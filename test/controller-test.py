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
            launch_argv = []
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
                    launch_argv.append(_args[0])
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
                    self.assertEqual(launch_argv, [[
                        "/fake/uwsm-app", "--", sleep_executable, "--identity",
                    ]])
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
        if guard is not None and not guard():
            return False
        self.messages.append(value)
        return True


class MemoryStreamWriter:
    """Small StreamWriter duck used to exercise the real Client output lock."""

    def __init__(self):
        self.data = []
        self.closing = False

    def is_closing(self):
        return self.closing

    def write(self, data):
        self.data.append(bytes(data))

    async def drain(self):
        await asyncio.sleep(0)

    def messages(self):
        return [json.loads(chunk) for chunk in self.data]


class GatedDrainStreamWriter(MemoryStreamWriter):
    """Buffers the first write, then holds its drain completion on a gate."""

    def __init__(self):
        super().__init__()
        self.drain_entered = asyncio.Event()
        self.drain_gate = asyncio.Event()
        self._held_once = False

    async def drain(self):
        if not self._held_once:
            self._held_once = True
            self.drain_entered.set()
            await self.drain_gate.wait()
        else:
            await asyncio.sleep(0)


class TwoStageGatedDrainStreamWriter(MemoryStreamWriter):
    """Independently gates health and generation-1 drain completion."""

    def __init__(self):
        super().__init__()
        self.drain_entered = [asyncio.Event(), asyncio.Event()]
        self.drain_gates = [asyncio.Event(), asyncio.Event()]
        self.drain_count = 0

    async def drain(self):
        index = self.drain_count
        self.drain_count += 1
        if index < len(self.drain_gates):
            self.drain_entered[index].set()
            await self.drain_gates[index].wait()
        else:
            await asyncio.sleep(0)


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


class VanishingBackend(SlowBackend):
    """Backend whose daemon disappears once, then initialize recreates it."""

    def __init__(self):
        super().__init__()
        self.missing = True
        self.initialize_calls = 0

    async def initialize(self):
        self.initialize_calls += 1
        self.missing = False
        self.actual = controller.Actual("identity", 6500, 100)
        return self.actual

    async def probe(self, *, publish=True):
        if self.missing:
            raise RuntimeError("backend disappeared")
        return await super().probe(publish=publish)


