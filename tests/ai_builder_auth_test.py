"""Tests of the browser sign-in (ai-builder/auth.py) with a FAKE `claude` script that mimics the login screen in a real PTY.
The real Claude Code CLI is never started: no real login, logout or generation. Nothing runs Docker, Kind, Kubernetes or Helm.
Run: tests/ai-builder.sh"""
import contextlib
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import threading
import time
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "ai-builder"))
import auth, builder, server  # noqa: E402

CODE = "Zx9aQ-test_CODE.value~1234#state567890"
URL = "https://claude.ai/oauth/authorize?code=true&client_id=fake&state=abc"
LEAKS = ["person@example.com", "sk-ant-oat01-LEAKLEAK", "Press Enter"]       # printed by the fake: must never reach an API answer

FAKE = r'''#!/usr/bin/env python3
import json, os, sys, time
state, mode = os.environ["FAKE_STATE"], os.environ.get("FAKE_MODE", "ok")
args = sys.argv[1:]
open(os.path.join(state, "argv.log"), "a").write(json.dumps(args) + "\n")
marker = os.path.join(state, "logged_in")
if args[:2] == ["auth", "status"]:
    print(json.dumps({"loggedIn": os.path.exists(marker), "loginExpiresAt": None, "email": "person@example.com"}))
    sys.exit(0 if os.path.exists(marker) else 1)
if args[:2] == ["auth", "logout"]:
    if os.path.exists(marker): os.remove(marker)
    print("Logged out"); sys.exit(0)
if args[:2] == ["auth", "login"]:
    if mode == "exit":
        print("boom"); sys.exit(1)
    if mode == "nourl":
        time.sleep(60)
    print("Use the URL below to sign in")
    print("\x1b[1m" + os.environ.get("FAKE_URL", "https://claude.ai/oauth/authorize?code=true&client_id=fake&state=abc") + "\x1b[0m")
    print("Paste code here if prompted > ", end="", flush=True)
    line = sys.stdin.readline().strip()
    expected = open(os.path.join(state, "expected")).read()
    if mode == "wrong" or line != expected:
        print("Authentication failed: Invalid authorization code", flush=True); time.sleep(30); sys.exit(1)
    if mode != "nostatus":
        open(marker, "w").write("1")
    print("Logged in as person@example.com sk-ant-oat01-LEAKLEAK")
    print("Login successful. Press Enter to continue...", flush=True)
    sys.stdin.readline(); sys.exit(0)
sys.exit(2)
'''


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "state").mkdir(); (self.tmp / "state" / "expected").write_text(CODE)
        self.fake = self.tmp / "claude"; self.fake.write_text(FAKE); self.fake.chmod(self.fake.stat().st_mode | stat.S_IXUSR)
        os.environ["FAKE_STATE"] = str(self.tmp / "state"); os.environ.pop("FAKE_MODE", None); os.environ.pop("FAKE_URL", None)
        self.addCleanup(lambda: [os.environ.pop(k, None) for k in ("FAKE_STATE", "FAKE_MODE", "FAKE_URL")])
        self.busy = False
        self.mgr = self.make()

    def make(self, timeout=60, clock=time.monotonic):
        root = self.tmp / "repo"; root.mkdir(exist_ok=True)
        cfg = builder.Config(env={"AI_BUILDER_CLAUDE": str(self.fake), "AI_BUILDER_LOGIN_TIMEOUT": str(timeout), "AI_BUILDER_QUIET": "1",
                                  "CLAUDE_CONFIG_DIR": str(self.tmp / "claude-config")}, root=root)
        mgr = auth.AuthManager(cfg, generation_busy=lambda: self.busy, clock=clock)
        self.addCleanup(lambda: mgr.cancel())
        return mgr

    def wait(self, pred, what="condition", timeout=12):
        end = time.time() + timeout
        while time.time() < end:
            if pred(): return
            time.sleep(0.05)
        self.fail(f"timed out waiting for {what}: {self.mgr.public()}")

    def state(self): return (self.mgr.public() or {}).get("state")
    def argv(self): return [json.loads(l) for l in (self.tmp / "state" / "argv.log").read_text().splitlines()] if (self.tmp / "state" / "argv.log").exists() else []
    def logins(self): return [a for a in self.argv() if a[:2] == ["auth", "login"]]
    def to_code(self):
        self.mgr.start(); self.wait(lambda: self.state() == "awaiting_browser", "the sign-in address")


