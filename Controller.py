#!/usr/bin/env python3
"""Session controller for jgordijn.night-light.

The public interface is the ``attach`` subcommand.  It is a newline-delimited
JSON proxy to one compositor-session daemon.  This module deliberately uses
only the Python standard library and never invokes a shell.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import datetime as dt
import errno
import fcntl
import hashlib
import http.client
import json
import math
import os
import pathlib
import re
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
from dataclasses import dataclass
from typing import Any, Callable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

PROTOCOL = 1
VERSION = "1.0.0"
MAX_LINE = 64 * 1024
MAX_BODY = 256 * 1024
RELEASE_GRACE = float(os.environ.get("NIGHT_LIGHT_RELEASE_GRACE", "8"))
TEMPERATURE_WRITE_INTERVAL = 5.0
# One accepted write can spend two seconds in hyprctl and six more verifying
# identity, temperature, and gamma.  Shutdown lets that transaction become
# truthful before falling back to terminating its child.
SHUTDOWN_APPLY_TIMEOUT = 9.0
PROCESS_TERMINATE_TIMEOUT = 0.25
PROCESS_KILL_TIMEOUT = 1.0
ALLOWED_HOSTS = frozenset(("geocoding-api.open-meteo.com", "wttr.in"))
LOCATION_KEYS = (
    "label", "admin1", "country", "latitude", "longitude", "timezone",
    "source", "precision", "observedAt",
)
SOURCE_PRECISION = {
    "weather": "selected-locality",
    "manual-search": "selected-locality",
    "manual-coordinates": "coordinates",
    "auto-ip": "approximate-city",
}
# Linux sockaddr_un.sun_path has 108 bytes, including the terminating NUL for
# pathname sockets.  Keep this explicit: pathlib character counts are not the
# bound enforced by AF_UNIX.
UNIX_SOCKET_PATH_BYTES = 107
# Distinguish an intentionally captured no-apply state (None) from callers
# whose status publication is not tied to backend apply authority.
_UNBOUND_APPLY_TOKEN = object()
DISPLAY_TIME_KEYS = frozenset(("sunset", "sunrise", "nextBoundary", "overrideUntil"))
ECMASCRIPT_DATE_LIMIT_MS = 8_640_000_000_000_000
UTC_EPOCH = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)


def _open_directory(path: pathlib.Path) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return os.open(path, flags)


def _private_dir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = _open_directory(path)
    try:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode):
            raise OSError("private path is not a directory")
        if info.st_uid != os.getuid():
            raise PermissionError("private path has a different owner")
        os.fchmod(fd, 0o700)
    finally:
        os.close(fd)


def _safe_signature(value: str) -> str:
    """Return a fixed-size, filesystem-safe encoding of a session identity."""
    digest = hashlib.sha256(value.encode("utf-8", "surrogatepass")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def _require_private_runtime_root(path: pathlib.Path) -> None:
    if not path.is_absolute():
        raise RuntimeError("XDG_RUNTIME_DIR must be absolute")
    try:
        fd = _open_directory(path)
    except OSError as exc:
        raise RuntimeError("XDG_RUNTIME_DIR is not an accessible directory") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError("XDG_RUNTIME_DIR has an invalid owner or type")
        if stat.S_IMODE(info.st_mode) & 0o077:
            raise RuntimeError("XDG_RUNTIME_DIR is not private")
    finally:
        os.close(fd)


def _require_unix_path(path: pathlib.Path) -> None:
    encoded = os.fsencode(path)
    if b"\0" in encoded or len(encoded) > UNIX_SOCKET_PATH_BYTES:
        raise RuntimeError("controller socket path exceeds the AF_UNIX byte limit")


def runtime_dir() -> pathlib.Path:
    root = os.environ.get("XDG_RUNTIME_DIR")
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if not root or not signature:
        raise RuntimeError("XDG_RUNTIME_DIR and HYPRLAND_INSTANCE_SIGNATURE are required")
    runtime_root = pathlib.Path(root)
    _require_private_runtime_root(runtime_root)
    base = runtime_root / "jgordijn-night-light"
    result = base / _safe_signature(signature)
    # Validate before creating anything.  Hashing the complete signature keeps
    # the component at 43 ASCII bytes without conflating compositor sessions.
    _require_unix_path(result / "control.sock")
    _private_dir(base)
    _private_dir(result)
    return result


def location_path() -> pathlib.Path:
    override = os.environ.get("NIGHT_LIGHT_STATE_PATH")
    if override:
        return pathlib.Path(override)
    state_home = os.environ.get("XDG_STATE_HOME")
    if not state_home:
        home = os.environ.get("HOME")
        if not home:
            raise RuntimeError("HOME is required")
        state_home = str(pathlib.Path(home) / ".local" / "state")
    return pathlib.Path(state_home) / "omarchy" / "settings" / "jgordijn.night-light.json"


def _limited_string(value: Any, limit: int, *, nonempty: bool = False) -> str:
    if not isinstance(value, str):
        raise ValueError("invalid location text")
    value = value.strip()
    if nonempty and not value:
        raise ValueError("empty location label")
    if len(value) > limit:
        raise ValueError("location text is too long")
    return value


def _coordinate(value: Any, low: float, high: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("invalid coordinate")
    result = float(value)
    if not math.isfinite(result) or result < low or result > high:
        raise ValueError("coordinate out of range")
    # Keep integers/numbers as JSON numbers, while normalizing negative zero.
    return 0.0 if result == 0 else result


def _timestamp(value: Any) -> str:
    value = _limited_string(value, 64, nonempty=True)
    if not value.endswith("Z"):
        raise ValueError("timestamp is not UTC")
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise ValueError("invalid timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() != dt.timedelta(0):
        raise ValueError("timestamp is not UTC")
    return value


def validate_location(value: Any) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("location must be an object")
    source = value.get("source")
    if source not in SOURCE_PRECISION or value.get("precision") != SOURCE_PRECISION[source]:
        raise ValueError("invalid source and precision")
    return {
        "label": _limited_string(value.get("label"), 120, nonempty=True),
        "admin1": _limited_string(value.get("admin1"), 80),
        "country": _limited_string(value.get("country"), 80),
        "latitude": _coordinate(value.get("latitude"), -90, 90),
        "longitude": _coordinate(value.get("longitude"), -180, 180),
        "timezone": _limited_string(value.get("timezone"), 80),
        "source": source,
        "precision": value["precision"],
        "observedAt": _timestamp(value.get("observedAt")),
    }


def validate_state(value: Any, *, revision: int | None = None) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("state must be an object")
    if value.get("schemaVersion") != 1:
        raise ValueError("unsupported schema")
    raw_revision = value.get("revision") if revision is None else revision
    if isinstance(raw_revision, bool) or not isinstance(raw_revision, int) or raw_revision < 0:
        raise ValueError("invalid revision")
    mode = value.get("mode")
    if mode not in ("none", "weather", "manual", "auto-ip"):
        raise ValueError("invalid mode")
    consent = value.get("autoConsentVersion")
    if isinstance(consent, bool) or not isinstance(consent, int) or consent not in (0, 1):
        raise ValueError("invalid consent version")
    manual = validate_location(value.get("manual"))
    weather = validate_location(value.get("weatherCache"))
    auto_ip = validate_location(value.get("autoIpCache"))
    if manual is not None and manual["source"] not in ("manual-search", "manual-coordinates"):
        raise ValueError("invalid manual location")
    if weather is not None and weather["source"] != "weather":
        raise ValueError("invalid weather cache")
    if auto_ip is not None and auto_ip["source"] != "auto-ip":
        raise ValueError("invalid automatic cache")
    if mode == "manual" and manual is None:
        raise ValueError("manual mode has no location")
    if mode == "auto-ip" and (auto_ip is None or consent != 1):
        raise ValueError("automatic mode has no consented location")
    return {
        "schemaVersion": 1,
        "revision": raw_revision,
        "mode": mode,
        "autoConsentVersion": consent,
        "manual": manual,
        "weatherCache": weather,
        "autoIpCache": auto_ip,
    }


class LocationStore:
    """Atomic, private state storage with revision compare-and-swap."""

    def __init__(self, path: pathlib.Path | None = None):
        self.path = path or location_path()
        self._lock = threading.RLock()

    def read(self) -> tuple[str, dict[str, Any] | None]:
        with self._lock:
            return self._read_unlocked()

    def _read_unlocked(self) -> tuple[str, dict[str, Any] | None]:
        try:
            info = self.path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                return "temporarily-unavailable", None
            raw = self.path.read_bytes()
        except FileNotFoundError:
            return "absent", None
        except OSError:
            return "temporarily-unavailable", None
        try:
            decoded = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return "malformed", None
        if isinstance(decoded, dict) and decoded.get("schemaVersion") != 1:
            return "unsupported-schema", None
        try:
            return "valid", validate_state(decoded)
        except ValueError:
            return "malformed", None

    def write(self, candidate: Any, expected_revision: int | None = None) -> dict[str, Any]:
        with self._lock:
            outcome, current = self._read_unlocked()
            if outcome not in ("absent", "valid"):
                raise StateError("state-not-writable", outcome)
            current_revision = current["revision"] if current is not None else 0
            if expected_revision is not None:
                if isinstance(expected_revision, bool) or not isinstance(expected_revision, int):
                    raise StateError("revision-conflict", "invalid expected revision")
                if expected_revision != current_revision:
                    raise StateError("revision-conflict", "location state changed")
            try:
                state = validate_state(candidate, revision=current_revision + 1)
            except ValueError as exc:
                raise StateError("state-invalid", str(exc)) from exc
            parent = self.path.parent
            _private_dir(parent)
            payload = (json.dumps(state, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
            temporary: pathlib.Path | None = None
            try:
                fd, name = tempfile.mkstemp(prefix="." + self.path.name + ".", dir=parent)
                temporary = pathlib.Path(name)
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "wb", closefd=True) as stream:
                    stream.write(payload)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.path)
                temporary = None
                os.chmod(self.path, 0o600)
                directory_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            except OSError as exc:
                raise StateError("state-write-failed", "could not save location state") from exc
            finally:
                if temporary is not None:
                    with contextlib.suppress(FileNotFoundError):
                        temporary.unlink()
            return state

    def forget(self, expected_revision: int | None = None) -> None:
        with self._lock:
            outcome, current = self._read_unlocked()
            current_revision = current["revision"] if outcome == "valid" and current else 0
            if expected_revision is not None and expected_revision != current_revision:
                raise StateError("revision-conflict", "location state changed")
            try:
                self.path.unlink()
            except FileNotFoundError:
                return
            except OSError as exc:
                raise StateError("state-delete-failed", "could not forget location state") from exc
            directory_fd = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)


class StateError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class NetworkError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class ProviderClient:
    def __init__(self, request_json: Callable[..., Any] | None = None):
        self._request = request_json or self._request_json

    @staticmethod
    def _request_json(host: str, path: str, *, deadline: float) -> Any:
        if host not in ALLOWED_HOSTS or not path.startswith("/") or path.startswith("//"):
            raise NetworkError("network-denied", "provider is not allowed")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise NetworkError("offline", "provider request timed out")
        connection = http.client.HTTPSConnection(
            host, 443, timeout=min(3.0, remaining), context=ssl.create_default_context()
        )
        try:
            connection.request("GET", path, headers={"User-Agent": f"jgordijn.night-light/{VERSION}", "Accept": "application/json"})
            response = connection.getresponse()
            if response.status == 429:
                raise NetworkError("rate-limited", "provider rate limited the request")
            if response.status < 200 or response.status >= 300:
                raise NetworkError("offline", "provider request failed")
            body = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise NetworkError("offline", "provider request timed out")
                if connection.sock is not None:
                    connection.sock.settimeout(min(3.0, remaining))
                chunk = response.read(min(65536, MAX_BODY + 1 - len(body)))
                if not chunk:
                    break
                body.extend(chunk)
                if len(body) > MAX_BODY:
                    raise NetworkError("response-too-large", "provider response was too large")
            try:
                return json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise NetworkError("provider-invalid", "provider returned invalid data") from exc
        except NetworkError:
            raise
        except (OSError, http.client.HTTPException) as exc:
            raise NetworkError("offline", "provider is unavailable") from exc
        finally:
            connection.close()

    def _with_rate_retry(self, host: str, path: str) -> Any:
        deadline = time.monotonic() + 6.0
        for attempt, delay in enumerate((0.0, 0.25, 1.0)):
            if delay:
                if time.monotonic() + delay >= deadline:
                    break
                time.sleep(delay)
            try:
                return self._request(host, path, deadline=deadline)
            except NetworkError as exc:
                if exc.code != "rate-limited" or attempt == 2:
                    raise
        raise NetworkError("rate-limited", "provider rate limited the request")

    def geocode(self, query: Any, language: Any) -> list[dict[str, Any]]:
        if not isinstance(query, str):
            raise NetworkError("invalid-request", "invalid search query")
        normalized = " ".join(query.split())
        if len(normalized) > 200 or len("".join(normalized.split())) < 3:
            raise NetworkError("invalid-request", "search query is too short")
        if not isinstance(language, str) or not re.fullmatch(r"[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?", language):
            language = "en"
        path = "/v1/search?" + urllib.parse.urlencode({
            "name": normalized, "count": 5, "format": "json", "language": language,
        })
        data = self._with_rate_retry("geocoding-api.open-meteo.com", path)
        if not isinstance(data, dict) or not isinstance(data.get("results", []), list):
            raise NetworkError("provider-invalid", "provider returned invalid data")
        results = []
        now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        for item in data.get("results", [])[:5]:
            if not isinstance(item, dict):
                continue
            try:
                location = validate_location({
                    "label": item.get("name", ""),
                    "admin1": item.get("admin1", ""),
                    "country": item.get("country", ""),
                    "latitude": item.get("latitude"),
                    "longitude": item.get("longitude"),
                    "timezone": item.get("timezone", ""),
                    "source": "manual-search",
                    "precision": "selected-locality",
                    "observedAt": now,
                })
            except ValueError:
                continue
            if location is not None:
                results.append(location)
        return results

    @staticmethod
    def _wttr_value(area: dict[str, Any], key: str) -> str:
        value = area.get(key, "")
        if isinstance(value, list) and value and isinstance(value[0], dict):
            value = value[0].get("value", "")
        return value if isinstance(value, str) else ""

    def auto_locate(self) -> dict[str, Any]:
        data = self._with_rate_retry("wttr.in", "/?format=j1")
        try:
            area = data["nearest_area"][0]
            latitude = area["latitude"]
            longitude = area["longitude"]
        except (KeyError, IndexError, TypeError) as exc:
            raise NetworkError("provider-invalid", "provider returned invalid data") from exc
        now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        try:
            location = validate_location({
                "label": self._wttr_value(area, "areaName") or "Approximate",
                "admin1": self._wttr_value(area, "region"),
                "country": self._wttr_value(area, "country"),
                "latitude": float(latitude),
                "longitude": float(longitude),
                "timezone": "",
                "source": "auto-ip",
                "precision": "approximate-city",
                "observedAt": now,
            })
        except (ValueError, TypeError) as exc:
            raise NetworkError("provider-invalid", "provider returned invalid data") from exc
        assert location is not None
        return location


@dataclass(frozen=True)
class Actual:
    kind: str
    temperature: int
    gamma: int

    def json(self) -> dict[str, Any]:
        return {"kind": self.kind, "temperature": self.temperature, "gamma": self.gamma}

    def matches(self, desired: dict[str, Any] | None) -> bool:
        return bool(desired) and self.kind == desired["kind"] and (
            self.kind == "identity" or self.temperature == desired["temperature"]
        )


def validate_desired(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict) or raw.get("kind") not in ("identity", "temperature"):
        raise ValueError("invalid desired state")
    if raw["kind"] == "identity":
        return {"kind": "identity"}
    value = raw.get("temperature")
    if isinstance(value, bool) or not isinstance(value, int) or not 1000 <= value <= 6500:
        raise ValueError("invalid desired temperature")
    return {"kind": "temperature", "temperature": value}


def _zone_info(key: str) -> ZoneInfo | None:
    """Resolve one bounded IANA key without accepting filesystem paths."""
    if not key or len(key) > 80 or key.startswith("/") or "\0" in key:
        return None
    try:
        return ZoneInfo(key)
    except (ZoneInfoNotFoundError, ValueError, OSError):
        return None


def _system_zone() -> tuple[str, ZoneInfo]:
    """Resolve the live shell/system IANA zone, with UTC as a safe authority."""
    candidates: list[str] = []
    environment_zone = os.environ.get("TZ", "")
    if environment_zone.startswith(":"):
        environment_zone = environment_zone[1:]
    if environment_zone.startswith("/usr/share/zoneinfo/"):
        environment_zone = environment_zone[len("/usr/share/zoneinfo/"):]
    if environment_zone:
        candidates.append(environment_zone)

    local_zone = dt.datetime.now().astimezone().tzinfo
    local_key = getattr(local_zone, "key", None)
    if isinstance(local_key, str):
        candidates.append(local_key)

    with contextlib.suppress(OSError):
        resolved = os.path.realpath("/etc/localtime")
        marker = "/zoneinfo/"
        if marker in resolved:
            candidates.append(resolved.split(marker, 1)[1])
    with contextlib.suppress(OSError, UnicodeError):
        timezone_text = pathlib.Path("/etc/timezone").read_text().strip()
        if timezone_text:
            candidates.append(timezone_text)

    for key in candidates:
        zone = _zone_info(key)
        if zone is not None:
            return key, zone
    # UTC is itself an installed IANA key in CPython's zoneinfo search path.
    return "UTC", ZoneInfo("UTC")


def _epoch_datetime(epoch_ms: Any, zone: ZoneInfo) -> dt.datetime:
    if (
        isinstance(epoch_ms, bool)
        or not isinstance(epoch_ms, (int, float))
        or not math.isfinite(epoch_ms)
        or abs(epoch_ms) > ECMASCRIPT_DATE_LIMIT_MS
    ):
        raise ValueError("invalid epoch")
    try:
        return (UTC_EPOCH + dt.timedelta(milliseconds=epoch_ms)).astimezone(zone)
    except (OverflowError, ValueError) as exc:
        # zoneinfo is backed by datetime, whose supported calendar is narrower
        # than ECMAScript's.  An epoch that cannot be projected is not usable.
        raise ValueError("invalid epoch") from exc


def _offset_minutes(projected: dt.datetime) -> int:
    offset = projected.utcoffset()
    if offset is None:
        raise ValueError("invalid timezone offset")
    # Current IANA offsets are minute-aligned.  int() also gives the conventional
    # minute projection for the few historical local-mean-time second offsets.
    return int(offset.total_seconds() / 60)


def _ambiguous_wall_time(projected: dt.datetime, zone: ZoneInfo) -> bool:
    naive = projected.replace(tzinfo=None)
    first = naive.replace(tzinfo=zone, fold=0)
    second = naive.replace(tzinfo=zone, fold=1)
    if first.utcoffset() == second.utcoffset():
        return False

    def valid(candidate: dt.datetime) -> bool:
        returned = candidate.astimezone(dt.timezone.utc).astimezone(zone)
        return returned.replace(tzinfo=None) == naive and returned.fold == candidate.fold

    return valid(first) and valid(second)


def _projected_time(epoch_ms: Any, zone: ZoneInfo) -> dict[str, Any]:
    projected = _epoch_datetime(epoch_ms, zone)
    return {
        "epochMs": epoch_ms,
        "dateKey": projected.date().isoformat(),
        "wallMs": (
            projected.hour * 3_600_000
            + projected.minute * 60_000
            + projected.second * 1_000
            + projected.microsecond // 1_000
        ),
        "offsetMinutes": _offset_minutes(projected),
        "fold": projected.fold,
        "ambiguous": _ambiguous_wall_time(projected, zone),
    }


def _boundary_epoch_ms(day: dt.date, zone: ZoneInfo) -> int:
    # fold=0 chooses the first midnight when it repeats.  For a midnight gap,
    # zoneinfo's pre-transition interpretation maps to the first real instant
    # of that civil date, which is the required epoch boundary.
    local_midnight = dt.datetime.combine(day, dt.time(), tzinfo=zone).replace(fold=0)
    utc_midnight = local_midnight.astimezone(dt.timezone.utc)
    delta = utc_midnight - UTC_EPOCH
    return (delta.days * 86_400 + delta.seconds) * 1_000 + delta.microseconds // 1_000


def project_civil_day(request: dict[str, Any]) -> dict[str, Any]:
    """Validate and project one request into a single local-civil transaction."""
    requested_zone = request.get("zoneId")
    if not isinstance(requested_zone, str) or len(requested_zone) > 80:
        raise ValueError("invalid timezone")
    zone = _zone_info(requested_zone)
    if zone is None:
        zone_id, zone = _system_zone()
        zone_source = "system"
    else:
        zone_id = requested_zone
        zone_source = "location"

    now = _epoch_datetime(request.get("nowMs"), zone)
    date_key = now.date().isoformat()
    marker = _projected_time(request.get("nowMs"), zone)

    raw_events = request.get("events", [])
    if not isinstance(raw_events, list) or len(raw_events) > 8:
        raise ValueError("invalid events")
    events = []
    for raw_event in raw_events:
        if not isinstance(raw_event, dict) or raw_event.get("kind") not in ("sunrise", "sunset"):
            raise ValueError("invalid event")
        event = _projected_time(raw_event.get("epochMs"), zone)
        if event["dateKey"] == date_key:
            events.append({"kind": raw_event["kind"], **event})
    events.sort(key=lambda event: event["epochMs"])

    raw_display_times = request.get("displayTimes", {})
    if not isinstance(raw_display_times, dict) or not set(raw_display_times).issubset(DISPLAY_TIME_KEYS):
        raise ValueError("invalid display times")
    display_times: dict[str, Any] = {}
    for key, epoch_ms in raw_display_times.items():
        display_times[key] = None if epoch_ms is None else _projected_time(epoch_ms, zone)

    try:
        next_day = now.date() + dt.timedelta(days=1)
        day_start_ms = _boundary_epoch_ms(now.date(), zone)
        day_end_ms = _boundary_epoch_ms(next_day, zone)
    except (OverflowError, ValueError) as exc:
        raise ValueError("invalid epoch") from exc
    return {
        "dateKey": date_key,
        "zoneId": zone_id,
        "zoneSource": zone_source,
        "dayStartMs": day_start_ms,
        "dayEndMs": day_end_ms,
        "markerWallMs": marker["wallMs"],
        "markerOffsetMinutes": marker["offsetMinutes"],
        "markerFold": marker["fold"],
        "markerAmbiguous": marker["ambiguous"],
        "events": events,
        "displayTimes": display_times,
    }


class ApplySuperseded(Exception):
    """An apply token was replaced before it could mutate the display."""


class ExternalActual(Exception):
    """A schedule compare-and-swap found an unobserved external winner."""

    def __init__(self, actual: Actual):
        super().__init__("actual display state changed")
        self.actual = actual


class ApplyToken:
    """Attachment/generation-labelled cancellation visible to loop and worker."""

    def __init__(
        self,
        generation: int,
        attachment_epoch: int,
        if_actual: dict[str, Any] | None = None,
    ):
        self.generation = generation
        self.attachment_epoch = attachment_epoch
        self.if_actual = if_actual
        self._async_event = asyncio.Event()
        self._thread_event = threading.Event()
        self._stop_child_event = asyncio.Event()
        self._stop_child_thread_event = threading.Event()

    def set(self, *, stop_mutating_child: bool = True) -> None:
        # Shutdown may stop admission while allowing an already-running apply
        # transaction its bounded grace.  Supersession additionally raises the
        # child barrier used by hot reload and latest-wins replacement.
        if stop_mutating_child:
            self._stop_child_thread_event.set()
            self._stop_child_event.set()
        self._thread_event.set()
        self._async_event.set()

    def is_set(self) -> bool:
        return self._thread_event.is_set()

    def must_stop_child(self) -> bool:
        return self._stop_child_thread_event.is_set()

    async def wait(self) -> None:
        await self._async_event.wait()

    async def wait_to_stop_child(self) -> None:
        await self._stop_child_event.wait()


class Backend:
    """Serialized hyprsunset access.  Every child is invoked with argv only."""

    def __init__(self):
        self.hyprctl = os.environ.get("NIGHT_LIGHT_HYPRCTL", "/usr/bin/hyprctl")
        self.hyprsunset = os.environ.get("NIGHT_LIGHT_HYPRSUNSET", "/usr/bin/hyprsunset")
        self.uwsm = os.environ.get("NIGHT_LIGHT_UWSM_APP", "/usr/bin/uwsm-app")
        self.signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        self.baseline: Actual | None = None
        self.actual: Actual | None = None
        self.last_ack: dict[str, Any] | None = None
        self.last_ack_owner: tuple[int, int] | None = None
        self.last_ack_chain_available = False
        # Monotonic identity for the ack allowance represented above. Statuses
        # snapshot this before output so an older observation cannot consume a
        # newer same-token ack created while that output is blocked.
        self.last_ack_chain_version = 0
        # Kept distinct from last_ack: a timed-out child may have changed the
        # compositor before it was terminated even though verification did not
        # complete.  Release may CAS against either truthful possibility.
        self.last_attempt: dict[str, Any] | None = None
        self.last_attempt_owner: tuple[int, int] | None = None
        self.last_temperature_write = 0.0
        self.owned_pid: int | None = None
        self.owned_start: str | None = None
        self.owned_exe: str | None = None
        self.owned_signature: str | None = None
        self.started = False
        self.command_lock = asyncio.Lock()
        self.accepting_applies = True
        self._mutating_processes: set[asyncio.subprocess.Process] = set()

    async def _stop_process(
        self,
        process: asyncio.subprocess.Process,
        communication: asyncio.Task[tuple[bytes, bytes]] | None = None,
    ) -> None:
        """Terminate and reap a child; returning always means it cannot write."""
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                process.terminate()
        waiter: asyncio.Task[Any] = (
            communication if communication is not None
            else asyncio.create_task(process.wait())
        )
        try:
            await asyncio.wait_for(asyncio.shield(waiter), PROCESS_TERMINATE_TIMEOUT)
            return
        except asyncio.TimeoutError:
            pass
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                process.kill()
        try:
            await asyncio.wait_for(asyncio.shield(waiter), PROCESS_KILL_TIMEOUT)
        except asyncio.TimeoutError as exc:
            if communication is not None:
                communication.cancel()
            raise RuntimeError("backend command could not be stopped") from exc

    async def stop_mutating_processes(self) -> None:
        """Defensive shutdown barrier used before compare-and-swap release."""
        processes = tuple(self._mutating_processes)
        if processes:
            await asyncio.gather(
                *(self._stop_process(process) for process in processes),
                return_exceptions=False,
            )
            for process in processes:
                if process.returncode is not None:
                    self._mutating_processes.discard(process)
        if self._mutating_processes:
            raise RuntimeError("backend mutation did not stop")

    async def _run(
        self,
        argv: list[str],
        timeout: float = 2.0,
        *,
        superseded: ApplyToken | None = None,
        mutating: bool = False,
        shutdown_write: bool = False,
    ) -> str:
        # Unlike asyncio.to_thread(subprocess.run), this keeps a process handle:
        # cancellation and timeout both terminate and reap the child.
        if superseded is not None and superseded.is_set():
            raise ApplySuperseded()
        if mutating and not shutdown_write and not self.accepting_applies:
            raise ApplySuperseded()
        creation = asyncio.create_task(
            asyncio.create_subprocess_exec(
                *argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        )
        try:
            process = await asyncio.shield(creation)
        except asyncio.CancelledError:
            # Process creation itself is cancellation-sensitive.  Recover the
            # handle and stop it rather than letting an untracked child escape.
            process = await creation
            await self._stop_process(process)
            raise
        if mutating:
            self._mutating_processes.add(process)
        communication = asyncio.create_task(process.communicate())
        superseded_wait: asyncio.Task[None] | None = None
        if mutating and superseded is not None:
            superseded_wait = asyncio.create_task(superseded.wait_to_stop_child())
        try:
            waiters: set[asyncio.Task[Any]] = {communication}
            if superseded_wait is not None:
                waiters.add(superseded_wait)
            done, _pending = await asyncio.wait(
                waiters, timeout=timeout, return_when=asyncio.FIRST_COMPLETED
            )
            # Cancellation wins a simultaneous process completion.  Once the
            # attachment handshake sets this token, return only after its old
            # mutating child has been terminated and reaped.  command_lock then
            # makes this a barrier before a replacement apply can start.
            if superseded is not None and superseded.must_stop_child():
                await self._stop_process(process, communication)
                raise ApplySuperseded()
            if communication not in done:
                await self._stop_process(process, communication)
                raise RuntimeError("backend command timed out")
            stdout, _stderr = communication.result()
            if process.returncode != 0:
                raise RuntimeError("backend command failed")
            return stdout.decode("utf-8", "replace").strip()
        except asyncio.CancelledError:
            await self._stop_process(process, communication)
            raise
        finally:
            if superseded_wait is not None:
                superseded_wait.cancel()
                await asyncio.gather(superseded_wait, return_exceptions=True)
            # Keep an unreaped child visible to the shutdown barrier.  In the
            # exceptional case where SIGKILL cannot be observed within its
            # bound, release must fail closed rather than claim quiescence.
            if mutating and process.returncode is not None:
                self._mutating_processes.discard(process)

    @staticmethod
    def _integer(output: str, low: int, high: int) -> int:
        matches = re.findall(r"(?<![\d.])-?\d+(?![\d.])", output)
        if not matches:
            raise RuntimeError("malformed backend response")
        value = int(matches[-1])
        if not low <= value <= high:
            raise RuntimeError("backend value out of range")
        return value

    async def _probe_locked(self, *, publish: bool = True) -> Actual:
        """Probe while command_lock is held by the caller."""
        identity_text = await self._run([self.hyprctl, "hyprsunset", "identity", "get"])
        temperature_text = await self._run([self.hyprctl, "hyprsunset", "temperature"])
        gamma_text = await self._run([self.hyprctl, "hyprsunset", "gamma"])
        lowered = identity_text.strip().lower()
        if lowered in ("true", "1", "yes", "on"):
            identity = True
        elif lowered in ("false", "0", "no", "off"):
            identity = False
        else:
            raise RuntimeError("malformed identity response")
        actual = Actual(
            "identity" if identity else "temperature",
            self._integer(temperature_text, 1000, 20000),
            self._integer(gamma_text, 1, 1000),
        )
        if publish:
            self.actual = actual
        return actual

    def _reconcile_attempt(self, actual: Actual) -> bool:
        """Resolve one uncertain mutation against this serialized observation."""
        attempt = self.last_attempt
        owner = self.last_attempt_owner
        if attempt is not None:
            # Once the mutating child has stopped, its attempt has exactly one
            # truthful resolution.  Do not leave a stale candidate available to
            # a later observation or compare-and-swap release.
            self.last_attempt = None
            self.last_attempt_owner = None
            if actual.matches(attempt):
                self.last_ack = attempt
                self.last_ack_owner = owner
                self.last_ack_chain_available = owner is not None
                self.last_ack_chain_version += 1
                return True
        # Equality with arbitrary older plugin history is observational, not
        # proof that this particular preflight consumed a controller attempt.
        return False

    def note_observation_published(self, observed_ack_version: int) -> None:
        """Consume only the exact ack allowance visible to this observation."""
        if observed_ack_version == self.last_ack_chain_version:
            self.last_ack_chain_available = False

    def _ack_chain_matches(self, actual: Actual, token: ApplyToken | None) -> bool:
        return bool(
            token is not None
            and self.last_ack_chain_available
            and self.last_ack_owner is not None
            and self.last_ack_owner[0] == token.attachment_epoch
            and self.last_ack_owner[1] < token.generation
            and actual.matches(self.last_ack)
        )

    async def probe(self, *, publish: bool = True) -> Actual:
        async with self.command_lock:
            return await self._probe_locked(publish=publish)

    async def probe_reconciled(
        self,
        accept: Callable[[], bool],
    ) -> tuple[Actual, bool] | None:
        """Probe and atomically resolve a possibly committed controller write.

        ``accept`` is checked while the command lock still excludes another
        controller mutation.  An obsolete attachment therefore changes neither
        the published cache nor write ownership.
        """
        async with self.command_lock:
            actual = await self._probe_locked(publish=False)
            if not accept():
                return None
            owned = self._reconcile_attempt(actual)
            self.actual = actual
            return actual, owned

    def _process_info(
        self,
        pid: int,
        *,
        signature: str | None = None,
    ) -> tuple[str, str, str] | None:
        proc = pathlib.Path("/proc") / str(pid)
        try:
            exe = os.readlink(proc / "exe")
            environ = (proc / "environ").read_bytes().split(b"\0")
            expected_signature = self.signature if signature is None else signature
            signature_entry = (
                "HYPRLAND_INSTANCE_SIGNATURE=" + expected_signature
            ).encode()
            if signature_entry not in environ:
                return None
            fields = (proc / "stat").read_text().split()
            return exe, fields[21], "matched"
        except (OSError, IndexError, UnicodeDecodeError):
            return None

    def matching_processes(self) -> list[tuple[int, str, str]]:
        expected = os.path.realpath(self.hyprsunset)
        found = []
        try:
            entries = os.scandir("/proc")
        except OSError:
            return found
        with entries:
            for entry in entries:
                if not entry.name.isdigit():
                    continue
                info = self._process_info(int(entry.name))
                if info and os.path.realpath(info[0]) == expected:
                    found.append((int(entry.name), info[0], info[1]))
        return found

    async def initialize(self) -> Actual:
        try:
            actual = await self.probe()
            self.baseline = actual
            return actual
        except Exception:
            pass
        matches = self.matching_processes()
        if matches:
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                await asyncio.sleep(0.1)
                try:
                    actual = await self.probe()
                    self.baseline = actual
                    return actual
                except Exception:
                    continue
            raise RuntimeError("matching hyprsunset IPC did not become ready")
        # No matching session process exists.  Launch exact configured binaries.
        await asyncio.to_thread(
            subprocess.Popen,
            [self.uwsm, "--", self.hyprsunset, "--config", "/dev/null", "--identity"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True, close_fds=True,
        )
        self.started = True
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            await asyncio.sleep(0.1)
            matches = self.matching_processes()
            if len(matches) == 1:
                self.owned_pid, self.owned_exe, self.owned_start = matches[0]
                self.owned_signature = self.signature
            try:
                actual = await self.probe()
                self.baseline = actual
                return actual
            except Exception:
                continue
        raise RuntimeError("hyprsunset did not start")

    async def apply(
        self,
        desired: dict[str, Any],
        *,
        restoring: bool = False,
        superseded: ApplyToken | None = None,
        if_actual: dict[str, Any] | None = None,
    ) -> Actual:
        desired = validate_desired(desired)
        if if_actual is not None:
            if_actual = validate_desired(if_actual)
        if superseded is not None and superseded.is_set():
            raise ApplySuperseded()

        wait = 0.0
        if desired["kind"] == "temperature" and not restoring:
            wait = TEMPERATURE_WRITE_INTERVAL - (time.monotonic() - self.last_temperature_write)
        if wait > 0:
            # Matching requests are observational and must not sit through the
            # write limiter.  A second probe below closes changes during wait.
            actual = await self.probe(publish=False)
            if superseded is not None and superseded.is_set():
                raise ApplySuperseded()
            self.actual = actual
            self._reconcile_attempt(actual)
            if actual.matches(desired):
                return actual
            if superseded is None:
                await asyncio.sleep(wait)
            else:
                try:
                    await asyncio.wait_for(superseded.wait(), timeout=wait)
                except asyncio.TimeoutError:
                    pass
                else:
                    raise ApplySuperseded()

        async with self.command_lock:
            if superseded is not None and superseded.is_set():
                raise ApplySuperseded()

            # The controller, rather than any caller-side cache, is the final
            # no-op authority.  Probe and the possible mutation share the lock
            # so daemon work cannot interleave between that decision and write.
            actual = await self._probe_locked(publish=False)
            if superseded is not None and superseded.is_set():
                raise ApplySuperseded()
            self.actual = actual
            reconciled_attempt = False
            if not restoring:
                reconciled_attempt = self._reconcile_attempt(actual)
            if actual.matches(desired):
                return actual
            if (
                not restoring
                and if_actual is not None
                and not actual.matches(if_actual)
                and not reconciled_attempt
                and not self._ack_chain_matches(actual, superseded)
            ):
                # Probe and decision share command_lock, so no controller write
                # can slip between this failed CAS and external adoption.
                raise ExternalActual(actual)

            if not restoring:
                self.last_attempt = desired
                self.last_attempt_owner = (
                    (superseded.attachment_epoch, superseded.generation)
                    if superseded is not None else None
                )
            if desired["kind"] == "identity":
                await self._run(
                    [self.hyprctl, "hyprsunset", "identity", "true"],
                    superseded=superseded, mutating=True,
                    shutdown_write=restoring,
                )
            else:
                await self._run(
                    [self.hyprctl, "hyprsunset", "temperature", str(desired["temperature"])],
                    superseded=superseded, mutating=True,
                    shutdown_write=restoring,
                )
                self.last_temperature_write = time.monotonic()
            if superseded is not None and superseded.is_set():
                raise ApplySuperseded()
            actual = await self._probe_locked(publish=False)
            # Verification can overlap an attachment handshake.  Do not turn
            # obsolete completion into acknowledged ownership or observation.
            if superseded is not None and superseded.is_set():
                raise ApplySuperseded()
            self.actual = actual
            if not actual.matches(desired):
                if not restoring:
                    self.last_attempt = None
                    self.last_attempt_owner = None
                raise RuntimeError("backend verification failed")
            if not restoring:
                self.last_ack = desired
                self.last_ack_owner = self.last_attempt_owner
                self.last_ack_chain_available = self.last_ack_owner is not None
                self.last_ack_chain_version += 1
                self.last_attempt = None
                self.last_attempt_owner = None
            return actual

    def _owned_identity(self) -> tuple[int, str, str, str] | None:
        if (
            self.owned_pid is None
            or self.owned_start is None
            or self.owned_exe is None
            or self.owned_signature is None
        ):
            return None
        executable = os.path.realpath(self.owned_exe)
        if (
            executable != os.path.realpath(self.hyprsunset)
            or self.owned_signature != self.signature
        ):
            return None
        return (
            self.owned_pid,
            self.owned_start,
            executable,
            self.owned_signature,
        )

    def _owned_still_matches(
        self,
        identity: tuple[int, str, str, str] | None = None,
    ) -> bool:
        identity = self._owned_identity() if identity is None else identity
        if identity is None:
            return False
        pid, start, executable, signature = identity
        info = self._process_info(pid, signature=signature)
        return bool(
            info
            and info[1] == start
            and os.path.realpath(info[0]) == executable
        )

    @staticmethod
    async def _wait_pidfd(pidfd: int, timeout: float) -> bool:
        """Wait a bounded time for one pidfd's exact process to exit."""
        loop = asyncio.get_running_loop()
        exited = loop.create_future()

        def ready() -> None:
            if not exited.done():
                exited.set_result(None)

        loop.add_reader(pidfd, ready)
        try:
            await asyncio.wait_for(asyncio.shield(exited), timeout)
            return True
        except asyncio.TimeoutError:
            return False
        finally:
            loop.remove_reader(pidfd)
            if not exited.done():
                exited.cancel()

    @staticmethod
    def _reap_pidfd(pidfd: int) -> None:
        """Reap when this process is the parent; otherwise the owner will reap."""
        with contextlib.suppress(ChildProcessError, OSError):
            os.waitid(os.P_PIDFD, pidfd, os.WEXITED | os.WNOHANG)

    async def _stop_owned_process(self) -> None:
        """TERM, then KILL/reap only the recorded owned process identity."""
        identity = self._owned_identity()
        if identity is None or not self._owned_still_matches(identity):
            return
        pid, _start, _executable, _signature = identity
        try:
            pidfd = os.pidfd_open(pid)
        except ProcessLookupError:
            return

        try:
            # Recheck after obtaining the stable pidfd.  Signals sent through it
            # cannot hit a replacement that later reuses the numeric PID.
            if not self._owned_still_matches(identity):
                return
            signal.pidfd_send_signal(pidfd, signal.SIGTERM)
            if await self._wait_pidfd(pidfd, PROCESS_TERMINATE_TIMEOUT):
                self._reap_pidfd(pidfd)
                return

            # Exec or session changes revoke ownership before escalation.
            if not self._owned_still_matches(identity):
                raise RuntimeError("owned hyprsunset identity changed during shutdown")
            signal.pidfd_send_signal(pidfd, signal.SIGKILL)
            if not await self._wait_pidfd(pidfd, PROCESS_KILL_TIMEOUT):
                raise RuntimeError("owned hyprsunset could not be stopped")
            self._reap_pidfd(pidfd)
        finally:
            os.close(pidfd)

    async def release(self) -> None:
        """CAS-restore shared state and always stop a verified owned daemon."""
        try:
            actual = await self.probe()
        except Exception:
            # A release probe failure prevents safe restoration, but not teardown
            # of a process whose complete launch identity is still verified.
            if self.started:
                await self._stop_owned_process()
            return
        candidates = [
            candidate for candidate in (self.last_attempt, self.last_ack)
            if candidate is not None
        ]
        if not candidates and self.started and self.baseline is not None:
            expected = {"kind": self.baseline.kind}
            if self.baseline.kind == "temperature":
                expected["temperature"] = self.baseline.temperature
            candidates.append(expected)
        expected = candidates[0] if candidates else None

        if self.started:
            restoration_error: Exception | None = None
            try:
                # An external winner revokes restoration authority, but never
                # ownership of the exact daemon this controller launched.
                if not candidates or any(actual.matches(item) for item in candidates):
                    await self.apply({"kind": "identity"}, restoring=True)
            except Exception as exc:
                restoration_error = exc
            try:
                await self._stop_owned_process()
            except Exception as stop_error:
                if restoration_error is not None:
                    raise restoration_error from stop_error
                raise
            if restoration_error is not None:
                raise restoration_error
            return

        if candidates and not any(actual.matches(candidate) for candidate in candidates):
            return  # An external owner won the CAS; do not touch shared state.
        if self.baseline is not None and expected is not None:
            target = {"kind": self.baseline.kind}
            if self.baseline.kind == "temperature":
                target["temperature"] = self.baseline.temperature
            if not actual.matches(target):
                with contextlib.suppress(Exception):
                    await self.apply(target, restoring=True)