class QueueAndGenerationTests(unittest.IsolatedAsyncioTestCase):
    @staticmethod
    async def wait_until(predicate, timeout=1.0):
        async def poll():
            while not predicate():
                await asyncio.sleep(0.005)
        await asyncio.wait_for(poll(), timeout)

    async def test_health_restarts_backend_that_disappears_after_startup(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            daemon.backend = VanishingBackend()
            daemon.backend_ready = True
            writer = MemoryStreamWriter()
            client = controller.Client(asyncio.StreamReader(), writer)
            daemon.activate_client(client)

            await daemon._health_iteration()

            self.assertEqual(daemon.backend.initialize_calls, 1)
            self.assertTrue(daemon.backend_ready)
            self.assertIsNone(daemon.backend_error)
            self.assertEqual(writer.messages(), [{
                "protocol": 1,
                "type": "backendStatus",
                "available": True,
                "actual": {"kind": "identity", "temperature": 6500, "gamma": 100},
                "override": None,
                "error": None,
            }])

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
                            "ifActual": {"kind": "temperature", "temperature": 4777},
                            "intent": "schedule",
                        })
                        old_token = daemon.apply_token
                        await self.wait_until(lambda: daemon.pending is None)
                        self.assertIsNotNone(old_token)
                        await daemon.dispatch(client, {
                            "protocol": 1, "requestId": "new-temperature", "generation": 2,
                            "operation": "setDesired",
                            "desired": {"kind": "temperature", "temperature": 4300},
                            "ifActual": {"kind": "temperature", "temperature": 4777},
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
                            "ifActual": {"kind": "temperature", "temperature": 4300},
                            "intent": "schedule",
                        })
                        await self.wait_until(lambda: daemon.pending is None)
                        await daemon.dispatch(client, {
                            "protocol": 1, "requestId": "identity", "generation": 4,
                            "operation": "setDesired", "desired": {"kind": "identity"},
                            "ifActual": {"kind": "temperature", "temperature": 4300},
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

    async def test_stale_status_held_on_output_lock_preserves_successor_ack_chain(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            with mock.patch.dict(os.environ, fake.environment(), clear=False), \
                    mock.patch.object(controller, "TEMPERATURE_WRITE_INTERVAL", 0.0):
                daemon = controller.ControllerDaemon(root)
                daemon.backend = controller.Backend()
                await daemon.backend.probe()
                daemon.backend_ready = True
                writer = MemoryStreamWriter()
                client = controller.Client(asyncio.StreamReader(), writer)
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                await client.write_lock.acquire()
                try:
                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": "old", "generation": 1,
                        "operation": "setDesired",
                        "desired": {"kind": "temperature", "temperature": 4300},
                        "ifActual": {"kind": "temperature", "temperature": 4777},
                        "intent": "schedule", "overrideUntil": 999999,
                    })
                    old_token = daemon.apply_token
                    self.assertIsNotNone(old_token)
                    await self.wait_until(
                        lambda: daemon.backend.last_ack
                        == {"kind": "temperature", "temperature": 4300}
                    )
                    self.assertTrue(
                        daemon.backend.last_ack_chain_available,
                        "verified old ack was consumed before output publication",
                    )

                    # Service cannot have observed old: its status is waiting on
                    # write_lock. The rapid successor therefore truthfully keeps
                    # the previously published 4777 K as its CAS guard.
                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": "new", "generation": 2,
                        "operation": "setDesired",
                        "desired": {"kind": "temperature", "temperature": 4100},
                        "ifActual": {"kind": "temperature", "temperature": 4777},
                        "intent": "schedule", "overrideUntil": 999999,
                    })
                    self.assertTrue(old_token.is_set())
                finally:
                    client.write_lock.release()

                try:
                    await self.wait_until(
                        lambda: daemon.backend.last_ack
                        == {"kind": "temperature", "temperature": 4100}
                    )
                    await self.wait_until(lambda: len(writer.messages()) == 1)
                    self.assertEqual(fake.writes(), [
                        ["hyprsunset", "temperature", "4300"],
                        ["hyprsunset", "temperature", "4100"],
                    ])
                    self.assertIsNone(daemon.runtime_override)
                    wire = writer.messages()
                    self.assertEqual(len(wire), 1, "stale old status reached the wire")
                    self.assertEqual(wire[0]["requestId"], "new")
                    self.assertEqual(wire[0]["generation"], 2)
                    self.assertEqual(wire[0]["actual"], {
                        "kind": "temperature", "temperature": 4100, "gamma": 100,
                    })
                    self.assertFalse(
                        daemon.backend.last_ack_chain_available,
                        "successfully published successor status retained private ack allowance",
                    )
                finally:
                    daemon.apply_task.cancel()
                    await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_supersession_during_drain_preserves_successor_ack_chain(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            with mock.patch.dict(os.environ, fake.environment(), clear=False), \
                    mock.patch.object(controller, "TEMPERATURE_WRITE_INTERVAL", 0.0):
                daemon = controller.ControllerDaemon(root)
                daemon.backend = controller.Backend()
                await daemon.backend.probe()
                daemon.backend_ready = True
                writer = GatedDrainStreamWriter()
                client = controller.Client(asyncio.StreamReader(), writer)
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                try:
                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": "old-drain", "generation": 1,
                        "operation": "setDesired",
                        "desired": {"kind": "temperature", "temperature": 4300},
                        "ifActual": {"kind": "temperature", "temperature": 4777},
                        "intent": "schedule", "overrideUntil": 999999,
                    })
                    old_token = daemon.apply_token
                    self.assertIsNotNone(old_token)
                    await asyncio.wait_for(writer.drain_entered.wait(), 1)
                    self.assertEqual(
                        daemon.backend.last_ack,
                        {"kind": "temperature", "temperature": 4300},
                    )
                    self.assertTrue(daemon.backend.last_ack_chain_available)
                    self.assertEqual(
                        [message["requestId"] for message in writer.messages()],
                        ["old-drain"],
                        "old status was not buffered before drain blocked",
                    )

                    # The pre-drain guard passed, but this successor revokes the
                    # old token before drain completion. Service still holds its
                    # last accepted 4777 K because generation 1 is now stale.
                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": "new-drain", "generation": 2,
                        "operation": "setDesired",
                        "desired": {"kind": "temperature", "temperature": 4100},
                        "ifActual": {"kind": "temperature", "temperature": 4777},
                        "intent": "schedule", "overrideUntil": 999999,
                    })
                    self.assertTrue(old_token.is_set())
                    writer.drain_gate.set()

                    await self.wait_until(
                        lambda: daemon.backend.last_ack
                        == {"kind": "temperature", "temperature": 4100}
                    )
                    await self.wait_until(lambda: len(writer.messages()) == 2)
                    self.assertEqual(fake.writes(), [
                        ["hyprsunset", "temperature", "4300"],
                        ["hyprsunset", "temperature", "4100"],
                    ])
                    self.assertIsNone(daemon.runtime_override)
                    wire = writer.messages()
                    # writer.write necessarily buffered old bytes before the
                    # gated drain. Their stale correlation makes them
                    # non-authoritative; only generation 2 carries latest state.
                    self.assertEqual(
                        [(row["requestId"], row["generation"]) for row in wire],
                        [("old-drain", 1), ("new-drain", 2)],
                    )
                    self.assertEqual(wire[1]["actual"], {
                        "kind": "temperature", "temperature": 4100, "gamma": 100,
                    })
                    # writer.write() makes the second row observable before
                    # broadcast_status() resumes from drain and consumes the
                    # matching private ack allowance. Wait for that lifecycle
                    # boundary rather than racing it.
                    await self.wait_until(
                        lambda: not daemon.backend.last_ack_chain_available
                    )
                    self.assertFalse(daemon.backend.last_ack_chain_available)
                finally:
                    writer.drain_gate.set()
                    daemon.apply_task.cancel()
                    await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_two_stage_health_drain_cannot_consume_newer_ack_chain(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            with mock.patch.dict(os.environ, fake.environment(), clear=False), \
                    mock.patch.object(controller, "TEMPERATURE_WRITE_INTERVAL", 0.0):
                daemon = controller.ControllerDaemon(root)
                daemon.backend = controller.Backend()
                await daemon.backend.probe()
                daemon.backend_ready = True
                writer = TwoStageGatedDrainStreamWriter()
                client = controller.Client(asyncio.StreamReader(), writer)
                session = daemon.activate_client(client)
                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                captured_token = daemon.apply_token
                self.assertIsNone(captured_token)
                health = asyncio.create_task(daemon._health_iteration())
                try:
                    # Health has buffered the initial 4777 K observation, but
                    # its first drain is still incomplete under captured None
                    # apply authority.
                    await asyncio.wait_for(writer.drain_entered[0].wait(), 1)
                    self.assertEqual(writer.messages()[0]["actual"], {
                        "kind": "temperature", "temperature": 4777, "gamma": 100,
                    })

                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": "health-g1", "generation": 1,
                        "operation": "setDesired",
                        "desired": {"kind": "temperature", "temperature": 4300},
                        "ifActual": {"kind": "temperature", "temperature": 4777},
                        "intent": "schedule", "overrideUntil": 999999,
                    })
                    g1_token = daemon.apply_token
                    self.assertIsNotNone(g1_token)
                    await self.wait_until(
                        lambda: daemon.backend.last_ack
                        == {"kind": "temperature", "temperature": 4300}
                    )
                    self.assertTrue(daemon.backend.last_ack_chain_available)

                    # Completing old health drain must fail its captured-None
                    # guard rather than erase generation 1's newer ack chain.
                    writer.drain_gates[0].set()
                    await asyncio.wait_for(health, 1)
                    await asyncio.wait_for(writer.drain_entered[1].wait(), 1)
                    self.assertTrue(
                        daemon.backend.last_ack_chain_available,
                        "older health publication consumed generation 1 ack",
                    )

                    # Generation 1 is now buffered in the second gated drain.
                    # Generation 2 still truthfully guards from Service's last
                    # canonical 4777 K because g1 correlation is obsolete.
                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": "health-g2", "generation": 2,
                        "operation": "setDesired",
                        "desired": {"kind": "temperature", "temperature": 4100},
                        "ifActual": {"kind": "temperature", "temperature": 4777},
                        "intent": "schedule", "overrideUntil": 999999,
                    })
                    self.assertTrue(g1_token.is_set())
                    writer.drain_gates[1].set()

                    await self.wait_until(
                        lambda: daemon.backend.last_ack
                        == {"kind": "temperature", "temperature": 4100}
                    )
                    await self.wait_until(lambda: len(writer.messages()) == 3)
                    self.assertEqual(fake.writes(), [
                        ["hyprsunset", "temperature", "4300"],
                        ["hyprsunset", "temperature", "4100"],
                    ])
                    self.assertIsNone(daemon.runtime_override)
                    wire = writer.messages()
                    self.assertEqual(
                        [(row.get("requestId"), row.get("generation")) for row in wire],
                        [(None, None), ("health-g1", 1), ("health-g2", 2)],
                    )
                    self.assertEqual(wire[2]["actual"], {
                        "kind": "temperature", "temperature": 4100, "gamma": 100,
                    })
                    self.assertFalse(daemon.backend.last_ack_chain_available)

                    # A health publication captured under unchanged g2 authority
                    # remains legitimate and reaches the same client.
                    await daemon._health_iteration()
                    self.assertEqual(len(writer.messages()), 4)
                    self.assertEqual(writer.messages()[3]["actual"], {
                        "kind": "temperature", "temperature": 4100, "gamma": 100,
                    })
                finally:
                    for gate in writer.drain_gates:
                        gate.set()
                    if not health.done():
                        health.cancel()
                        await asyncio.gather(health, return_exceptions=True)
                    daemon.apply_task.cancel()
                    await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_health_after_g1_admission_cannot_consume_post_probe_ack_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            with mock.patch.dict(os.environ, fake.environment(), clear=False), \
                    mock.patch.object(controller, "TEMPERATURE_WRITE_INTERVAL", 0.0):
                daemon = controller.ControllerDaemon(root)
                daemon.backend = controller.Backend()
                await daemon.backend.probe()
                daemon.backend_ready = True
                writer = TwoStageGatedDrainStreamWriter()
                client = controller.Client(asyncio.StreamReader(), writer)
                daemon.activate_client(client)

                # Admit g1 but do not start apply_loop yet. Health therefore
                # observes 4777 K under the same token g1 will later mutate.
                await daemon.dispatch(client, {
                    "protocol": 1, "requestId": "same-token-g1", "generation": 1,
                    "operation": "setDesired",
                    "desired": {"kind": "temperature", "temperature": 4300},
                    "ifActual": {"kind": "temperature", "temperature": 4777},
                    "intent": "schedule", "overrideUntil": 999999,
                })
                g1_token = daemon.apply_token
                self.assertIsNotNone(g1_token)
                health = asyncio.create_task(daemon._health_iteration())
                daemon.apply_task = None
                try:
                    await asyncio.wait_for(writer.drain_entered[0].wait(), 1)
                    self.assertEqual(writer.messages()[0]["actual"], {
                        "kind": "temperature", "temperature": 4777, "gamma": 100,
                    })
                    observed_version = daemon.backend.last_ack_chain_version
                    self.assertEqual(observed_version, 0)

                    # g1 mutates only after health's status/version snapshot.
                    daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                    await self.wait_until(
                        lambda: daemon.backend.last_ack
                        == {"kind": "temperature", "temperature": 4300}
                    )
                    self.assertGreater(
                        daemon.backend.last_ack_chain_version, observed_version
                    )
                    g1_ack_version = daemon.backend.last_ack_chain_version
                    self.assertTrue(daemon.backend.last_ack_chain_available)

                    # Health still has the same token and legitimately reaches
                    # the wire, but its old version must not consume g1's ack.
                    writer.drain_gates[0].set()
                    await asyncio.wait_for(health, 1)
                    await asyncio.wait_for(writer.drain_entered[1].wait(), 1)
                    self.assertEqual(
                        daemon.backend.last_ack_chain_version, g1_ack_version
                    )
                    self.assertTrue(
                        daemon.backend.last_ack_chain_available,
                        "same-token pre-mutation health consumed post-probe g1 ack",
                    )

                    # g1 response is now in the second drain. Supersede it with
                    # g2 while Service still truthfully guards from 4777 K.
                    await daemon.dispatch(client, {
                        "protocol": 1, "requestId": "same-token-g2", "generation": 2,
                        "operation": "setDesired",
                        "desired": {"kind": "temperature", "temperature": 4100},
                        "ifActual": {"kind": "temperature", "temperature": 4777},
                        "intent": "schedule", "overrideUntil": 999999,
                    })
                    self.assertTrue(g1_token.is_set())
                    writer.drain_gates[1].set()

                    await self.wait_until(
                        lambda: daemon.backend.last_ack
                        == {"kind": "temperature", "temperature": 4100}
                    )
                    await self.wait_until(lambda: len(writer.messages()) == 3)
                    self.assertEqual(fake.writes(), [
                        ["hyprsunset", "temperature", "4300"],
                        ["hyprsunset", "temperature", "4100"],
                    ])
                    self.assertIsNone(daemon.runtime_override)
                    wire = writer.messages()
                    self.assertEqual(
                        [(row.get("requestId"), row.get("generation")) for row in wire],
                        [(None, None), ("same-token-g1", 1), ("same-token-g2", 2)],
                    )
                    self.assertEqual(wire[2]["actual"], {
                        "kind": "temperature", "temperature": 4100, "gamma": 100,
                    })
                    self.assertGreater(
                        daemon.backend.last_ack_chain_version, g1_ack_version
                    )
                    self.assertFalse(daemon.backend.last_ack_chain_available)
                finally:
                    for gate in writer.drain_gates:
                        gate.set()
                    if not health.done():
                        health.cancel()
                        await asyncio.gather(health, return_exceptions=True)
                    if daemon.apply_task is not None:
                        daemon.apply_task.cancel()
                        await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_schedule_cas_adopts_external_state_without_a_plugin_write(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = FakeHyprctl(root)
            with mock.patch.dict(os.environ, fake.environment(), clear=False):
                daemon = controller.ControllerDaemon(root)
                daemon.backend = controller.Backend()
                await daemon.backend.probe()
                daemon.backend_ready = True
                client = RecordingClient()

                await daemon.dispatch(client, {
                    "protocol": 1, "requestId": "cas", "generation": 1,
                    "operation": "setDesired",
                    "desired": {"kind": "temperature", "temperature": 4100},
                    "ifActual": {"kind": "temperature", "temperature": 4777},
                    "intent": "schedule", "overrideUntil": 987654,
                })
                token = daemon.apply_token
                self.assertIsNotNone(token)

                # The external winner deliberately equals stale plugin history;
                # an arbitrary old ack is not ownership proof for this CAS.
                daemon.backend.last_ack = {"kind": "temperature", "temperature": 3333}
                daemon.backend.last_ack_owner = (token.attachment_epoch, 0)
                daemon.backend.last_ack_chain_available = False
                fake.state.write_text(json.dumps({
                    "identity": False, "temperature": 3333, "gamma": 100,
                }))

                daemon.apply_task = asyncio.create_task(daemon.apply_loop())
                try:
                    await self.wait_until(lambda: any(
                        message.get("requestId") == "cas"
                        and message.get("type") == "backendStatus"
                        for message in client.messages
                    ))
                    response = next(
                        message for message in client.messages
                        if message.get("requestId") == "cas"
                    )
                    self.assertEqual(response["actual"], {
                        "kind": "temperature", "temperature": 3333, "gamma": 100,
                    })
                    self.assertEqual(response["override"], {
                        "target": {"kind": "temperature", "temperature": 3333},
                        "until": 987654, "source": "external",
                    })
                    self.assertEqual(fake.writes(), [])
                    self.assertIsNone(daemon.pending)
                    self.assertIsNone(daemon.deferred)
                    self.assertTrue(token.is_set())
                finally:
                    daemon.apply_task.cancel()
                    await asyncio.gather(daemon.apply_task, return_exceptions=True)

    async def test_invalid_schedule_cas_value_is_rejected_before_queueing(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            client = RecordingClient()
            await daemon.dispatch(client, {
                "protocol": 1, "requestId": "bad-cas", "generation": 1,
                "operation": "setDesired", "desired": {"kind": "identity"},
                "ifActual": {"kind": "temperature", "temperature": 999},
                "intent": "schedule",
            })
            self.assertEqual(client.messages[-1]["code"], "invalid-request")
            self.assertIsNone(daemon.pending)

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


class CivilProjectionTests(unittest.IsolatedAsyncioTestCase):
    @staticmethod
    def epoch_ms(value):
        parsed = controller.dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return int(parsed.timestamp() * 1000)

    @staticmethod
    def request(**changes):
        request = {
            "protocol": 1,
            "requestId": "timeline-1",
            "generation": 1,
            "operation": "projectCivilDay",
            "nowMs": 1788273420000,
            "zoneId": "Europe/Amsterdam",
            "events": [{"kind": "sunrise", "epochMs": 1788238305216}],
            "displayTimes": {"sunset": 1788287423925},
        }
        request.update(changes)
        return request

    async def test_reference_projection_echoes_transaction_and_filters_by_civil_date(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            client = RecordingClient()
            request = self.request(events=[
                {"kind": "sunset", "epochMs": self.epoch_ms("2026-08-31T18:30:00Z")},
                {"kind": "sunrise", "epochMs": 1788238305216},
                {"kind": "sunset", "epochMs": 1788287423925},
                {"kind": "sunrise", "epochMs": self.epoch_ms("2026-09-02T04:53:00Z")},
            ], displayTimes={
                "sunset": 1788287423925,
                "sunrise": 1788238305216,
                "nextBoundary": None,
                "overrideUntil": self.epoch_ms("2026-09-02T04:53:00Z"),
            })
            await daemon.dispatch(client, request)

        self.assertEqual(len(client.messages), 1)
        response = client.messages[0]
        self.assertEqual(response["type"], "civilDay")
        self.assertEqual(response["requestId"], "timeline-1")
        self.assertEqual(response["generation"], 1)
        projection = response["projection"]
        self.assertEqual(projection["dateKey"], "2026-09-01")
        self.assertEqual(projection["zoneId"], "Europe/Amsterdam")
        self.assertEqual(projection["zoneSource"], "location")
        self.assertEqual(projection["dayStartMs"], 1788213600000)
        self.assertEqual(projection["dayEndMs"], 1788300000000)
        self.assertEqual(projection["markerWallMs"], 59820000)
        self.assertEqual(projection["markerOffsetMinutes"], 120)
        self.assertEqual(projection["markerFold"], 0)
        self.assertFalse(projection["markerAmbiguous"])
        self.assertEqual([event["kind"] for event in projection["events"]], ["sunrise", "sunset"])
        self.assertEqual(projection["events"][0], {
            "kind": "sunrise", "epochMs": 1788238305216,
            "dateKey": "2026-09-01", "wallMs": 24705216,
            "offsetMinutes": 120, "fold": 0, "ambiguous": False,
        })
        self.assertIsNone(projection["displayTimes"]["nextBoundary"])
        self.assertEqual(
            projection["displayTimes"]["overrideUntil"]["dateKey"], "2026-09-02"
        )

    async def test_spring_gap_has_real_23_hour_bounds_and_snapped_wall_time(self):
        now_ms = self.epoch_ms("2026-03-29T01:30:00Z")
        projection = controller.project_civil_day(self.request(
            nowMs=now_ms,
            events=[{"kind": "sunrise", "epochMs": now_ms}],
            displayTimes={},
        ))
        self.assertEqual(projection["dateKey"], "2026-03-29")
        self.assertEqual(projection["dayEndMs"] - projection["dayStartMs"], 23 * 60 * 60 * 1000)
        self.assertEqual(projection["markerWallMs"], 3 * 60 * 60 * 1000 + 30 * 60 * 1000)
        self.assertEqual(projection["markerOffsetMinutes"], 120)
        self.assertEqual(projection["markerFold"], 0)
        self.assertFalse(projection["markerAmbiguous"])

    async def test_fall_fold_has_real_25_hour_bounds_and_distinct_same_wall_events(self):
        first = self.epoch_ms("2026-10-25T00:30:00Z")
        second = self.epoch_ms("2026-10-25T01:30:00Z")
        projection = controller.project_civil_day(self.request(
            nowMs=second,
            events=[
                {"kind": "sunrise", "epochMs": first},
                {"kind": "sunset", "epochMs": second},
            ],
            displayTimes={"sunrise": first, "sunset": second},
        ))
        self.assertEqual(projection["dayEndMs"] - projection["dayStartMs"], 25 * 60 * 60 * 1000)
        self.assertEqual(projection["markerWallMs"], 2 * 60 * 60 * 1000 + 30 * 60 * 1000)
        self.assertEqual((projection["markerOffsetMinutes"], projection["markerFold"]), (60, 1))
        self.assertTrue(projection["markerAmbiguous"])
        events = projection["events"]
        self.assertEqual([event["wallMs"] for event in events], [9_000_000, 9_000_000])
        self.assertEqual([event["offsetMinutes"] for event in events], [120, 60])
        self.assertEqual([event["fold"] for event in events], [0, 1])
        self.assertTrue(all(event["ambiguous"] for event in events))

    async def test_invalid_location_zone_uses_live_system_iana_zone(self):
        now_ms = self.epoch_ms("2026-01-15T12:00:00Z")
        with mock.patch.dict(os.environ, {"TZ": "America/New_York"}, clear=False):
            projection = controller.project_civil_day(self.request(
                nowMs=now_ms, zoneId="Not/A_Zone", events=[], displayTimes={}
            ))
        self.assertEqual(projection["zoneId"], "America/New_York")
        self.assertEqual(projection["zoneSource"], "system")
        self.assertEqual(projection["dateKey"], "2026-01-15")
        self.assertEqual(projection["markerWallMs"], 7 * 60 * 60 * 1000)
        self.assertEqual(projection["markerOffsetMinutes"], -300)

    async def test_polar_empty_and_single_event_shapes_are_not_fabricated(self):
        empty = controller.project_civil_day(self.request(events=[], displayTimes={}))
        self.assertEqual(empty["events"], [])
        self.assertEqual(empty["displayTimes"], {})

        event_ms = self.epoch_ms("2026-09-01T21:59:59.999Z")
        single = controller.project_civil_day(self.request(
            events=[{"kind": "sunset", "epochMs": event_ms}], displayTimes={}
        ))
        self.assertEqual(len(single["events"]), 1)
        self.assertEqual(single["events"][0]["kind"], "sunset")
        self.assertEqual(single["events"][0]["wallMs"], 86_399_999)

    async def test_request_bounds_and_named_fields_reject_without_partial_projection(self):
        invalid_requests = [
            self.request(nowMs=True),
            self.request(nowMs=controller.ECMASCRIPT_DATE_LIMIT_MS),
            self.request(zoneId="x" * 81),
            self.request(events=[{"kind": "sunrise", "epochMs": 1788238305216}] * 9),
            self.request(events=[{"kind": "noon", "epochMs": 1788238305216}]),
            self.request(events=[{"kind": "sunrise", "epochMs": float("nan")}]),
            self.request(displayTimes={"sunrise": 1788238305216, "private": 0}),
            self.request(displayTimes={"sunrise": "1788238305216"}),
        ]
        for index, request in enumerate(invalid_requests):
            with self.subTest(index=index):
                with tempfile.TemporaryDirectory() as temporary:
                    daemon = controller.ControllerDaemon(pathlib.Path(temporary))
                    client = RecordingClient()
                    await daemon.dispatch(client, request)
                self.assertEqual(len(client.messages), 1)
                self.assertEqual(client.messages[0]["type"], "error")
                self.assertEqual(client.messages[0]["code"], "invalid-request")
                self.assertNotIn("projection", client.messages[0])

        accepted = controller.project_civil_day(self.request(
            events=[
                {"kind": "sunrise" if index % 2 == 0 else "sunset", "epochMs": 1788238305216 + index}
                for index in range(8)
            ],
            displayTimes={},
        ))
        self.assertEqual(len(accepted["events"]), 8)

    async def test_projection_has_no_location_network_backend_or_override_side_effect(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            daemon.runtime_override = {
                "target": {"kind": "temperature", "temperature": 3333},
                "until": 123, "source": "external",
            }
            client = RecordingClient()
            with mock.patch.object(daemon.store, "read") as read, \
                    mock.patch.object(daemon.store, "write") as write, \
                    mock.patch.object(daemon.provider, "geocode") as geocode, \
                    mock.patch.object(daemon.provider, "auto_locate") as auto_locate, \
                    mock.patch.object(daemon.backend, "probe") as probe, \
                    mock.patch.object(daemon.backend, "apply") as apply:
                await daemon.dispatch(client, self.request(events=[], displayTimes={}))
            for operation in (read, write, geocode, auto_locate, probe, apply):
                operation.assert_not_called()
            self.assertEqual(daemon.runtime_override["target"]["temperature"], 3333)
            self.assertIsNone(daemon.pending)
            self.assertIsNone(daemon.deferred)
            self.assertEqual(client.messages[0]["type"], "civilDay")

    async def test_latest_timeline_generation_and_attachment_are_publication_barriers(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = controller.ControllerDaemon(pathlib.Path(temporary))
            old_client = RecordingClient()
            entered = threading.Event()
            gate = threading.Event()
            real_project = controller.project_civil_day

            def delayed(request):
                if request["requestId"] in ("old-generation", "old-attachment"):
                    entered.set()
                    gate.wait(1)
                return real_project(request)

            with mock.patch.object(controller, "project_civil_day", side_effect=delayed):
                old = asyncio.create_task(daemon.dispatch(old_client, self.request(
                    requestId="old-generation", generation=1, events=[], displayTimes={}
                )))
                await asyncio.wait_for(asyncio.to_thread(entered.wait), 1)
                # Even a deliberately reused generation is latest-request-wins.
                await daemon.dispatch(old_client, self.request(
                    requestId="new-generation", generation=1, events=[], displayTimes={}
                ))
                gate.set()
                await asyncio.wait_for(old, 1)
            self.assertEqual(
                [message.get("requestId") for message in old_client.messages],
                ["new-generation"],
            )

            entered.clear()
            gate.clear()
            fresh_client = RecordingClient()
            with mock.patch.object(controller, "project_civil_day", side_effect=delayed):
                old = asyncio.create_task(daemon.dispatch(old_client, self.request(
                    requestId="old-attachment", generation=3, events=[], displayTimes={}
                )))
                await asyncio.wait_for(asyncio.to_thread(entered.wait), 1)
                await daemon.dispatch(fresh_client, self.request(
                    requestId="fresh-attachment", generation=0, events=[], displayTimes={}
                ))
                gate.set()
                await asyncio.wait_for(old, 1)
            self.assertFalse(any(
                message.get("requestId") == "old-attachment" for message in old_client.messages
            ))
            self.assertEqual(fresh_client.messages[0]["requestId"], "fresh-attachment")

    async def test_real_unix_socket_new_projection_revokes_blocked_same_attachment_worker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            daemon = controller.ControllerDaemon(root)
            daemon.socket_path = root / "projection.sock"
            daemon.server = await asyncio.start_unix_server(
                daemon.handle_client, path=daemon.socket_path
            )
            reader, writer = await asyncio.open_unix_connection(daemon.socket_path)
            entered = threading.Event()
            gate = threading.Event()
            old_finished = threading.Event()
            real_project = controller.project_civil_day

            def delayed(request):
                if request["requestId"] == "socket-old":
                    entered.set()
                    try:
                        gate.wait(2)
                    finally:
                        old_finished.set()
                return real_project(request)

            try:
                ready = json.loads(await asyncio.wait_for(reader.readline(), 1))
                status = json.loads(await asyncio.wait_for(reader.readline(), 1))
                self.assertEqual(ready["type"], "ready")
                self.assertEqual(status["type"], "backendStatus")

                old_request = self.request(
                    requestId="socket-old", generation=1,
                    zoneId="Europe/Amsterdam", events=[], displayTimes={},
                )
                new_request = self.request(
                    requestId="socket-new", generation=2,
                    zoneId="Asia/Tokyo", events=[], displayTimes={},
                )
                with mock.patch.object(
                    controller, "project_civil_day", side_effect=delayed
                ):
                    writer.write((json.dumps(old_request) + "\n").encode())
                    await writer.drain()
                    await asyncio.wait_for(asyncio.to_thread(entered.wait), 1)

                    # This is one real attachment and one sequential NDJSON
                    # stream.  The reader must admit generation 2 while the
                    # generation-1 worker remains blocked.
                    writer.write((json.dumps(new_request) + "\n").encode())
                    await writer.drain()
                    response = json.loads(await asyncio.wait_for(reader.readline(), 1))
                    self.assertEqual(response["type"], "civilDay")
                    self.assertEqual(response["requestId"], "socket-new")
                    self.assertEqual(response["generation"], 2)
                    self.assertEqual(response["projection"]["zoneId"], "Asia/Tokyo")

                    gate.set()
                    await asyncio.wait_for(asyncio.to_thread(old_finished.wait), 1)
                    with self.assertRaises(asyncio.TimeoutError):
                        await asyncio.wait_for(reader.readline(), 0.1)
            finally:
                gate.set()
                daemon.closing = True
                writer.close()
                await writer.wait_closed()
                daemon.server.close()
                await daemon.server.wait_closed()

                async def clients_closed():
                    while daemon.clients:
                        await asyncio.sleep(0.005)

                await asyncio.wait_for(clients_closed(), 1)
                if daemon.release_task is not None:
                    daemon.release_task.cancel()
                    await asyncio.gather(daemon.release_task, return_exceptions=True)
                with contextlib.suppress(FileNotFoundError):
                    daemon.socket_path.unlink()


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