class Parsing(unittest.TestCase):
    def test_official_address_is_extracted_from_ansi_output(self):
        text = "\x1b[2J\x1b[1;1HUse the URL below to sign in\r\n\x1b[1mhttps://claude.ai/oauth/authorize?code=true&state=a%20b\x1b[0m\r\nPaste code here if prompted > "
        self.assertEqual(auth.extract_login_url(text), "https://claude.ai/oauth/authorize?code=true&state=a%20b")
        self.assertEqual(auth.extract_login_url("visit https://platform.claude.com/oauth/authorize?x=1."), "https://platform.claude.com/oauth/authorize?x=1")
        self.assertEqual(auth.extract_login_url("https://claude.com/cai/oauth/authorize?x=1)"), "https://claude.com/cai/oauth/authorize?x=1")

    def test_foreign_or_unsafe_addresses_are_never_offered(self):
        for bad in ("https://evil.example/login", "http://claude.ai/oauth", "https://claude.ai.evil.example/x", "https://evil.example/claude.ai",
                    "https://user:pw@claude.ai/x", "https://notclaude.ai/x", "http://localhost:4444/callback", "javascript:alert(1)", "https://anthropic.com.evil.co/x"):
            self.assertIsNone(auth.extract_login_url(bad), bad); self.assertFalse(auth.allowed_login_url(bad), bad)
        self.assertIsNone(auth.extract_login_url("https://evil.example/ then https://claude.ai.evil.example/")),
        self.assertEqual(auth.extract_login_url("https://evil.example/a https://claude.ai/oauth/authorize?y=2"), "https://claude.ai/oauth/authorize?y=2")

    def test_code_shape(self):
        for ok in (CODE, "abcdefgh", "A" * 2048): self.assertTrue(auth.CODE_RE.match(ok), ok[:20])
        for bad in ("", "short", "has space in it", "line\nbreak1234", "https://claude.ai/x", "a" * 2049, "code;rm -rf", "$(id)12345", "\x00" * 10): self.assertFalse(auth.CODE_RE.match(bad), repr(bad[:20]))


