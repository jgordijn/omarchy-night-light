#!/usr/bin/env python3
"""Deterministic controller tests.  No test talks to Hyprland or the network."""

from __future__ import annotations

import asyncio
import contextlib
import importlib.util
import json
import os
import pathlib
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("night_light_controller", ROOT / "Controller.py")
assert SPEC and SPEC.loader
controller = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = controller
SPEC.loader.exec_module(controller)


def location(source="weather", precision="selected-locality"):
    return {
        "label": "Test locality", "admin1": "", "country": "",
        "latitude": 52.1, "longitude": 5.1, "timezone": "Europe/Amsterdam",
        "source": source, "precision": precision, "observedAt": "2026-09-01T10:00:00Z",
    }


def state(mode="weather"):
    return {
        "schemaVersion": 1, "revision": 99, "mode": mode,
        "autoConsentVersion": 0, "manual": None,
        "weatherCache": location(), "autoIpCache": None,
    }


class LocationStoreTests(unittest.TestCase):
    def test_atomic_private_round_trip_revision_and_unknown_key_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "private" / "location.json"
            store = controller.LocationStore(path)
            candidate = state()
            candidate["unknown"] = "not persisted"
            saved = store.write(candidate, expected_revision=0)
            self.assertEqual(saved["revision"], 1)
            self.assertNotIn("unknown", saved)
            outcome, loaded = store.read()
            self.assertEqual(outcome, "valid")
            self.assertEqual(loaded, saved)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            with self.assertRaises(controller.StateError) as conflict:
                store.write(candidate, expected_revision=0)
            self.assertEqual(conflict.exception.code, "revision-conflict")
            self.assertEqual(store.read()[1], saved)

    def test_malformed_and_unsupported_are_distinct_and_never_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "location.json"
            path.write_text("{partial")
            path.chmod(0o600)
            store = controller.LocationStore(path)
            self.assertEqual(store.read()[0], "malformed")
            original = path.read_bytes()
            with self.assertRaises(controller.StateError):
                store.write(state())
            self.assertEqual(path.read_bytes(), original)
            path.write_text('{"schemaVersion":2}')
            path.chmod(0o600)
            self.assertEqual(store.read()[0], "unsupported-schema")

    def test_validation_rejects_nonfinite_wrong_pair_and_incomplete_modes(self):
        bad = state()
        bad["weatherCache"] = {**location(), "latitude": float("nan")}
        with self.assertRaises(ValueError):
            controller.validate_state(bad)
        bad = state()
        bad["weatherCache"] = {**location(), "source": "auto-ip"}
        with self.assertRaises(ValueError):
            controller.validate_state(bad)
        bad = state("manual")
        with self.assertRaises(ValueError):
            controller.validate_state(bad)

    def test_failed_replace_preserves_prior_bytes_and_forget_is_cas(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "private" / "location.json"
            store = controller.LocationStore(path)
            saved = store.write(state())
            before = path.read_bytes()
            with mock.patch.object(controller.os, "replace", side_effect=OSError("fake failure")):
                with self.assertRaises(controller.StateError):
                    store.write(state(), expected_revision=saved["revision"])
            self.assertEqual(path.read_bytes(), before)
            with self.assertRaises(controller.StateError):
                store.forget(expected_revision=0)
            self.assertTrue(path.exists())
            store.forget(expected_revision=saved["revision"])
            self.assertFalse(path.exists())


class ProviderTests(unittest.TestCase):
    def test_geocode_is_bounded_canonical_and_query_is_url_encoded(self):
        calls = []

        def fake(host, path, *, deadline):
            calls.append((host, path, deadline))
            return {"results": [{
                "name": "A City", "admin1": "Region", "country": "Country",
                "latitude": 1.25, "longitude": 2.5, "timezone": "Etc/UTC",
            }]}

        client = controller.ProviderClient(fake)
        results = client.geocode("  A City & region  ", "nl-NL")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["source"], "manual-search")
        self.assertEqual(calls[0][0], "geocoding-api.open-meteo.com")
        self.assertIn("name=A+City+%26+region", calls[0][1])
        self.assertLessEqual(len(results), 5)

    def test_429_has_only_two_bounded_retries(self):
        calls = 0

        def fake(host, path, *, deadline):
            nonlocal calls
            calls += 1
            raise controller.NetworkError("rate-limited", "no")

        client = controller.ProviderClient(fake)
        with mock.patch.object(controller.time, "sleep"):
            with self.assertRaises(controller.NetworkError) as caught:
                client.auto_locate()
        self.assertEqual(caught.exception.code, "rate-limited")
        self.assertEqual(calls, 3)

    def test_https_primitive_rejects_non_allowlisted_host_before_io(self):
        with self.assertRaises(controller.NetworkError) as caught:
            controller.ProviderClient._request_json("example.com", "/", deadline=time.monotonic() + 1)
        self.assertEqual(caught.exception.code, "network-denied")


class FakeHyprctl:
    """Creates a fake executable that records argv and emulates state."""

    SCRIPT = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
state_path = pathlib.Path(os.environ["FAKE_HYPR_STATE"])
log_path = pathlib.Path(os.environ["FAKE_HYPR_LOG"])
write_log_path = pathlib.Path(os.environ["FAKE_HYPR_WRITE_LOG"])
with log_path.open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
state = json.loads(state_path.read_text())
args = sys.argv[1:]
block_path = os.environ.get("FAKE_HYPR_BLOCK_MUTATION")
gate_path = os.environ.get("FAKE_HYPR_MUTATION_GATE")
if block_path and gate_path and args == ["hyprsunset", "temperature", "4100"]:
    pathlib.Path(block_path).write_text("entered")
    deadline = __import__("time").monotonic() + 5
    while not pathlib.Path(gate_path).exists():
        if __import__("time").monotonic() >= deadline:
            raise SystemExit(8)
        __import__("time").sleep(0.005)