class Client:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader = reader
        self.writer = writer
        self.write_lock = asyncio.Lock()
        self.tasks: dict[str, asyncio.Task[Any]] = {}
        self.timeline_tasks: set[asyncio.Task[Any]] = set()

    async def send(
        self,
        value: dict[str, Any],
        *,
        guard: Callable[[], bool] | None = None,
    ) -> bool:
        if self.writer.is_closing():
            return False
        data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
        async with self.write_lock:
            # Check after waiting for the output lock and immediately before
            # publication, so an attachment epoch/generation change cannot
            # queue an old status behind an earlier message. The return value
            # lets ownership bookkeeping happen only after this guarded write.
            if guard is not None and not guard():
                return False
            self.writer.write(data)
            await self.writer.drain()
            # drain may yield long enough for a newer generation or attachment
            # to supersede this response. Bytes can already be buffered, but
            # callers reject their stale correlation; do not report an
            # authoritative publication or consume owned-ack allowance.
            if guard is not None and not guard():
                return False
            return True


@dataclass
class AttachmentSession:
    epoch: int
    generation_floor: dict[str, int]


class ControllerDaemon:
    def __init__(self, directory: pathlib.Path):
        self.directory = directory
        self.socket_path = directory / "control.sock"
        self.lock_path = directory / "controller.lock"
        self.lock_fd: int | None = None
        self.server: asyncio.AbstractServer | None = None
        self.clients: set[Client] = set()
        self.ever_attached = False
        self.release_task: asyncio.Task[Any] | None = None
        self.stop_event = asyncio.Event()
        self.store = LocationStore()
        self.provider = ProviderClient()
        self.backend = Backend()
        self.backend_ready = False
        self.backend_error: str | None = None
        self.pending: tuple[dict[str, Any], Client, dict[str, Any], ApplyToken] | None = None
        self.deferred: tuple[dict[str, Any], Client, dict[str, Any], ApplyToken] | None = None
        self.apply_token: ApplyToken | None = None
        self.apply_event = asyncio.Event()
        self.apply_task: asyncio.Task[Any] | None = None
        self.health_task: asyncio.Task[Any] | None = None
        self.attachment_epoch = 0
        self.active_attachment_epoch = 0
        self.attachment_sessions: dict[Any, AttachmentSession] = {}
        self.network_token: dict[str, tuple[Any, ...] | None] = {"geocode": None, "auto": None}
        self.timeline_token: object | None = None
        self.state_transaction_lock = asyncio.Lock()
        self.apply_idle = asyncio.Event()
        self.apply_idle.set()
        # Initialization owns process-launch lifecycle state.  Keep its task
        # independent from apply-loop cancellation so shutdown can wait until a
        # launched daemon has either been identified or initialization failed.
        self.initialization_task: asyncio.Task[Actual] | None = None
        self.closing = False
        self.runtime_override: dict[str, Any] | None = None
        self.last_schedule_boundary: int | None = None

    def acquire(self) -> bool:
        flags = os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
        lock_fd = os.open(self.lock_path, flags, 0o600)
        info = os.fstat(lock_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            os.close(lock_fd)
            raise PermissionError("controller lock has an invalid owner or type")
        os.fchmod(lock_fd, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(lock_fd)
            return False
        self.lock_fd = lock_fd
        return True

    async def _initialize_backend(self) -> Actual:
        """Run initialization as tracked, shutdown-visible lifecycle work."""
        task = self.initialization_task
        if task is None or task.done():
            task = asyncio.create_task(self.backend.initialize())
            self.initialization_task = task
        self.apply_idle.clear()
        try:
            # Cancelling an apply must not abandon a to_thread(Popen) launch.
            # The independent task records started/ownership before close's
            # initialization barrier permits compare-and-swap release.
            return await asyncio.shield(task)
        finally:
            self.apply_idle.set()
            if task.done() and self.initialization_task is task:
                self.initialization_task = None

    async def start(self) -> None:
        with contextlib.suppress(FileNotFoundError):
            self.socket_path.unlink()
        self.server = await asyncio.start_unix_server(self.handle_client, path=self.socket_path, limit=MAX_LINE + 1)
        socket_info = self.socket_path.lstat()
        if not stat.S_ISSOCK(socket_info.st_mode) or socket_info.st_uid != os.getuid():
            self.server.close()
            await self.server.wait_closed()
            raise PermissionError("controller socket has an invalid owner or type")
        os.chmod(self.socket_path, 0o600)
        self.apply_task = asyncio.create_task(self.apply_loop())
        self.health_task = asyncio.create_task(self.health_loop())
        try:
            await self._initialize_backend()
            self.backend_ready = True
        except Exception:
            self.backend_error = "backend-unavailable"
        # A daemon spawned by an attachment that dies before connecting must not
        # become an orphan either.
        if not self.clients:
            self.release_task = asyncio.create_task(self.release_after_grace())

    async def broadcast_status(
        self,
        request: dict[str, Any] | None = None,
        client: Client | None = None,
        *,
        expected_epoch: int | None = None,
        expected_token: ApplyToken | None | object = _UNBOUND_APPLY_TOKEN,
    ) -> None:
        # Snapshot actual and its ack-chain identity in one event-loop turn.
        # Publication may block, but it can consume only this observed version.
        observed_ack_version = getattr(self.backend, "last_ack_chain_version", 0)
        actual = self.backend.actual.json() if self.backend.actual else {"kind": "unavailable"}
        response = {
            "protocol": PROTOCOL, "type": "backendStatus", "available": self.backend_ready,
            "actual": actual, "override": self.runtime_override, "error": self.backend_error,
        }
        if request:
            response.update(request_fields(request))
        targets = [client] if client else list(self.clients)
        for target in targets:
            if target is None:
                continue

            def still_current(target: Client = target) -> bool:
                session = self.attachment_sessions.get(target)
                if session is None or session.epoch != self.active_attachment_epoch:
                    return False
                if expected_epoch is not None and session.epoch != expected_epoch:
                    return False
                if expected_token is _UNBOUND_APPLY_TOKEN:
                    return True
                if expected_token is None:
                    return self.apply_token is None
                return self.apply_is_current(target, expected_token)

            with contextlib.suppress(Exception):
                # Client.send rechecks authority both after the output lock and
                # after drain. False means either no bytes were written or the
                # buffered correlation became stale during drain; neither is an
                # authoritative Service observation, so neither may consume the
                # ack chain needed by a rapid successor's truthful ifActual.
                did_publish = await target.send(response, guard=still_current)
                if did_publish:
                    published = getattr(self.backend, "note_observation_published", None)
                    if published is not None:
                        published(observed_ack_version)

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        sock = writer.get_extra_info("socket")
        if sock is not None and hasattr(socket, "SO_PEERCRED"):
            try:
                _pid, uid, _gid = __import__("struct").unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if uid != os.getuid():
                    writer.close()
                    await writer.wait_closed()
                    return
            except OSError:
                writer.close()
                return
        client = Client(reader, writer)
        session = self.activate_client(client)
        self.ever_attached = True
        if self.release_task:
            self.release_task.cancel()
            self.release_task = None
        await client.send({"protocol": PROTOCOL, "type": "ready", "daemonPid": os.getpid(), "available": self.backend_ready})
        await self.broadcast_status(client=client, expected_epoch=session.epoch)
        try:
            while True:
                try:
                    line = await reader.readline()
                except (ValueError, asyncio.LimitOverrunError):
                    break
                if not line:
                    break
                if len(line) > MAX_LINE or not line.endswith(b"\n"):
                    break
                try:
                    request = json.loads(line)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    await self.error(client, {}, "invalid-json", "request is not valid JSON")
                    continue
                if (
                    isinstance(request, dict)
                    and request.get("operation") == "projectCivilDay"
                ):
                    # Projection runs in a worker thread.  Do not serialize the
                    # socket reader behind that worker: the next NDJSON request
                    # must be admitted immediately so it can revoke stale
                    # timeline authority before the old result publishes.
                    task = asyncio.create_task(self.dispatch(client, request))
                    client.timeline_tasks.add(task)

                    def projection_done(completed: asyncio.Task[Any]) -> None:
                        client.timeline_tasks.discard(completed)
                        with contextlib.suppress(asyncio.CancelledError, Exception):
                            completed.result()

                    task.add_done_callback(projection_done)
                else:
                    await self.dispatch(client, request)
        finally:
            for task in client.tasks.values():
                task.cancel()
            for task in client.timeline_tasks:
                task.cancel()
            if client.timeline_tasks:
                await asyncio.gather(*client.timeline_tasks, return_exceptions=True)
            self.clients.discard(client)
            self.attachment_sessions.pop(client, None)
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
            if not self.clients and self.ever_attached and not self.closing:
                self.release_task = asyncio.create_task(self.release_after_grace())

    async def release_after_grace(self) -> None:
        try:
            await asyncio.sleep(RELEASE_GRACE)
            if not self.clients:
                self.stop_event.set()
        except asyncio.CancelledError:
            pass

    async def error(self, client: Client, request: Any, code: str, message: str) -> None:
        response = {"protocol": PROTOCOL, "type": "error", "code": code, "message": message}
        if isinstance(request, dict):
            response.update(request_fields(request))
        await client.send(response)

    @staticmethod
    def valid_request(request: Any) -> tuple[bool, str]:
        if not isinstance(request, dict) or request.get("protocol") != PROTOCOL:
            return False, "unsupported-protocol"
        if not isinstance(request.get("requestId"), (str, int)) or isinstance(request.get("requestId"), bool):
            return False, "invalid-request"
        generation = request.get("generation")
        if isinstance(generation, bool) or not isinstance(generation, int) or generation < 0:
            return False, "invalid-request"
        if not isinstance(request.get("operation"), str):
            return False, "invalid-request"
        return True, ""

    def activate_client(self, client: Any, *, connected: bool = True) -> AttachmentSession:
        """Make a new attachment the sole publisher for a fresh generation namespace."""
        existing = self.attachment_sessions.get(client)
        if existing is not None:
            return existing
        self.attachment_epoch += 1
        session = AttachmentSession(
            self.attachment_epoch,
            {"backend": -1, "state": -1, "geocode": -1, "auto": -1, "timeline": -1},
        )
        self.attachment_sessions[client] = session
        self.active_attachment_epoch = session.epoch
        if connected:
            self.clients.add(client)

        # A socket attachment is the epoch handshake.  Work from an overlapping
        # hot-reload predecessor must neither publish nor overtake the replacement.
        self.pending = None
        self.deferred = None
        # Detach the predecessor's authority as part of the epoch handoff.
        # Keeping a cancelled token installed would make the replacement's
        # first observational probe capture authority that can never be current.
        old_apply_token = self.apply_token
        self.apply_token = None
        if old_apply_token is not None:
            old_apply_token.set()
        self.network_token = {"geocode": None, "auto": None}
        self.timeline_token = None
        for attached in self.clients:
            if attached is client:
                continue
            for task in list(attached.tasks.values()):
                task.cancel()
            attached.tasks.clear()
            for task in list(getattr(attached, "timeline_tasks", ())):
                task.cancel()
        return session

    def is_current_client(self, client: Any) -> bool:
        session = self.attachment_sessions.get(client)
        return bool(session and session.epoch == self.active_attachment_epoch)

    def accept_generation(self, client: Any, family: str, generation: int) -> bool:
        session = self.attachment_sessions.get(client)
        if session is None:
            session = self.activate_client(client)
        if session.epoch != self.active_attachment_epoch:
            return False
        if generation < session.generation_floor[family]:
            return False
        session.generation_floor[family] = generation
        return True

    def generation_is_current(self, client: Any, family: str, generation: int) -> bool:
        session = self.attachment_sessions.get(client)
        return bool(
            session
            and session.epoch == self.active_attachment_epoch
            and generation == session.generation_floor[family]
        )

    def apply_is_current(self, client: Any, token: ApplyToken) -> bool:
        session = self.attachment_sessions.get(client)
        return bool(
            not token.is_set()
            and session
            and session.epoch == token.attachment_epoch == self.active_attachment_epoch
            and session.generation_floor["backend"] == token.generation
            and self.apply_token is token
        )

    def observation_is_current(
        self,
        client: Any | None,
        expected_epoch: int,
        expected_token: ApplyToken | None,
    ) -> bool:
        if self.closing or self.active_attachment_epoch != expected_epoch:
            return False
        if self.apply_token is not expected_token:
            return False
        if expected_token is not None and expected_token.is_set():
            return False
        if client is None:
            return True
        session = self.attachment_sessions.get(client)
        return bool(session and session.epoch == expected_epoch)

    async def dispatch(self, client: Client, request: Any) -> None:
        valid, code = self.valid_request(request)
        if not valid:
            await self.error(client, request, code, "invalid controller request")
            return
        if client not in self.attachment_sessions:
            # Direct dispatch is also used by deterministic unit clients which
            # have no stream lease; real socket clients are tracked in handle_client.
            self.activate_client(client, connected=False)
        operation = request["operation"]
        generation = request["generation"]
        if not self.is_current_client(client):
            await self.error(client, request, "stale-generation", "attachment is obsolete")
            return
        if operation == "probe":
            epoch = self.attachment_sessions[client].epoch
            token = self.apply_token
            try:
                actual = await self.observe(client, epoch, token)
            except Exception:
                if not self.observation_is_current(client, epoch, token):
                    await self.error(client, request, "stale-generation", "request is obsolete")
                    return
            else:
                if actual is None:
                    await self.error(client, request, "stale-generation", "request is obsolete")
                    return
            await self.broadcast_status(
                request, client, expected_epoch=epoch, expected_token=token
            )
        elif operation == "setDesired":
            if not self.accept_generation(client, "backend", generation):
                await self.error(client, request, "stale-generation", "request is obsolete")
                return
            try:
                desired = validate_desired(request.get("desired"))
                if_actual = (
                    validate_desired(request.get("ifActual"))
                    if "ifActual" in request else None
                )
            except ValueError as exc:
                await self.error(client, request, "invalid-request", str(exc))
                return
            intent = request.get("intent")
            if intent not in ("schedule", "override"):
                await self.error(client, request, "invalid-request", "invalid intent")
                return
            until = request.get("overrideUntil")
            if until is not None and (isinstance(until, bool) or not isinstance(until, (int, float)) or not math.isfinite(until) or until < 0):
                await self.error(client, request, "invalid-request", "invalid override expiry")
                return
            if intent == "override":
                self.runtime_override = {"target": desired, "until": until or 0, "source": "panel"}
            else:
                if until is not None:
                    self.last_schedule_boundary = int(until)
                if request.get("resume") is True or (self.runtime_override and self.runtime_override.get("until", 0) <= time.time() * 1000):
                    self.runtime_override = None
                if self.runtime_override:
                    await self.broadcast_status(
                        request, client,
                        expected_epoch=self.attachment_sessions[client].epoch,
                    )
                    return
            metadata = request_fields(request)
            self.deferred = None
            if self.apply_token is not None:
                self.apply_token.set()
            token = ApplyToken(
                generation,
                self.attachment_sessions[client].epoch,
                if_actual if intent == "schedule" else None,
            )
            self.apply_token = token
            self.pending = (desired, client, metadata, token)
            self.apply_event.set()
        elif operation == "projectCivilDay":
            if not self.accept_generation(client, "timeline", generation):
                await self.error(client, request, "stale-generation", "request is obsolete")
                return
            epoch = self.attachment_sessions[client].epoch
            timeline_token = object()
            self.timeline_token = timeline_token

            def timeline_is_current() -> bool:
                return bool(
                    self.timeline_token is timeline_token
                    and self.generation_is_current(client, "timeline", generation)
                    and self.attachment_sessions.get(client) is not None
                    and self.attachment_sessions[client].epoch == epoch
                )

            try:
                projection = await asyncio.to_thread(project_civil_day, request)
            except ValueError as exc:
                if timeline_is_current():
                    await self.error(client, request, "invalid-request", str(exc))
                return
            if not timeline_is_current():
                return
            response = {
                "protocol": PROTOCOL,
                "type": "civilDay",
                **request_fields(request),
                "projection": projection,
            }
            await client.send(response, guard=timeline_is_current)
        elif operation == "readLocationState":
            outcome, state = await asyncio.to_thread(self.store.read)
            await client.send({"protocol": PROTOCOL, "type": "locationState", "outcome": outcome, "state": state, **request_fields(request)})
        elif operation == "writeLocationState":
            if not self.accept_generation(client, "state", generation):
                await self.error(client, request, "stale-generation", "request is obsolete")
                return
            try:
                async with self.state_transaction_lock:
                    if not self.generation_is_current(client, "state", generation):
                        await self.error(client, request, "stale-generation", "request is obsolete")
                        return
                    state = await asyncio.to_thread(self.store.write, request.get("state"), request.get("expectedRevision"))
                if self.generation_is_current(client, "state", generation):
                    await client.send({"protocol": PROTOCOL, "type": "locationState", "outcome": "valid", "state": state, **request_fields(request)})
            except StateError as exc:
                await self.error(client, request, exc.code, str(exc))
        elif operation == "forgetLocationState":
            if not self.accept_generation(client, "state", generation):
                await self.error(client, request, "stale-generation", "request is obsolete")
                return
            try:
                async with self.state_transaction_lock:
                    if not self.generation_is_current(client, "state", generation):
                        await self.error(client, request, "stale-generation", "request is obsolete")
                        return
                    await asyncio.to_thread(self.store.forget, request.get("expectedRevision"))
                # Forget is also an immediate privacy cancellation barrier.
                session = self.attachment_sessions[client]
                session.generation_floor["geocode"] = max(session.generation_floor["geocode"], generation)
                session.generation_floor["auto"] = max(session.generation_floor["auto"], generation)
                self.network_token = {"geocode": None, "auto": None}
                for attached in self.clients:
                    for task in list(attached.tasks.values()):
                        task.cancel()
                    attached.tasks.clear()
                await client.send({"protocol": PROTOCOL, "type": "locationState", "outcome": "absent", "state": None, **request_fields(request)})
            except StateError as exc:
                await self.error(client, request, exc.code, str(exc))
        elif operation in ("geocode", "autoLocate"):
            family = "geocode" if operation == "geocode" else "auto"
            if operation == "autoLocate":
                outcome, persisted = await asyncio.to_thread(self.store.read)
                if outcome != "valid" or persisted is None or persisted["autoConsentVersion"] != 1:
                    await self.error(client, request, "consent-required", "approximate location requires consent")
                    return
            if not self.accept_generation(client, family, generation):
                await self.error(client, request, "stale-generation", "request is obsolete")
                return
            epoch = self.attachment_sessions[client].epoch
            if family == "geocode":
                token = (epoch, generation, request.get("searchEpoch"), " ".join(str(request.get("query", "")).split()))
            else:
                token = (epoch, generation, request.get("locationEpoch"))
            self.network_token[family] = token
            request_id = str(request["requestId"])
            old = client.tasks.pop(request_id, None)
            if old:
                old.cancel()
            task = asyncio.create_task(self.network_operation(client, request, family))
            client.tasks[request_id] = task
        elif operation == "cancel":
            target = str(request.get("cancelRequestId", request.get("requestId")))
            task = client.tasks.pop(target, None)
            if task:
                task.cancel()
            await client.send({"protocol": PROTOCOL, "type": "networkResult", "cancelled": True, **request_fields(request)})
        else:
            await self.error(client, request, "unknown-operation", "unknown controller operation")

    async def network_operation(self, client: Client, request: dict[str, Any], family: str) -> None:
        session = self.attachment_sessions.get(client)
        if session is None:
            return
        if family == "geocode":
            token = (session.epoch, request["generation"], request.get("searchEpoch"), " ".join(str(request.get("query", "")).split()))
        else:
            token = (session.epoch, request["generation"], request.get("locationEpoch"))
        try:
            if family == "geocode":
                payload = await asyncio.to_thread(self.provider.geocode, request.get("query"), request.get("language", "en"))
                extra = {"results": payload, "searchEpoch": request.get("searchEpoch"), "query": token[3]}
            else:
                payload = await asyncio.to_thread(self.provider.auto_locate)
                extra = {"result": payload, "locationEpoch": request.get("locationEpoch")}
            if token != self.network_token[family] or not self.is_current_client(client):
                return
            await client.send({"protocol": PROTOCOL, "type": "networkResult", "ok": True, **extra, **request_fields(request)})
        except asyncio.CancelledError:
            return
        except NetworkError as exc:
            if token == self.network_token[family] and self.is_current_client(client):
                await self.error(client, request, exc.code, str(exc))
        finally:
            request_id = str(request["requestId"])
            if client.tasks.get(request_id) is asyncio.current_task():
                client.tasks.pop(request_id, None)

    async def apply_loop(self) -> None:
        while True:
            await self.apply_event.wait()
            self.apply_event.clear()
            while self.pending is not None:
                desired, client, metadata, token = self.pending
                self.pending = None
                if not self.backend_ready:
                    try:
                        await self._initialize_backend()
                        self.backend_ready = True
                        self.backend_error = None
                    except Exception:
                        if not self.apply_is_current(client, token):
                            continue
                        self.backend_error = "backend-unavailable"
                        self.deferred = (desired, client, metadata, token)
                        await self.broadcast_status(
                            metadata, client,
                            expected_epoch=token.attachment_epoch,
                            expected_token=token,
                        )
                        break
                if not self.apply_is_current(client, token):
                    continue
                success = False
                superseded = False
                for delay in (0.0, 0.25, 1.0):
                    if delay:
                        try:
                            await asyncio.wait_for(token.wait(), timeout=delay)
                        except asyncio.TimeoutError:
                            pass
                    # The immutable token closes retry, backend rate-limit, and
                    # already-running mutating-child waits when work is replaced.
                    if not self.apply_is_current(client, token):
                        superseded = True
                        break
                    self.apply_idle.clear()
                    try:
                        apply_kwargs: dict[str, Any] = {"superseded": token}
                        if token.if_actual is not None:
                            apply_kwargs["if_actual"] = token.if_actual
                        await self.backend.apply(desired, **apply_kwargs)
                        if not self.apply_is_current(client, token):
                            superseded = True
                            break
                        success = True
                        self.backend_error = None
                        break
                    except ApplySuperseded:
                        superseded = True
                        break
                    except ExternalActual as external:
                        if not self.apply_is_current(client, token):
                            superseded = True
                            break
                        self.backend.actual = external.actual
                        self.backend_ready = True
                        self.backend_error = None
                        self.runtime_override = {
                            "target": {
                                "kind": external.actual.kind,
                                **(
                                    {"temperature": external.actual.temperature}
                                    if external.actual.kind == "temperature" else {}
                                ),
                            },
                            "until": self.last_schedule_boundary or 0,
                            "source": "external",
                        }
                        self.pending = None
                        self.deferred = None
                        await self.broadcast_status(
                            metadata,
                            client,
                            expected_epoch=token.attachment_epoch,
                            expected_token=token,
                        )
                        token.set()
                        if self.apply_token is token:
                            self.apply_token = None
                        superseded = True
                        break
                    except Exception:
                        if not self.apply_is_current(client, token):
                            superseded = True
                            break
                        self.backend_error = "apply-failed"
                    finally:
                        self.apply_idle.set()
                if superseded or not self.apply_is_current(client, token):
                    continue
                if not success:
                    self.backend_ready = False
                    self.deferred = (desired, client, metadata, token)
                await self.broadcast_status(
                    metadata, client,
                    expected_epoch=token.attachment_epoch,
                    expected_token=token,
                )

    async def observe(
        self,
        client: Any | None,
        expected_epoch: int,
        expected_token: ApplyToken | None,
    ) -> Actual | None:
        previous = self.backend.actual
        observation = await self.backend.probe_reconciled(
            lambda: self.observation_is_current(client, expected_epoch, expected_token)
        )
        # The backend checks attachment authority under the same lock as the
        # probe and possible-attempt reconciliation.  A predecessor observation
        # can therefore publish neither cache nor ownership after hot reload.
        if observation is None:
            return None
        actual, controller_owned = observation
        self.backend_ready = True
        self.backend_error = None
        if previous is not None and actual != previous and not controller_owned:
            self.runtime_override = {
                "target": {"kind": actual.kind, **({"temperature": actual.temperature} if actual.kind == "temperature" else {})},
                "until": self.last_schedule_boundary or 0,
                "source": "external",
            }
            self.pending = None
            if self.apply_token is not None:
                self.apply_token.set()
        return actual

    async def _health_iteration(self) -> None:
        epoch = self.active_attachment_epoch
        token = self.apply_token
        recovered = False
        try:
            actual = await self.observe(None, epoch, token)
            if actual is None:
                return
            recovered = True
        except Exception:
            # A failed probe from superseded authority must not downgrade or
            # restart the replacement's backend.  Under current authority,
            # recover the same way startup/apply does: initialize() first waits
            # for an existing session daemon and starts one only when none
            # exists.  This makes an owned hyprsunset disappearing after login
            # self-healing instead of leaving the widget unavailable forever.
            if not self.observation_is_current(None, epoch, token):
                return
            try:
                await self._initialize_backend()
                if not self.observation_is_current(None, epoch, token):
                    return
                self.backend_ready = True
                self.backend_error = None
                recovered = True
            except Exception:
                if not self.observation_is_current(None, epoch, token):
                    return
                self.backend_ready = False
                self.backend_error = "backend-unavailable"
        # Publication is part of the health observation transaction. Bind it
        # to the exact captured apply authority, including None: a health status
        # blocked in output must not consume an ack created later.
        await self.broadcast_status(expected_epoch=epoch, expected_token=token)
        if recovered and self.deferred is not None and self.pending is None and self.runtime_override is None:
            # Publish health first. The attached Service immediately sends its
            # freshly recalculated (possibly newly persisted) target, replacing
            # deferred work. Retain a bounded fallback for other protocol
            # callers so deferred health recovery is not weakened.
            deferred = self.deferred
            await asyncio.sleep(0.1)
            if (
                self.deferred is deferred
                and self.pending is None
                and self.runtime_override is None
                and self.observation_is_current(None, epoch, token)
            ):
                self.pending = deferred
                self.deferred = None
                self.apply_event.set()

    async def health_loop(self) -> None:
        while True:
            await asyncio.sleep(30)
            await self._health_iteration()

    async def close(self) -> None:
        # Stop admission first.  An apply already past its final token check is
        # allowed to finish and record last_ack; only then may release perform
        # its compare-and-swap.  If it exceeds the transaction's bound, task
        # cancellation terminates and reaps the tracked child.
        self.closing = True
        self.backend.accepting_applies = False
        self.pending = None
        self.deferred = None
        if self.apply_token is not None:
            self.apply_token.set(stop_mutating_child=False)
        if self.release_task:
            self.release_task.cancel()
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        for client in list(self.clients):
            client.writer.close()

        if self.health_task:
            self.health_task.cancel()
            await asyncio.gather(self.health_task, return_exceptions=True)
        stop_mutations = getattr(self.backend, "stop_mutating_processes", None)
        if self.apply_task:
            try:
                await asyncio.wait_for(
                    asyncio.shield(self.apply_idle.wait()), SHUTDOWN_APPLY_TIMEOUT
                )
            except asyncio.TimeoutError:
                self.apply_task.cancel()
            else:
                self.apply_task.cancel()

            # apply_task cancellation cannot cancel initialization: Popen may
            # already have created hyprsunset while its to_thread caller has not
            # returned.  Await that launch lifecycle before allowing release to
            # inspect started/owned_pid.
            initialization = self.initialization_task
            if initialization is not None:
                await asyncio.gather(initialization, return_exceptions=True)
            if stop_mutations is not None:
                await stop_mutations()
            await asyncio.gather(self.apply_task, return_exceptions=True)
        else:
            initialization = self.initialization_task
            if initialization is not None:
                await asyncio.gather(initialization, return_exceptions=True)
            if stop_mutations is not None:
                await stop_mutations()

        # This barrier is deliberately immediately adjacent to release: once it
        # returns there is no old process that can perform a stale post-CAS write.
        if stop_mutations is not None:
            await stop_mutations()
        await self.backend.release()
        with contextlib.suppress(FileNotFoundError):
            self.socket_path.unlink()
        # Keep the inode linked while locked.  Removing a locked flock file opens
        # a split-lock race; a harmless private zero-byte lock is safer.
        if self.lock_fd is not None:
            fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            os.close(self.lock_fd)
            self.lock_fd = None


def request_fields(request: dict[str, Any]) -> dict[str, Any]:
    result = {}
    for key in ("requestId", "generation"):
        if key in request:
            result[key] = request[key]
    return result


async def daemon_main() -> int:
    try:
        directory = runtime_dir()
    except Exception:
        return 2
    daemon = ControllerDaemon(directory)
    if not daemon.acquire():
        return 0
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, daemon.stop_event.set)
    try:
        await daemon.start()
        await daemon.stop_event.wait()
    finally:
        await daemon.close()
    return 0


def _connect_socket(path: pathlib.Path) -> socket.socket:
    info = path.lstat()
    if (
        not stat.S_ISSOCK(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) & 0o077
    ):
        raise PermissionError("controller socket has an invalid owner or type")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(os.fspath(path))
        if hasattr(socket, "SO_PEERCRED"):
            credentials = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
            _pid, uid, _gid = __import__("struct").unpack("3i", credentials)
            if uid != os.getuid():
                raise PermissionError("controller peer has a different owner")
        return sock
    except BaseException:
        sock.close()
        raise


async def attach_main() -> int:
    try:
        directory = runtime_dir()
    except Exception as exc:
        print(json.dumps({"protocol": PROTOCOL, "type": "error", "code": "runtime-unavailable", "message": str(exc)}), flush=True)
        return 2
    path = directory / "control.sock"
    sock: socket.socket | None = None
    deadline = time.monotonic() + 6.0
    last_spawn = 0.0
    while time.monotonic() < deadline:
        try:
            sock = await asyncio.to_thread(_connect_socket, path)
            break
        except (FileNotFoundError, ConnectionRefusedError, OSError):
            now = time.monotonic()
            # Retrying the starter closes the narrow race where an old daemon
            # holds flock while finishing its CAS cleanup.  flock still ensures
            # that at most one starter becomes a writer.
            if now - last_spawn >= 0.25:
                subprocess.Popen(
                    [sys.executable, str(pathlib.Path(__file__).resolve()), "daemon"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True, close_fds=True, env=os.environ.copy(),
                )
                last_spawn = now
            await asyncio.sleep(0.05)
    if sock is None:
        print(json.dumps({"protocol": PROTOCOL, "type": "error", "code": "controller-unavailable", "message": "controller did not start"}), flush=True)
        return 1
    sock.setblocking(False)
    reader, writer = await asyncio.open_unix_connection(sock=sock, limit=MAX_LINE + 1)

    stdin_reader = asyncio.StreamReader(limit=MAX_LINE + 1)
    stdin_protocol = asyncio.StreamReaderProtocol(stdin_reader)
    await asyncio.get_running_loop().connect_read_pipe(lambda: stdin_protocol, sys.stdin.buffer)

    async def input_pump() -> None:
        while True:
            try:
                line = await stdin_reader.readline()
            except (ValueError, asyncio.LimitOverrunError):
                writer.close()
                return
            if not line:
                with contextlib.suppress(Exception):
                    writer.write_eof()
                return
            if len(line) > MAX_LINE or not line.endswith(b"\n"):
                writer.close()
                return
            writer.write(line)
            await writer.drain()

    async def output_pump() -> None:
        while True:
            line = await reader.readline()
            if not line:
                return
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()

    input_task = asyncio.create_task(input_pump())
    output_task = asyncio.create_task(output_pump())
    done, pending = await asyncio.wait((input_task, output_task), return_when=asyncio.FIRST_COMPLETED)
    # On stdin EOF, close the lease immediately.  On daemon EOF, stop reading stdin.
    writer.close()
    with contextlib.suppress(Exception):
        await writer.wait_closed()
    for task in pending:
        task.cancel()
    return 0


def main() -> int:
    os.umask(0o077)
    if len(sys.argv) != 2 or sys.argv[1] not in ("attach", "daemon"):
        print("usage: Controller.py attach", file=sys.stderr)
        return 2
    if sys.argv[1] == "attach":
        return asyncio.run(attach_main())
    return asyncio.run(daemon_main())


if __name__ == "__main__":
    raise SystemExit(main())