class Lifecycle(Base):
    def test_sign_in_with_a_code(self):
        self.assertFalse(self.mgr.status()["logged_in"])
        s = self.mgr.start()
        self.assertEqual(s["session"]["state"], "starting"); self.assertEqual(set(s), {"logged_in", "expires_at", "enabled", "session"})
        self.wait(lambda: self.state() == "awaiting_browser", "the sign-in address")
        pub = self.mgr.public()
        self.assertEqual((pub["url"], pub["awaiting_code"]), (URL, True)); self.assertGreater(pub["seconds_left"], 0)
        self.assertEqual(self.logins(), [["auth", "login", "--claudeai"]], "fixed arguments only")
        self.mgr.submit_code(CODE)
        self.wait(lambda: self.state() == "succeeded", "success")
        st = self.mgr.status()
        self.assertTrue(st["logged_in"]); self.assertIsNone(st["session"]["url"]); self.assertIsNone(st["session"]["error"])

    def test_method_and_email_become_separate_arguments(self):
        self.mgr.start("sso", "person@example.co"); self.wait(lambda: self.logins(), "the process")
        self.assertEqual(self.logins()[0], ["auth", "login", "--sso", "--email", "person@example.co"])

    def test_invalid_method_or_email_never_starts_a_process(self):
        for m, e in (("bash", None), ("claudeai", "x@y"), ("claudeai", "a b@c.de"), ("claudeai", "a@b.co; id"), ("--help", None), ("claudeai", 5)):
            with self.assertRaises(auth.AuthError) as cm: self.mgr.start(m, e)
            self.assertEqual(cm.exception.status, 400)
        self.assertEqual(self.logins(), [])

    def test_only_one_session_and_never_during_generation(self):
        self.to_code()
        with self.assertRaises(auth.AuthError) as cm: self.mgr.start()
        self.assertEqual(cm.exception.status, 409); self.assertEqual(len(self.logins()), 1)
        self.mgr.cancel(); self.wait(lambda: self.state() == "cancelled")
        self.busy = True
        with self.assertRaises(auth.AuthError) as cm: self.mgr.start()
        self.assertEqual(cm.exception.status, 409); self.assertIn("generation", str(cm.exception))

    def test_code_is_refused_unless_a_sign_in_waits_for_it(self):
        with self.assertRaises(auth.AuthError) as cm: self.mgr.submit_code(CODE)
        self.assertEqual(cm.exception.status, 409)
        self.to_code()
        for bad in ("https://claude.ai/oauth/code/callback", "two words here", "short", None, 123, ""):
            with self.assertRaises(auth.AuthError) as cm: self.mgr.submit_code(bad)
            self.assertEqual(cm.exception.status, 400)
        self.assertEqual(self.state(), "awaiting_browser", "a rejected paste does not disturb the session")
        self.mgr.submit_code(CODE)
        with self.assertRaises(auth.AuthError) as cm: self.mgr.submit_code(CODE)       # already verifying or finished
        self.assertEqual(cm.exception.status, 409)

    def test_wrong_code_fails_with_a_fixed_message_and_a_new_attempt_is_possible(self):
        os.environ["FAKE_MODE"] = "wrong"
        self.to_code(); self.mgr.submit_code(CODE)
        self.wait(lambda: self.state() == "failed", "failure")
        self.assertEqual(self.mgr.public()["error"], auth.MESSAGES["invalid_code"]); self.assertFalse(self.mgr.status()["logged_in"])
        os.environ["FAKE_MODE"] = "ok"
        self.to_code(); self.mgr.submit_code(CODE); self.wait(lambda: self.state() == "succeeded", "second attempt")

    def test_cancellation_kills_the_login_process(self):
        self.to_code(); proc = self.mgr._proc
        self.assertIsNotNone(proc); self.assertIsNone(proc.poll())
        self.assertEqual(self.mgr.cancel()["session"]["state"], "cancelled")
        self.wait(lambda: proc.poll() is not None, "process exit")
        self.assertFalse(self.mgr.active()); self.mgr.start()                          # and a new one can start

    def test_timeout_ends_the_session_and_the_process(self):
        mgr = self.make(timeout=1)
        self.mgr = mgr; mgr.start(); self.wait(lambda: self.state() == "awaiting_browser")
        proc = mgr._proc
        self.wait(lambda: self.state() == "failed", "timeout", 8)
        self.assertEqual(mgr.public()["error"], auth.MESSAGES["timeout"]); self.wait(lambda: proc.poll() is not None, "process exit")
        self.assertIsNone(mgr.public()["url"])

    def test_no_address_in_time(self):
        os.environ["FAKE_MODE"] = "nourl"
        clock = {"t": 1000.0}
        mgr = self.make(timeout=600, clock=lambda: clock["t"]); self.mgr = mgr
        mgr.start(); time.sleep(0.5); clock["t"] += 60                                  # a minute passes, nothing was printed
        self.wait(lambda: self.state() == "failed", "no_url")
        self.assertEqual(mgr.public()["error"], auth.MESSAGES["no_url"])

    def test_process_that_exits_early_is_a_failure(self):
        os.environ["FAKE_MODE"] = "exit"
        self.mgr.start(); self.wait(lambda: self.state() == "failed", "failure")
        self.assertEqual(self.mgr.public()["error"], auth.MESSAGES["exited"])

    def test_the_screen_is_not_trusted_without_a_login(self):
        os.environ["FAKE_MODE"] = "nostatus"                                            # says "Login successful" but nothing is stored
        self.to_code(); self.mgr.submit_code(CODE); self.wait(lambda: self.state() == "failed", "failure")
        self.assertEqual(self.mgr.public()["error"], auth.MESSAGES["not_confirmed"])

    def test_missing_cli_is_reported_not_raised(self):
        self.fake.unlink()
        self.assertEqual(self.mgr.status()["error"], "claude_missing"); self.assertIsNone(self.mgr.status()["logged_in"])
        self.assertEqual(self.mgr.start()["session"]["error"], auth.MESSAGES["start_failed"])


