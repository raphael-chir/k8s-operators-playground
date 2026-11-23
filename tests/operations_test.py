"""Cancelling a use case start (web/operations.py), with REAL processes: a fake `playground` script stands in for the engine, so nothing touches
Docker or Kubernetes. Covers: the whole process group ends (children, grandchildren, a child that ignores SIGTERM), the stop runs only after
the start is gone, the log is kept, a stop that cannot start is recorded as failed, repeated Cancel is refused, and a successful restart.
Run from tests/:  python3 -m unittest operations_test"""
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "web"))
import operations  # noqa: E402


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class CancelTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.log = self.tmp / "uc.log"
        self.events = self.tmp / "events"
        # "start" = a shell that records its pid, then spawns a stubborn child (ignores TERM) and a grandchild, as kind/helm/kubectl would.
        self.fake = self.tmp / "playground"
        self.fake.write_text(f"""#!/bin/bash
case "$2" in
  start) echo "start $$" >> {self.events}
         bash -c 'trap "" TERM; echo "stubborn $$" >> {self.events}; exec sleep 3071' &
         ( sleep 3071 & echo "grandchild $!" >> {self.events}; wait ) &
         echo "creating cluster"; sleep 3071 ;;
  stop)  [ -z "$(pgrep -f 'sleep 3071')" ] && echo "stop-after-start-gone" >> {self.events} || echo "STOP-WHILE-START-ALIVE" >> {self.events}
         echo "deleting clusters"; exit ${{STOP_RC:-0}} ;;
esac
""")
        self.fake.chmod(0o755)

    def spawn(self, target, mode="wb"):
        log = open(self.log, mode)
        proc = subprocess.Popen([str(self.fake), "usecase", target, "demo"], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        return log, proc

    def pids(self, word):
        return [int(l.split()[1]) for l in self.events.read_text().splitlines() if l.startswith(word)]

    def wait_for(self, word, n=1):
        for _ in range(100):
            if self.events.exists() and len(self.pids(word)) >= n:
                return
            time.sleep(0.05)
        self.fail(f"no '{word}' event")

    def run_cancel(self, stop_rc=0, spawn_fails=False):
        log, proc = self.spawn("start")
        old = {"proc": proc, "log_file": log, "state": "starting"}
        stop_op = {"kind": "stop", "state": "stopping", "exit_code": None, "finished": None, "log_file": None, "proc": None, "cancel": True}
        self.wait_for("stubborn"); self.wait_for("grandchild")
        os.environ["STOP_RC"] = str(stop_rc)
        done = threading.Event()

        def spawn():
            if spawn_fails:
                raise OSError("boom")
            with open(self.log, "ab") as m:
                m.write(b"\n--- Start cancelled ---\n")
            return self.spawn("stop", "ab")

        def watch(p):
            rc = p.wait()
            stop_op.update(state="succeeded" if rc == 0 else "failed", exit_code=rc)
        lock = threading.Lock()
        t = threading.Thread(target=lambda: (operations.cancel_then_stop(lock, old, stop_op, spawn, watch), done.set()))
        t.start(); t.join(20)
        self.assertTrue(done.is_set(), "cancel_then_stop did not finish")
        return old, stop_op

    def test_cancel_ends_the_whole_group_then_stops(self):
        old, stop_op = self.run_cancel()
        pids = self.pids("stubborn") + self.pids("grandchild") + self.pids("start")
        time.sleep(0.2)
        self.assertEqual([p for p in pids if alive(p)], [], "a process of the cancelled start survived")
        self.assertIn("stop-after-start-gone", self.events.read_text())      # the stop began only after the start was gone
        self.assertNotIn("STOP-WHILE-START-ALIVE", self.events.read_text())
        self.assertEqual(stop_op["state"], "succeeded")                       # Starting -> Cancel -> Stop -> Stopped

    def test_log_is_preserved_and_extended(self):
        self.run_cancel()
        text = self.log.read_text()
        self.assertIn("creating cluster", text); self.assertIn("Start cancelled", text); self.assertIn("deleting clusters", text)
        self.assertLess(text.index("creating cluster"), text.index("deleting clusters"))

    def test_cleanup_failure_is_reported_and_retryable(self):
        _, stop_op = self.run_cancel(stop_rc=3)
        self.assertEqual((stop_op["state"], stop_op["exit_code"]), ("failed", 3))      # "Cleanup failed": the page offers Stop again

    def test_a_stop_that_cannot_start_is_failed_not_stuck(self):
        _, stop_op = self.run_cancel(spawn_fails=True)
        self.assertEqual(stop_op["state"], "failed")

    def test_terminate_group_on_an_already_finished_start(self):
        _, proc = self.spawn("stop"); proc.wait()
        operations.terminate_group(proc)       # nothing left: no error

    def tearDown(self):
        os.system(f"pkill -f 'sleep 3071' 2>/dev/null; true")


class HostIssuesTest(unittest.TestCase):
    """The data behind the dashboard's resource confirmation: what the host sampler wrote, only when fresh, never for an external use case."""
    def write(self, age=0, body=None):
        f = Path(tempfile.mkdtemp()) / ".host-checks"
        body = body if body is not None else ("disk|CRITICAL|Host disk usage|99% used;;3.4 GiB free|<85%|Below 10% free the kubelet reports DiskPressure.|fix|\n"
                                              "inotify|WARNING|Linux inotify limits|a;;b|rec|Kind may fail.|fix|restore\n"
                                              "memory|UNAVAILABLE|Host memory|unavailable||||\n")
        f.write_text(f"#ts={time.time() - age}\n{body}")
        return f

    def test_issues_are_critical_and_warning_only(self):
        issues = operations.host_issues(self.write(), "internal")
        self.assertEqual([i["id"] for i in issues], ["disk", "inotify"])          # UNAVAILABLE is not an issue
        self.assertEqual(issues[0]["status"], "CRITICAL")
        self.assertEqual(issues[0]["current"], "99% used / 3.4 GiB free")
        self.assertIn("DiskPressure", issues[0]["impact"])

    def test_external_is_never_checked(self):
        self.assertEqual(operations.host_issues(self.write(), "external"), [])

    def test_stale_file_means_no_confirmation_not_a_block(self):
        self.assertEqual(operations.host_issues(self.write(age=21), "internal"), [])      # older than 20 s
        self.assertEqual(len(operations.host_issues(self.write(age=19), "internal")), 2)  # within the window

    def test_missing_or_broken_file(self):
        self.assertEqual(operations.host_issues(Path(tempfile.mkdtemp()) / "nope", "internal"), [])
        f = Path(tempfile.mkdtemp()) / "x"; f.write_text("garbage\n"); self.assertEqual(operations.host_issues(f, "internal"), [])

    def test_no_issue(self):
        self.assertEqual(operations.host_issues(self.write(body=""), "internal"), [])


class StartConfirmationSourceTest(unittest.TestCase):
    """web/app.py (checked on its source, FastAPI is not needed): the start answers resource warnings with a distinguishable 409, and the
    confirmed request goes straight to the unchanged _launch."""
    SRC = (Path(__file__).resolve().parent.parent / "web" / "app.py").read_text()
    JS = (Path(__file__).resolve().parent.parent / "web" / "static" / "app.js").read_text()

    def test_server(self):
        self.assertIn('body.get("confirm_resources") is not True', self.SRC)
        self.assertIn('"code": "resource_confirmation"', self.SRC)
        self.assertIn("status_code=409", self.SRC)
        self.assertIn("operations.host_issues(HOST_CHECKS_FILE, ptype)", self.SRC)

    def test_page(self):
        self.assertIn('e.code === "resource_confirmation"', self.JS)       # only this 409 opens the dialog; the others are shown as errors
        self.assertIn("confirm_resources: true", self.JS)
        self.assertIn("Continue anyway", self.JS)


class RegistryRulesTest(unittest.TestCase):
    """The 409 rules of web/app.py _launch, checked on its source (FastAPI is not needed): Cancel is only a stop while 'starting', a second
    Cancel finds the registered stop operation, and a start during a stop is refused."""
    SRC = (Path(__file__).resolve().parent.parent / "web" / "app.py").read_text()

    def test_rules_are_in_place(self):
        self.assertIn('kind == "stop" and current["state"] == "starting" and current.get("proc")', self.SRC)
        self.assertIn('already has an operation in progress', self.SRC)
        self.assertIn('_ops[name] = op', self.SRC)                      # the stop is registered under the lock BEFORE the start is killed
        self.assertIn('"ab"', self.SRC)                                  # a cancelled start's log is appended to, never truncated
        self.assertIn('operations.cancel_then_stop', self.SRC)


if __name__ == "__main__":
    unittest.main()