verification_path = os.environ.get("FAKE_HYPR_BLOCK_VERIFICATION")
verification_gate = os.environ.get("FAKE_HYPR_VERIFICATION_GATE")
if (verification_path and verification_gate
        and args == ["hyprsunset", "identity", "get"]
        and not state["identity"] and state["temperature"] == 4100):
    pathlib.Path(verification_path).write_text("entered")
    deadline = __import__("time").monotonic() + 5
    while not pathlib.Path(verification_gate).exists():
        if __import__("time").monotonic() >= deadline:
            raise SystemExit(9)
        __import__("time").sleep(0.005)
if args == ["hyprsunset", "identity", "get"]:
    print("true" if state["identity"] else "false")
elif args == ["hyprsunset", "temperature"]:
    print(state["temperature"])
elif args == ["hyprsunset", "gamma"]:
    print(state["gamma"])
elif args == ["hyprsunset", "identity", "true"]:
    if os.environ.get("FAKE_HYPR_FAIL_IDENTITY"):
        raise SystemExit(10)
    state["identity"] = True
    state_path.write_text(json.dumps(state))
    with write_log_path.open("a") as stream: stream.write(json.dumps(args) + "\n")
elif len(args) == 3 and args[:2] == ["hyprsunset", "temperature"]:
    state["temperature"] = int(args[2]); state["identity"] = False
    state_path.write_text(json.dumps(state))
    with write_log_path.open("a") as stream: stream.write(json.dumps(args) + "\n")
else:
    raise SystemExit(7)