class HostMode(Base):
    """Without CLAUDE_CONFIG_DIR (host mode) `claude auth ...` would touch the developer's own login: the sign-in is refused."""

    def setUp(self):
        super().setUp()
        root = self.tmp / "repo2"; root.mkdir()
        cfg = builder.Config(env={"AI_BUILDER_CLAUDE": str(self.fake)}, root=root)
        self.mgr = auth.AuthManager(cfg)

    def test_nothing_is_started_or_signed_out_in_host_mode(self):
        self.assertEqual(self.mgr.status(), {"logged_in": None, "expires_at": None, "enabled": False, "session": None})
        for call in (lambda: self.mgr.start(), lambda: self.mgr.submit_code(CODE), lambda: self.mgr.logout()):
            with self.assertRaises(auth.AuthError) as cm: call()
            self.assertEqual(cm.exception.status, 403); self.assertIn("container", str(cm.exception))
        self.assertEqual(self.argv(), [], "the claude binary was never run")
        self.assertEqual(self.mgr.cancel()["session"], None)

    def test_explicit_opt_in(self):
        os.environ["AI_BUILDER_ALLOW_HOST_AUTH"] = "1"; self.addCleanup(os.environ.pop, "AI_BUILDER_ALLOW_HOST_AUTH", None)
        cfg = builder.Config(env={"AI_BUILDER_CLAUDE": str(self.fake)}, root=self.tmp / "repo2")
        self.assertTrue(auth.AuthManager(cfg).enabled)


class Logout(Base):
    def signed_in(self):
        self.to_code(); self.mgr.submit_code(CODE); self.wait(lambda: self.state() == "succeeded")

    def test_logout_and_reconnect(self):
        self.signed_in(); self.assertTrue(self.mgr.status()["logged_in"])
        st = self.mgr.logout()
        self.assertFalse(st["logged_in"]); self.assertIsNone(st["session"])
        self.assertIn(["auth", "logout"], self.argv())
        self.signed_in(); self.assertTrue(self.mgr.status()["logged_in"])

    def test_logout_is_refused_during_a_sign_in_or_a_generation(self):
        self.to_code()
        with self.assertRaises(auth.AuthError) as cm: self.mgr.logout()
        self.assertEqual(cm.exception.status, 409)
        self.mgr.cancel(); self.busy = True
        with self.assertRaises(auth.AuthError) as cm: self.mgr.logout()
        self.assertEqual(cm.exception.status, 409); self.assertNotIn(["auth", "logout"], self.argv())

    def test_status_is_cached_briefly_and_refreshed_after_changes(self):
        self.mgr.status(); self.mgr.status(); self.mgr.status()
        self.assertEqual(len([a for a in self.argv() if a[:2] == ["auth", "status"]]), 1)
        self.signed_in(); self.assertTrue(self.mgr.status()["logged_in"])


class NoSecrets(Base):
    def everything_returned(self):
        return json.dumps([self.mgr.public(), self.mgr.status()])

    def test_neither_the_code_nor_the_screen_leaks(self):
        out, err = io.StringIO(), io.StringIO()
        seen = []
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.to_code(); seen.append(self.everything_returned())
            self.mgr.submit_code(CODE); seen.append(self.everything_returned())
            self.wait(lambda: self.state() == "succeeded"); seen.append(self.everything_returned())
        blob = "".join(seen) + out.getvalue() + err.getvalue()
        for secret in [CODE, "Zx9aQ", *LEAKS]: self.assertNotIn(secret, blob, secret)
        keys = set(self.mgr.status()) | set(self.mgr.status()["session"]); self.assertLessEqual(keys, {"logged_in", "expires_at", "enabled", "error", "session", "state", "method", "url", "awaiting_code", "seconds_left"})

    def test_the_code_is_not_kept_in_memory_state_or_on_disk(self):
        self.to_code(); self.mgr.submit_code(CODE); self.wait(lambda: self.state() == "succeeded")
        self.assertNotIn(CODE, repr(self.mgr.session)); self.assertNotIn(CODE, repr(vars(self.mgr)))
        for p in self.tmp.rglob("*"):
            if p.is_file() and p.name != "expected":                                    # "expected" is the fake CLI's own fixture
                self.assertNotIn(CODE, p.read_text(errors="replace"), str(p))

    def test_errors_do_not_echo_the_pasted_value(self):
        self.to_code()
        for bad in ("https://claude.ai/leak-me-12345", "secret value with spaces"):
            with self.assertRaises(auth.AuthError) as cm: self.mgr.submit_code(bad)
            self.assertNotIn("leak-me", str(cm.exception)); self.assertNotIn("secret value", str(cm.exception))