'''

    def __init__(self, directory: pathlib.Path):
        self.executable = directory / "hyprctl"
        self.state = directory / "state.json"
        self.log = directory / "argv.jsonl"
        self.write_log = directory / "writes.jsonl"
        self.executable.write_text(self.SCRIPT)
        self.executable.chmod(0o700)
        self.state.write_text(json.dumps({"identity": False, "temperature": 4777, "gamma": 100}))
        self.log.write_text("")
        self.write_log.write_text("")

    def environment(self):
        return {
            "NIGHT_LIGHT_HYPRCTL": str(self.executable),
            "FAKE_HYPR_STATE": str(self.state),
            "FAKE_HYPR_LOG": str(self.log),
            "FAKE_HYPR_WRITE_LOG": str(self.write_log),
        }

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def writes(self):
        return [json.loads(line) for line in self.write_log.read_text().splitlines()]


class BackendTests(unittest.IsolatedAsyncioTestCase):
    async def test_probe_and_apply_use_only_safe_separate_argv(self):
        with tempfile.TemporaryDirectory() as temporary:
            fake = FakeHyprctl(pathlib.Path(temporary))
            with mock.patch.dict(os.environ, fake.environment(), clear=False):
                backend = controller.Backend()
                actual = await backend.probe()
                self.assertEqual((actual.kind, actual.temperature), ("temperature", 4777))
                await backend.apply({"kind": "identity"})
            calls = fake.calls()
            self.assertIn(["hyprsunset", "identity", "get"], calls)
            self.assertIn(["hyprsunset", "identity", "true"], calls)
            self.assertNotIn(["hyprsunset", "identity"], calls)
            self.assertNotIn(["hyprsunset", "reset"], calls)
            self.assertTrue(all(isinstance(call, list) for call in calls))

    async def test_matching_apply_has_zero_writes_but_divergence_reconciles(self):
        with tempfile.TemporaryDirectory() as temporary:
            fake = FakeHyprctl(pathlib.Path(temporary))
            with mock.patch.dict(os.environ, fake.environment(), clear=False):
                backend = controller.Backend()
                matching = {"kind": "temperature", "temperature": 4777}
                actual = await backend.apply(matching)
                self.assertTrue(actual.matches(matching))
                self.assertIsNone(backend.last_ack, "an observation must not claim write ownership")

                writes = [
                    call for call in fake.calls()
                    if call == ["hyprsunset", "identity", "true"]
                    or (len(call) == 3 and call[:2] == ["hyprsunset", "temperature"])
                ]
                self.assertEqual(writes, [])

                # A genuinely different schedule target is still applied and
                # verified, and repeating it becomes observational again.
                await backend.apply({"kind": "identity"})
                count_after_reconcile = len(fake.calls())
                await backend.apply({"kind": "identity"})
            writes = [
                call for call in fake.calls()
                if call == ["hyprsunset", "identity", "true"]
                or (len(call) == 3 and call[:2] == ["hyprsunset", "temperature"])
            ]
            self.assertEqual(writes, [["hyprsunset", "identity", "true"]])
            self.assertGreater(len(fake.calls()), count_after_reconcile, "no-op still probes")

    async def test_compare_and_swap_release_restores_shared_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            fake = FakeHyprctl(pathlib.Path(temporary))
            with mock.patch.dict(os.environ, fake.environment(), clear=False):
                backend = controller.Backend()
                backend.baseline = await backend.probe()
                await backend.apply({"kind": "identity"})
                await backend.release()
            restored = json.loads(fake.state.read_text())
            self.assertFalse(restored["identity"])
            self.assertEqual(restored["temperature"], 4777)

    async def test_compare_and_swap_release_leaves_external_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            fake = FakeHyprctl(pathlib.Path(temporary))
            with mock.patch.dict(os.environ, fake.environment(), clear=False):
                backend = controller.Backend()
                backend.baseline = await backend.probe()
                await backend.apply({"kind": "identity"})
                fake.state.write_text(json.dumps({"identity": False, "temperature": 3333, "gamma": 100}))
                call_count = len(fake.calls())
                await backend.release()
            self.assertEqual(json.loads(fake.state.read_text())["temperature"], 3333)
            later = fake.calls()[call_count:]
            self.assertFalse(any(call[:2] == ["hyprsunset", "identity"] and call[-1] == "true" for call in later))
            self.assertFalse(any(call[:2] == ["hyprsunset", "temperature"] and len(call) == 3 for call in later))

    @staticmethod
    def record_owned_child(backend, child):
        info = backend._process_info(child.pid)
        if info is None:
            raise AssertionError("fake child identity was not observable")
        backend.started = True
        backend.owned_pid = child.pid
        backend.owned_exe = info[0]
        backend.owned_start = info[1]
        backend.owned_signature = backend.signature

    async def test_owned_release_reports_restoration_failure_but_stops_exact_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            signature = "restoration-failure-live-child"
            executable = os.path.realpath(sys.executable)
            environment = {
                **fake.environment(),
                "FAKE_HYPR_FAIL_IDENTITY": "1",
                "HYPRLAND_INSTANCE_SIGNATURE": signature,
                "NIGHT_LIGHT_HYPRSUNSET": executable,
            }
            children = []
            with mock.patch.dict(os.environ, environment, clear=False):
                backend = controller.Backend()
                owned = subprocess.Popen(
                    [executable, "-c", "import time; time.sleep(30)"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, env=os.environ.copy(),
                )
                shared = subprocess.Popen(
                    [executable, "-c", "import time; time.sleep(30)"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, env=os.environ.copy(),
                )
                children.extend((owned, shared))
                try:
                    self.record_owned_child(backend, owned)
                    backend.last_ack = {"kind": "temperature", "temperature": 4777}

                    with self.assertRaisesRegex(RuntimeError, "backend command failed"):
                        await backend.release()

                    self.assertFalse(
                        pathlib.Path(f"/proc/{owned.pid}").exists(),
                        "failed identity restoration orphaned the owned daemon",
                    )
                    self.assertIsNone(shared.poll(), "a shared process was stopped")
                finally:
                    for child in children:
                        if child.poll() is None:
                            child.kill()
                        with contextlib.suppress(subprocess.TimeoutExpired):
                            child.wait(timeout=1)

    async def test_owned_release_escalates_term_resistant_child_to_kill(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            ready = root / "ready"
            term_seen = root / "term-seen"
            signature = "term-resistant-live-child"
            executable = os.path.realpath(sys.executable)
            environment = {
                "HYPRLAND_INSTANCE_SIGNATURE": signature,
                "NIGHT_LIGHT_HYPRSUNSET": executable,
            }
            script = (
                "import pathlib, signal, sys, time\n"
                "term = pathlib.Path(sys.argv[1])\n"
                "signal.signal(signal.SIGTERM, lambda *_: term.write_text('term'))\n"
                "pathlib.Path(sys.argv[2]).write_text('ready')\n"
                "while True: time.sleep(1)\n"
            )
            with mock.patch.dict(os.environ, environment, clear=False):
                backend = controller.Backend()
                child = subprocess.Popen(
                    [executable, "-c", script, str(term_seen), str(ready)],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, env=os.environ.copy(),
                )
                try:
                    deadline = time.monotonic() + 1
                    while not ready.exists() and time.monotonic() < deadline:
                        await asyncio.sleep(0.005)
                    self.assertTrue(ready.exists(), "fake child did not install SIGTERM handler")
                    self.record_owned_child(backend, child)
                    sent = []
                    real_send_signal = controller.signal.pidfd_send_signal

                    def record_signal(pidfd, sig, *args):
                        sent.append(sig)
                        return real_send_signal(pidfd, sig, *args)

                    with mock.patch.object(backend, "probe", side_effect=RuntimeError("IPC failed")), \
                            mock.patch.object(
                                controller.signal, "pidfd_send_signal", side_effect=record_signal
                            ), \
                            mock.patch.object(controller, "PROCESS_TERMINATE_TIMEOUT", 0.05):
                        await backend.release()

                    self.assertTrue(term_seen.exists(), "SIGTERM was not delivered")
                    self.assertEqual(sent, [signal.SIGTERM, signal.SIGKILL])
                    self.assertFalse(pathlib.Path(f"/proc/{child.pid}").exists())
                finally:
                    if child.poll() is None:
                        child.kill()
                    with contextlib.suppress(subprocess.TimeoutExpired):
                        child.wait(timeout=1)

    async def test_close_waits_for_inflight_mutation_before_cas_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            entered = root / "mutation-entered"
            gate = root / "mutation-gate"
            environment = {
                **fake.environment(),
                "FAKE_HYPR_BLOCK_MUTATION": str(entered),
                "FAKE_HYPR_MUTATION_GATE": str(gate),
            }
            with mock.patch.dict(os.environ, environment, clear=False):
                daemon = controller.ControllerDaemon(root)
                daemon.backend.baseline = await daemon.backend.probe()
                daemon.backend_ready = True
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                client = RecordingClient()
                await daemon.dispatch(client, {
                    "protocol": 1, "requestId": "blocked", "generation": 1,
                    "operation": "setDesired",
                    "desired": {"kind": "temperature", "temperature": 4100},
                    "intent": "schedule",
                })

                async def wait_for_entry():
                    while not entered.exists():
                        await asyncio.sleep(0.002)

                await asyncio.wait_for(wait_for_entry(), 1)
                closing = asyncio.create_task(daemon.close())
                await asyncio.sleep(0.03)
                self.assertFalse(closing.done(), "release raced the mutating child")
                self.assertEqual(json.loads(fake.state.read_text())["temperature"], 4777)
                gate.write_text("continue")
                await asyncio.wait_for(closing, 2)

            # The blocked write completed before CAS, was acknowledged, and was
            # restored to the shared baseline.  Nothing can write after close.
            self.assertEqual(json.loads(fake.state.read_text())["temperature"], 4777)
            calls_at_close = fake.calls()
            self.assertIn(["hyprsunset", "temperature", "4100"], calls_at_close)
            self.assertIn(["hyprsunset", "temperature", "4777"], calls_at_close)
            await asyncio.sleep(0.05)
            self.assertEqual(fake.calls(), calls_at_close)

    async def test_close_timeout_terminates_mutation_before_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            entered = root / "mutation-entered"
            gate = root / "mutation-gate"
            environment = {
                **fake.environment(),
                "FAKE_HYPR_BLOCK_MUTATION": str(entered),
                "FAKE_HYPR_MUTATION_GATE": str(gate),
            }
            with mock.patch.dict(os.environ, environment, clear=False), \
                    mock.patch.object(controller, "SHUTDOWN_APPLY_TIMEOUT", 0.01):
                daemon = controller.ControllerDaemon(root)
                daemon.backend.baseline = await daemon.backend.probe()
                daemon.backend_ready = True
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                await daemon.dispatch(RecordingClient(), {
                    "protocol": 1, "requestId": "terminated", "generation": 1,
                    "operation": "setDesired",
                    "desired": {"kind": "temperature", "temperature": 4100},
                    "intent": "schedule",
                })

                async def wait_for_entry():
                    while not entered.exists():
                        await asyncio.sleep(0.002)

                await asyncio.wait_for(wait_for_entry(), 1)
                await asyncio.wait_for(daemon.close(), 2)
                gate.write_text("too-late")

            self.assertEqual(json.loads(fake.state.read_text())["temperature"], 4777)
            calls_at_close = fake.calls()
            await asyncio.sleep(0.05)
            self.assertEqual(fake.calls(), calls_at_close)

    async def test_close_waits_for_blocked_launch_and_stops_owned_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            signature = "blocked-launch-regression"
            created = threading.Event()
            launch_gate = threading.Event()
            child_holder = []
            real_popen = subprocess.Popen
            sleep_executable = os.path.realpath("/usr/bin/sleep")
            actual = controller.Actual("identity", 6500, 100)
            probe_calls = 0

            with mock.patch.dict(os.environ, {
                "HYPRLAND_INSTANCE_SIGNATURE": signature,
                "NIGHT_LIGHT_HYPRSUNSET": sleep_executable,
                "NIGHT_LIGHT_UWSM_APP": "/fake/uwsm-app",
            }, clear=False):
                backend = controller.Backend()

                def blocked_popen(*_args, **_kwargs):
                    # Model Popen having forked the configured daemon while the
                    # to_thread call has not returned to initialize() yet.
                    child = real_popen(
                        [sleep_executable, "30"], stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        start_new_session=True, close_fds=True,
                        env=os.environ.copy(),
                    )
                    child_holder.append(child)
                    created.set()
                    launch_gate.wait()
                    return child

                def matching_processes():
                    if not child_holder:
                        return []
                    child = child_holder[0]
                    info = backend._process_info(child.pid)
                    return [] if info is None else [(child.pid, info[0], info[1])]

                async def fake_probe(*, publish=True):
                    nonlocal probe_calls
                    probe_calls += 1
                    # Startup becomes ready exactly once, allowing initialize()
                    # to establish baseline and ownership.  The release probe
                    # then fails, as in the reported close-during-launch race.
                    if not created.is_set() or probe_calls != 2:
                        raise RuntimeError("IPC unavailable")
                    if publish:
                        backend.actual = actual
                    return actual

                daemon = controller.ControllerDaemon(root)
                daemon.backend = backend
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                try:
                    with mock.patch.object(controller.subprocess, "Popen", side_effect=blocked_popen), \
                            mock.patch.object(backend, "matching_processes", side_effect=matching_processes), \
                            mock.patch.object(backend, "probe", side_effect=fake_probe):
                        await daemon.dispatch(RecordingClient(), {
                            "protocol": 1, "requestId": "launch", "generation": 1,
                            "operation": "setDesired", "desired": {"kind": "identity"},
                            "intent": "schedule",
                        })

                        await asyncio.wait_for(asyncio.to_thread(created.wait), 1)
                        child = child_holder[0]
                        self.assertIsNone(child.poll())
                        self.assertFalse(daemon.apply_idle.is_set())

                        closing = asyncio.create_task(daemon.close())
                        await asyncio.sleep(0.03)
                        self.assertFalse(
                            closing.done(),
                            "close passed release before launch ownership was recorded",
                        )
                        self.assertIsNone(child.poll())

                        launch_gate.set()
                        await asyncio.wait_for(closing, 2)

                    self.assertTrue(backend.started)
                    self.assertEqual(backend.owned_pid, child.pid)
                    self.assertGreaterEqual(probe_calls, 3, "release failure path was not exercised")
                    child.wait(timeout=1)
                    self.assertIsNotNone(child.returncode, "owned launch survived close")
                finally:
                    launch_gate.set()
                    if not daemon.apply_task.done():
                        daemon.apply_task.cancel()
                        await asyncio.gather(daemon.apply_task, return_exceptions=True)
                    for child in child_holder:
                        if child.poll() is None:
                            child.terminate()
                            child.wait(timeout=1)


class RecordingClient:
    def __init__(self):
        self.messages = []
        self.tasks = {}

    async def send(self, value, *, guard=None):
        if guard is None or guard():
            self.messages.append(value)


class SlowBackend:
    def __init__(self):
        self.actual = controller.Actual("identity", 6500, 100)
        self.last_ack = None
        self.last_attempt = None
        self.applied = []

    async def initialize(self):
        return self.actual

    async def apply(self, desired, *, superseded=None):
        self.applied.append(desired)
        await asyncio.sleep(0.04)
        self.last_ack = desired
        self.actual = controller.Actual(desired["kind"], desired.get("temperature", 6500), 100)
        return self.actual

    async def probe(self, *, publish=True):
        return self.actual

    async def probe_reconciled(self, accept):
        actual = await self.probe(publish=False)
        if not accept():
            return None
        attempt = self.last_attempt
        self.last_attempt = None
        owned = actual.matches(self.last_ack)
        if attempt is not None and actual.matches(attempt):
            self.last_ack = attempt
            owned = True
        self.actual = actual
        return actual, owned

    async def release(self):
        pass


class BlockedProbeBackend(SlowBackend):
    def __init__(self):
        super().__init__()
        self.probe_entered = asyncio.Event()
        self.probe_gate = asyncio.Event()
        self.probed_actual = controller.Actual("temperature", 4100, 100)

    async def probe(self, *, publish=True):
        self.probe_entered.set()
        await self.probe_gate.wait()
        if publish:
            self.actual = self.probed_actual
        return self.probed_actual


class QueueAndGenerationTests(unittest.IsolatedAsyncioTestCase):
    @staticmethod
    async def wait_until(predicate, timeout=1.0):
        async def poll():
            while not predicate():
                await asyncio.sleep(0.005)
        await asyncio.wait_for(poll(), timeout)

    async def test_rate_limit_wait_is_token_aware_and_identity_preempts(self):
        with tempfile.TemporaryDirectory() as temporary:
            fake = FakeHyprctl(pathlib.Path(temporary))
            with mock.patch.dict(os.environ, fake.environment(), clear=False):
                daemon = controller.ControllerDaemon(pathlib.Path(temporary))
                daemon.backend = controller.Backend()
                daemon.backend_ready = True
                client = RecordingClient()
                daemon.clients.add(client)
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                try:
                    # The old request must already be inside Backend.apply's
                    # rate-limit wait when the replacement arrives.
                    daemon.backend.last_temperature_write = time.monotonic()
                    with mock.patch.object(controller, "TEMPERATURE_WRITE_INTERVAL", 0.12):
                        await daemon.dispatch(client, {
                            "protocol": 1, "requestId": "old-temperature", "generation": 1,
                            "operation": "setDesired",
                            "desired": {"kind": "temperature", "temperature": 4100},
                            "intent": "schedule",
                        })
                        old_token = daemon.apply_token
                        await self.wait_until(lambda: daemon.pending is None)
                        self.assertIsNotNone(old_token)
                        await daemon.dispatch(client, {
                            "protocol": 1, "requestId": "new-temperature", "generation": 2,
                            "operation": "setDesired",
                            "desired": {"kind": "temperature", "temperature": 4300},
                            "intent": "schedule",
                        })
                        await self.wait_until(
                            lambda: daemon.backend.last_ack == {"kind": "temperature", "temperature": 4300}
                        )
                    writes = [
                        call for call in fake.calls()
                        if (len(call) == 3 and call[:2] == ["hyprsunset", "temperature"])
                        or call == ["hyprsunset", "identity", "true"]
                    ]
                    self.assertEqual(writes, [["hyprsunset", "temperature", "4300"]])

                    # Identity has no temperature limit and wakes the old
                    # token, rather than sitting behind its full wait.
                    fake.log.write_text("")
                    daemon.backend.last_temperature_write = time.monotonic()
                    with mock.patch.object(controller, "TEMPERATURE_WRITE_INTERVAL", 2.0):
                        await daemon.dispatch(client, {
                            "protocol": 1, "requestId": "old-again", "generation": 3,
                            "operation": "setDesired",
                            "desired": {"kind": "temperature", "temperature": 4200},
                            "intent": "schedule",
                        })
                        await self.wait_until(lambda: daemon.pending is None)
                        await daemon.dispatch(client, {
                            "protocol": 1, "requestId": "identity", "generation": 4,
                            "operation": "setDesired", "desired": {"kind": "identity"},
                            "intent": "schedule",
                        })
                        await self.wait_until(
                            lambda: daemon.backend.last_ack == {"kind": "identity"}, timeout=0.75
                        )
                    writes = [
                        call for call in fake.calls()
                        if (len(call) == 3 and call[:2] == ["hyprsunset", "temperature"])
                        or call == ["hyprsunset", "identity", "true"]
                    ]
                    self.assertEqual(writes, [["hyprsunset", "identity", "true"]])
                finally:
                    daemon.apply_task.cancel()
                    with self.assertRaises(asyncio.CancelledError):
                        await daemon.apply_task

    async def test_matching_override_and_resume_keep_semantics_without_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            with mock.patch.dict(os.environ, fake.environment(), clear=False):
                daemon = controller.ControllerDaemon(root)
                daemon.backend = controller.Backend()
                await daemon.backend.probe()
                daemon.backend_ready = True
                client = RecordingClient()
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                try:
                    matching = {"kind": "temperature", "temperature": 4777}
                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": "override", "generation": 1,
                        "operation": "setDesired", "desired": matching,
                        "intent": "override", "overrideUntil": 123456,
                    })
                    await self.wait_until(lambda: any(
                        message.get("requestId") == "override" and message.get("type") == "backendStatus"
                        for message in client.messages
                    ))
                    self.assertEqual(daemon.runtime_override["target"], matching)

                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": "resume", "generation": 2,
                        "operation": "setDesired", "desired": matching,
                        "intent": "schedule", "resume": True,
                    })
                    await self.wait_until(lambda: any(
                        message.get("requestId") == "resume" and message.get("type") == "backendStatus"
                        for message in client.messages
                    ))
                    self.assertIsNone(daemon.runtime_override)
                finally:
                    daemon.apply_task.cancel()
                    await asyncio.gather(daemon.apply_task, return_exceptions=True)

            writes = [
                call for call in fake.calls()
                if call == ["hyprsunset", "identity", "true"]
                or (len(call) == 3 and call[:2] == ["hyprsunset", "temperature"])
            ]
            self.assertEqual(writes, [])

    async def test_latest_wins_and_stale_generation_cannot_mutate(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            daemon.backend = SlowBackend()
            daemon.backend_ready = True
            client = RecordingClient()
            daemon.clients.add(client)
            daemon.apply_task = asyncio.create_task(daemon.apply_loop())
            try:
                for generation, kelvin in ((1, 4100), (2, 4200), (3, 4300)):
                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": generation, "generation": generation,
                        "operation": "setDesired", "desired": {"kind": "temperature", "temperature": kelvin},
                        "intent": "schedule",
                    })
                await asyncio.sleep(0.12)
                self.assertEqual(daemon.backend.applied[-1]["temperature"], 4300)
                self.assertLessEqual(len(daemon.backend.applied), 2)
                await daemon.dispatch(client, {
                    "protocol": 1, "requestId": "stale", "generation": 2,
                    "operation": "setDesired", "desired": {"kind": "identity"}, "intent": "schedule",
                })
                await asyncio.sleep(0)
                self.assertEqual(client.messages[-1]["code"], "stale-generation")
                self.assertEqual(daemon.backend.applied[-1]["temperature"], 4300)
            finally:
                daemon.apply_task.cancel()

    async def test_hot_reload_fresh_generation_applies_and_old_client_cannot_supersede(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            daemon.backend = SlowBackend()
            daemon.backend_ready = True
            old_client = RecordingClient()
            fresh_client = RecordingClient()
            daemon.apply_task = asyncio.create_task(daemon.apply_loop())
            try:
                await daemon.dispatch(old_client, {
                    "protocol": 1, "requestId": "old-initial", "generation": 50,
                    "operation": "setDesired",
                    "desired": {"kind": "temperature", "temperature": 4100},
                    "intent": "schedule",
                })
                await daemon.dispatch(fresh_client, {
                    "protocol": 1, "requestId": "fresh-zero", "generation": 0,
                    "operation": "setDesired",
                    "desired": {"kind": "temperature", "temperature": 4300},
                    "intent": "schedule",
                })
                await daemon.dispatch(old_client, {
                    "protocol": 1, "requestId": "old-late", "generation": 51,
                    "operation": "setDesired", "desired": {"kind": "identity"},
                    "intent": "schedule",
                })

                await self.wait_until(
                    lambda: daemon.backend.last_ack == {"kind": "temperature", "temperature": 4300}
                )
                self.assertEqual(old_client.messages[-1]["requestId"], "old-late")
                self.assertEqual(old_client.messages[-1]["code"], "stale-generation")
                self.assertNotIn({"kind": "identity"}, daemon.backend.applied)
            finally:
                daemon.apply_task.cancel()
                await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_hot_reload_after_apply_gives_replacement_probe_fresh_authority(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            daemon.backend = SlowBackend()
            daemon.backend_ready = True
            old_client = RecordingClient()
            fresh_client = RecordingClient()
            daemon.apply_task = asyncio.create_task(daemon.apply_loop())
            try:
                await daemon.dispatch(old_client, {
                    "protocol": 1, "requestId": "old-apply", "generation": 50,
                    "operation": "setDesired",
                    "desired": {"kind": "temperature", "temperature": 4100},
                    "intent": "schedule",
                })
                await self.wait_until(lambda: any(
                    message.get("requestId") == "old-apply"
                    and message.get("type") == "backendStatus"
                    for message in old_client.messages
                ))
                old_token = daemon.apply_token
                self.assertIsNotNone(old_token)
                self.assertFalse(old_token.is_set())

                # This is the replacement service's exact ready -> startup-probe
                # handshake.  A completed predecessor apply must not lend its
                # now-cancelled token to the fresh observational request.
                await daemon.dispatch(fresh_client, {
                    "protocol": 1, "requestId": "fresh-probe", "generation": 0,
                    "operation": "probe",
                })

                self.assertTrue(old_token.is_set())
                self.assertIsNone(daemon.apply_token)
                responses = [
                    message for message in fresh_client.messages
                    if message.get("requestId") == "fresh-probe"
                ]
                self.assertEqual(len(responses), 1)
                self.assertEqual(responses[0]["type"], "backendStatus")
                self.assertEqual(responses[0]["actual"]["temperature"], 4100)

                await daemon.dispatch(old_client, {
                    "protocol": 1, "requestId": "old-late", "generation": 51,
                    "operation": "probe",
                })
                self.assertEqual(old_client.messages[-1]["requestId"], "old-late")
                self.assertEqual(old_client.messages[-1]["code"], "stale-generation")
            finally:
                daemon.apply_task.cancel()
                await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_blocked_old_probe_cannot_clear_replacement_pending_or_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            daemon.backend = BlockedProbeBackend()
            daemon.backend_ready = True
            old_client = RecordingClient()
            fresh_client = RecordingClient()

            old_probe = asyncio.create_task(daemon.dispatch(old_client, {
                "protocol": 1, "requestId": "old-probe", "generation": 50,
                "operation": "probe",
            }))
            await asyncio.wait_for(daemon.backend.probe_entered.wait(), 1)

            # Activation and admission happen while the predecessor's probe is
            # blocked.  The replacement owns both the pending work and token.
            await daemon.dispatch(fresh_client, {
                "protocol": 1, "requestId": "fresh-zero", "generation": 0,
                "operation": "setDesired",
                "desired": {"kind": "temperature", "temperature": 4300},
                "intent": "schedule",
            })
            fresh_token = daemon.apply_token
            self.assertIsNotNone(fresh_token)
            self.assertIsNotNone(daemon.pending)
            self.assertIs(daemon.pending[3], fresh_token)

            daemon.backend.probe_gate.set()
            await asyncio.wait_for(old_probe, 1)

            # The obsolete observation is a complete no-op: it publishes
            # neither backend cache/override nor cancellation state.
            self.assertEqual(daemon.backend.actual.kind, "identity")
            self.assertIsNone(daemon.runtime_override)
            self.assertIsNotNone(daemon.pending)
            self.assertIs(daemon.pending[3], fresh_token)
            self.assertFalse(fresh_token.is_set())
            self.assertEqual(len(old_client.messages), 1)
            self.assertEqual(old_client.messages[0]["requestId"], "old-probe")
            self.assertEqual(old_client.messages[0]["code"], "stale-generation")

            daemon.apply_task = asyncio.create_task(daemon.apply_loop())
            try:
                await self.wait_until(
                    lambda: daemon.backend.last_ack
                    == {"kind": "temperature", "temperature": 4300}
                )
                self.assertFalse(fresh_token.is_set())
                self.assertTrue(any(
                    message.get("requestId") == "fresh-zero"
                    and message.get("type") == "backendStatus"
                    for message in fresh_client.messages
                ))
            finally:
                daemon.apply_task.cancel()
                await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_hot_reload_after_write_before_ack_reconciles_fresh_probe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            verification_entered = root / "verification-entered"
            verification_gate = root / "verification-gate"
            environment = {
                **fake.environment(),
                "FAKE_HYPR_BLOCK_VERIFICATION": str(verification_entered),
                "FAKE_HYPR_VERIFICATION_GATE": str(verification_gate),
            }
            with mock.patch.dict(os.environ, environment, clear=False):
                daemon = controller.ControllerDaemon(root)
                daemon.backend.baseline = await daemon.backend.probe()
                daemon.backend_ready = True
                old_client = RecordingClient()
                fresh_client = RecordingClient()
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                try:
                    desired = {"kind": "temperature", "temperature": 4100}
                    await daemon.dispatch(old_client, {
                        "protocol": 1, "requestId": "old-write", "generation": 50,
                        "operation": "setDesired", "desired": desired,
                        "intent": "schedule",
                    })
                    await self.wait_until(verification_entered.exists)

                    # The mutation child has exited after changing Hyprland, but
                    # its verification is still blocked and cannot acknowledge it.
                    self.assertEqual(fake.writes(), [
                        ["hyprsunset", "temperature", "4100"]
                    ])
                    self.assertEqual(
                        json.loads(fake.state.read_text())["temperature"], 4100
                    )
                    self.assertEqual(daemon.backend.last_attempt, desired)
                    self.assertIsNone(daemon.backend.last_ack)
                    old_token = daemon.apply_token

                    # Activation cancels the predecessor while the fresh startup
                    # probe queues behind verification on the backend lock.
                    fresh_probe = asyncio.create_task(daemon.dispatch(fresh_client, {
                        "protocol": 1, "requestId": "fresh-probe", "generation": 0,
                        "operation": "probe",
                    }))
                    await self.wait_until(lambda: old_token is not None and old_token.is_set())
                    verification_gate.write_text("continue")
                    await asyncio.wait_for(fresh_probe, 2)

                    responses = [
                        message for message in fresh_client.messages
                        if message.get("requestId") == "fresh-probe"
                    ]
                    self.assertEqual(len(responses), 1)
                    self.assertEqual(responses[0]["type"], "backendStatus")
                    self.assertEqual(responses[0]["actual"]["temperature"], 4100)
                    self.assertIsNone(responses[0]["override"])
                    self.assertIsNone(daemon.runtime_override)
                    self.assertIsNone(daemon.backend.last_attempt)
                    self.assertEqual(daemon.backend.last_ack, desired)
                    self.assertFalse(any(
                        message.get("requestId") == "old-write"
                        for message in old_client.messages
                    ))

                    # Reconciliation preserves value-CAS ownership but does not
                    # authorize restoration over a later external winner.
                    fake.state.write_text(json.dumps({
                        "identity": False, "temperature": 3333, "gamma": 100,
                    }))
                    writes_before_release = list(fake.writes())
                    await daemon.backend.release()
                    self.assertEqual(
                        json.loads(fake.state.read_text())["temperature"], 3333
                    )
                    self.assertEqual(fake.writes(), writes_before_release)
                finally:
                    daemon.apply_task.cancel()
                    await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_hot_reload_terminates_paused_old_child_without_write_or_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            entered = root / "mutation-entered"
            gate = root / "mutation-gate"
            environment = {
                **fake.environment(),
                "FAKE_HYPR_BLOCK_MUTATION": str(entered),
                "FAKE_HYPR_MUTATION_GATE": str(gate),
            }
            with mock.patch.dict(os.environ, environment, clear=False):
                daemon = controller.ControllerDaemon(root)
                daemon.backend = controller.Backend()
                await daemon.backend.probe()
                daemon.backend_ready = True
                old_client = RecordingClient()
                fresh_client = RecordingClient()
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                try:
                    await daemon.dispatch(old_client, {
                        "protocol": 1, "requestId": "old-paused", "generation": 50,
                        "operation": "setDesired",
                        "desired": {"kind": "temperature", "temperature": 4100},
                        "intent": "schedule",
                    })
                    await self.wait_until(entered.exists)

                    # The fresh attachment is authoritative immediately.  Its
                    # generation namespace restarts at zero while activation
                    # wakes termination of the predecessor's paused child.
                    await daemon.dispatch(fresh_client, {
                        "protocol": 1, "requestId": "fresh-zero", "generation": 0,
                        "operation": "setDesired",
                        "desired": {"kind": "temperature", "temperature": 4300},
                        "intent": "schedule",
                    })
                    await self.wait_until(lambda: any(
                        message.get("requestId") == "fresh-zero"
                        and message.get("type") == "backendStatus"
                        for message in fresh_client.messages
                    ), timeout=1.5)

                    # Opening the old gate cannot revive the reaped process.
                    gate.write_text("too late")
                    await asyncio.sleep(0.05)
                    self.assertEqual(fake.writes(), [
                        ["hyprsunset", "temperature", "4300"]
                    ])
                    self.assertEqual(
                        json.loads(fake.state.read_text())["temperature"], 4300
                    )
                    self.assertFalse(daemon.backend._mutating_processes)
                    self.assertFalse(any(
                        message.get("requestId") == "old-paused"
                        for message in old_client.messages
                    ), "obsolete completion published backendStatus")
                finally:
                    daemon.apply_task.cancel()
                    await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_hot_reload_resets_state_and_provider_generation_namespaces(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            daemon = controller.ControllerDaemon(root)
            daemon.store = controller.LocationStore(root / "private" / "location.json")
            daemon.provider.geocode = lambda query, language: []
            daemon.provider.auto_locate = lambda: {"source": "fresh-provider"}
            old_client = RecordingClient()
            fresh_client = RecordingClient()
            candidate = state()
            candidate["autoConsentVersion"] = 1

            await daemon.dispatch(old_client, {
                "protocol": 1, "requestId": "old-state", "generation": 40,
                "operation": "writeLocationState", "state": candidate,
                "expectedRevision": 0,
            })
            await daemon.dispatch(old_client, {
                "protocol": 1, "requestId": "old-geocode", "generation": 40,
                "operation": "geocode", "query": "old", "language": "en",
                "searchEpoch": 1,
            })
            await daemon.dispatch(old_client, {
                "protocol": 1, "requestId": "old-auto", "generation": 40,
                "operation": "autoLocate", "locationEpoch": 1,
            })
            await self.wait_until(lambda: len([
                message for message in old_client.messages
                if message.get("type") == "networkResult"
            ]) == 2)

            # Merely connecting/dispatching as the replacement creates a new
            # namespace.  Its counters start at zero despite the daemon living on.
            await daemon.dispatch(fresh_client, {
                "protocol": 1, "requestId": "fresh-state", "generation": 0,
                "operation": "writeLocationState", "state": candidate,
                "expectedRevision": 1,
            })
            await daemon.dispatch(fresh_client, {
                "protocol": 1, "requestId": "fresh-geocode", "generation": 0,
                "operation": "geocode", "query": "fresh", "language": "en",
                "searchEpoch": 0,
            })
            await daemon.dispatch(fresh_client, {
                "protocol": 1, "requestId": "fresh-auto", "generation": 0,
                "operation": "autoLocate", "locationEpoch": 0,
            })
            await self.wait_until(lambda: len([
                message for message in fresh_client.messages
                if message.get("type") == "networkResult"
            ]) == 2)

            fresh_ids = {message.get("requestId") for message in fresh_client.messages}
            self.assertTrue({"fresh-state", "fresh-geocode", "fresh-auto"} <= fresh_ids)
            for operation, extra in (
                ("writeLocationState", {"state": candidate, "expectedRevision": 2}),
                ("geocode", {"query": "late", "language": "en", "searchEpoch": 2}),
                ("autoLocate", {"locationEpoch": 2}),
            ):
                await daemon.dispatch(old_client, {
                    "protocol": 1, "requestId": "old-late-" + operation,
                    "generation": 41, "operation": operation, **extra,
                })
            late = [
                message for message in old_client.messages
                if str(message.get("requestId", "")).startswith("old-late-")
            ]
            self.assertEqual(len(late), 3)
            self.assertTrue(all(message.get("code") == "stale-generation" for message in late))

    async def test_obsolete_network_generation_is_not_published(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            client = RecordingClient()
            daemon.clients.add(client)

            def delayed(query, language):
                time.sleep(0.05 if query == "old" else 0.005)
                return []

            daemon.provider.geocode = delayed
            # Search epoch and normalized query are barriers even when a caller
            # deliberately reuses its broader service generation.
            old = {"protocol": 1, "requestId": "old", "generation": 1, "operation": "geocode", "query": "old", "language": "en", "searchEpoch": 1}
            new = {"protocol": 1, "requestId": "new", "generation": 1, "operation": "geocode", "query": "new", "language": "en", "searchEpoch": 2}
            await daemon.dispatch(client, old)
            await daemon.dispatch(client, new)
            await asyncio.sleep(0.1)
            published = [message.get("requestId") for message in client.messages if message.get("type") == "networkResult"]
            self.assertEqual(published, ["new"])


class AttachDaemonTests(unittest.TestCase):
    def test_installed_format_signature_real_attach_round_trip(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            runtime.chmod(0o700)
            fake = FakeHyprctl(root)
            signature = "5c9377c15f85c50648f35ca5a213754f95b93ca0_1788126676_1545257629"
            component = controller._safe_signature(signature)
            session = runtime / "jgordijn-night-light" / component
            self.assertEqual(len(component), 43)
            self.assertNotEqual(component, signature)
            self.assertGreater(
                len(os.fsencode(runtime / "jgordijn-night-light" / signature / "control.sock")),
                controller.UNIX_SOCKET_PATH_BYTES,
            )
            self.assertLessEqual(
                len(os.fsencode(session / "control.sock")), controller.UNIX_SOCKET_PATH_BYTES
            )
            env = os.environ.copy()
            env.update(fake.environment())
            env.update({
                "XDG_RUNTIME_DIR": str(runtime),
                "HYPRLAND_INSTANCE_SIGNATURE": signature,
                "NIGHT_LIGHT_STATE_PATH": str(root / "state-home" / "location.json"),
                "NIGHT_LIGHT_RELEASE_GRACE": "0.15",
            })
            process = subprocess.Popen(
                [sys.executable, str(ROOT / "Controller.py"), "attach"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=env, text=True,
            )
            assert process.stdin and process.stdout
            ready = json.loads(process.stdout.readline())
            status = json.loads(process.stdout.readline())
            self.assertEqual(ready["type"], "ready")
            self.assertEqual(status["type"], "backendStatus")
            request = {"protocol": 1, "requestId": "p", "generation": 1, "operation": "probe"}
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            response = json.loads(process.stdout.readline())
            self.assertEqual(response["requestId"], "p")
            self.assertEqual(response["actual"]["temperature"], 4777)
            process.stdin.close()
            process.wait(timeout=3)
            process.stdout.close()
            assert process.stderr
            process.stderr.close()
            self.assertEqual(stat.S_IMODE(session.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((session / "controller.lock").stat().st_mode), 0o600)
            deadline = time.monotonic() + 2
            while (session / "control.sock").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse((session / "control.sock").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