class Http(Base):
    TOKEN = "t" * 64

    def setUp(self):
        super().setUp()
        tf = self.tmp / "token"; tf.write_text(self.TOKEN)
        root = self.tmp / "repo"; (root / "usecases" / "cnpg-standard").mkdir(parents=True)
        self.cfg = builder.Config(env={"AI_BUILDER_CLAUDE": str(self.fake), "AI_BUILDER_TOKEN_FILE": str(tf), "AI_BUILDER_STATE_DIR": str(self.tmp / "jobs"),
                                       "CLAUDE_CONFIG_DIR": str(self.tmp / "claude-config")}, root=root)
        self.jobs = builder.JobManager(self.cfg, runner=lambda *a: (1, "", "", False))
        self.mgr = auth.AuthManager(self.cfg, generation_busy=self.jobs.busy); self.addCleanup(self.mgr.cancel)
        self.log = io.StringIO()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.jobs, self.cfg, "t", self.mgr))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close); self.addCleanup(self.httpd.shutdown)

    def call(self, method, path, body=None, token=True, ctype="application/json"):
        c = HTTPConnection("127.0.0.1", self.port, timeout=15)
        h = {"Host": f"127.0.0.1:{self.port}", "Content-Type": ctype}
        if token: h["Authorization"] = f"Bearer {self.TOKEN}"
        c.request(method, path, None if body is None else (body if isinstance(body, (str, bytes)) else json.dumps(body)), h)
        r = c.getresponse(); data = json.loads(r.read() or b"{}"); c.close(); return r.status, data

    def test_routes_need_the_bearer_token(self):
        for method, path in (("GET", "/auth/status"), ("POST", "/auth/login"), ("POST", "/auth/code"), ("POST", "/auth/cancel"), ("POST", "/auth/logout")):
            self.assertEqual(self.call(method, path, {} if method == "POST" else None, token=False)[0], 401, path)

    def test_full_flow_over_http_without_logging_the_code(self):
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            self.cfg.quiet = False                                                      # the access log is ON for this test
            st, body = self.call("GET", "/auth/status"); self.assertEqual((st, body["logged_in"], body["session"]), (200, False, None))
            st, body = self.call("POST", "/auth/login", {}); self.assertEqual(st, 200)
            self.wait(lambda: self.call("GET", "/auth/status")[1]["session"]["state"] == "awaiting_browser")
            self.assertEqual(self.call("GET", "/auth/status")[1]["session"]["url"], URL)
            self.assertEqual(self.call("POST", "/auth/login", {})[0], 409)
            self.assertEqual(self.call("POST", "/auth/code", {"code": "not a code"})[0], 400)
            self.assertEqual(self.call("POST", "/auth/code", "{broken")[0], 400)
            self.assertEqual(self.call("POST", "/auth/code", {"code": CODE}, ctype="text/plain")[0], 415)
            st, body = self.call("POST", "/auth/code", {"code": CODE}); self.assertEqual(st, 200)
            self.wait(lambda: self.call("GET", "/auth/status")[1]["session"]["state"] == "succeeded")
            self.assertTrue(self.call("GET", "/auth/status")[1]["logged_in"])
            self.assertEqual(self.call("POST", "/auth/logout")[0], 200); self.assertFalse(self.call("GET", "/auth/status")[1]["logged_in"])
        log = captured.getvalue()
        self.assertIn("POST /auth/code", log, "the request line is logged"); self.assertNotIn(CODE, log); self.assertNotIn("Zx9aQ", log)

    def test_cancel_over_http(self):
        self.call("POST", "/auth/login", {}); self.wait(lambda: self.call("GET", "/auth/status")[1]["session"]["state"] == "awaiting_browser")
        st, body = self.call("POST", "/auth/cancel"); self.assertEqual((st, body["session"]["state"]), (200, "cancelled"))

    def test_login_body_is_optional_but_validated(self):
        self.assertEqual(self.call("POST", "/auth/login", {"method": "nope"})[0], 400)
        self.assertEqual(self.call("POST", "/auth/login", {"email": "bad"})[0], 400)
        self.assertEqual(self.call("POST", "/auth/login", "[1]")[0], 400)
        self.assertEqual(self.call("POST", "/auth/other", {})[0], 404)

    def test_generation_and_sign_in_do_not_overlap(self):
        self.call("POST", "/auth/login", {}); self.wait(lambda: self.mgr.active())
        st, body = self.call("POST", "/generate", {"name": "my-demo", "description": "Demonstrate something useful"})
        self.assertEqual(st, 409); self.assertIn("sign-in", body["error"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
