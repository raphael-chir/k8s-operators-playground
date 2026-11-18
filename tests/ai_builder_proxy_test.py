"""Tests of the Playground -> AI Builder proxy (web/ai_builder_proxy.py) against a FAKE upstream HTTP server on 127.0.0.1.
Nothing here starts Docker, Claude Code or the real AI Builder. The FastAPI wrappers in web/app.py are checked
statically (AST) because FastAPI is not installed on the host. Run: tests/ai-builder.sh"""
import ast
import json
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "web"))
import ai_builder_proxy as P  # noqa: E402

TOKEN = "k" * 64
JOB = "20261117-120000-abc123"
GOOD = {"host": "127.0.0.1:8080", "x-requested-with": "playground", "content-type": "application/json"}


class Upstream:
    """A scripted fake of the AI Builder: records every request, answers with the configured (status, body)."""

    def __init__(self):
        self.requests, self.reply, self.delay, self.raw = [], (200, {"ok": True}), 0, None
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass

            def _do(self):
                n = int(self.headers.get("Content-Length", "0") or 0)
                outer.requests.append({"method": self.command, "path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()},
                                       "body": self.rfile.read(n) if n else b""})
                time.sleep(outer.delay)
                status, body = outer.reply
                data = outer.raw if outer.raw is not None else json.dumps(body).encode()
                try:
                    self.send_response(status); self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
                except OSError:
                    pass
            do_GET = do_POST = do_DELETE = _do

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown(); self.httpd.server_close()


class Base(unittest.TestCase):
    def setUp(self):
        self.up = Upstream(); self.addCleanup(self.up.close)
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.tokenfile = Path(self.tmp.name) / "token"; self.tokenfile.write_text(TOKEN + "\n")
        self.proxy = P.Proxy(f"http://127.0.0.1:{self.up.port}", str(self.tokenfile), scale=1.0)

    def post_generate(self, body=None, headers=None):
        return self.proxy.handle("generate", {**GOOD, **(headers or {})}, json.dumps(body or {"name": "my-demo", "description": "Demonstrate X well"}).encode())


class Forwarding(Base):
    def test_every_operation_reaches_the_right_upstream_path_with_the_token(self):
        for op, method, path in (("health", "GET", "/health"), ("status", "GET", f"/status/{JOB}"), ("review", "GET", f"/review/{JOB}"),
                                 ("approve", "POST", f"/approve/{JOB}"), ("publish", "POST", f"/publish/{JOB}")):
            self.up.requests.clear()
            status, _ = self.proxy.handle(op, GOOD, None, JOB if op not in ("health",) else None)
            self.assertEqual(status, 200, op)
            r = self.up.requests[0]
            self.assertEqual((r["method"], r["path"]), (method, path))
            self.assertEqual(r["headers"]["authorization"], f"Bearer {TOKEN}")
        self.up.requests.clear()
        self.assertEqual(self.post_generate()[0], 200)
        r = self.up.requests[0]
        self.assertEqual((r["method"], r["path"], r["headers"]["content-type"]), ("POST", "/generate", "application/json"))
        self.assertEqual(json.loads(r["body"])["name"], "my-demo")

    def test_browser_headers_are_never_forwarded(self):
        self.proxy.handle("status", {**GOOD, "authorization": "Bearer attacker", "cookie": "s=1", "x-forwarded-for": "6.6.6.6"}, None, JOB)
        h = self.up.requests[0]["headers"]
        self.assertEqual(h["authorization"], f"Bearer {TOKEN}")
        self.assertNotIn("cookie", h); self.assertNotIn("x-forwarded-for", h); self.assertEqual(h["host"], f"127.0.0.1:{self.up.port}")

    def test_the_token_never_appears_in_anything_returned(self):
        self.up.reply = (409, {"error": "boom", "details": ["a"]})
        outputs = [self.proxy.handle("status", GOOD, None, JOB), self.proxy.handle("health", GOOD)]
        self.up.reply = (401, {"error": "bad token"}); outputs.append(self.proxy.handle("status", GOOD, None, JOB))
        self.tokenfile.write_text("short"); outputs.append(self.proxy.handle("status", GOOD, None, JOB))
        self.tokenfile.unlink(); outputs.append(self.proxy.handle("status", GOOD, None, JOB))
        self.assertNotIn(TOKEN, json.dumps(outputs))

    def test_job_ids_are_validated_and_the_destination_is_fixed(self):
        for bad in ("../../etc/passwd", "x", "", "20261117-120000-ABCDEF", JOB + "/../health", JOB + "?a=1", "http://evil/x", "%2e%2e"):
            self.up.requests.clear()
            self.assertEqual(self.proxy.handle("status", GOOD, None, bad)[0], 400, bad)
            self.assertEqual(self.up.requests, [], bad)
        with self.assertRaises(KeyError): self.proxy.handle("exec", GOOD)       # no operation outside the table
        with self.assertRaises(ValueError): P.Proxy("https://elsewhere:443")
        with self.assertRaises(ValueError): P.Proxy("http://user:pw@host:80")


CONV = "c-20261117-120000-abc123"


class ConversationOperations(Base):
    def test_every_conversation_operation_reaches_the_right_upstream_path(self):
        cases = (("conv_create", "POST", "/conversations", None, {"lab": "cnpg-standard"}), ("conv_list", "GET", "/conversations", None, None),
                 ("conv_get", "GET", f"/conversations/{CONV}", CONV, None), ("conv_send", "POST", f"/conversations/{CONV}/messages", CONV, {"message": "hi"}))
        for op, method, path, cid, body in cases:
            self.up.requests.clear()
            status, _ = self.proxy.handle(op, GOOD, None if body is None else json.dumps(body).encode(), cid)
            self.assertEqual(status, 200, op)
            r = self.up.requests[0]
            self.assertEqual((r["method"], r["path"]), (method, path), op)
            self.assertEqual(r["headers"]["authorization"], f"Bearer {TOKEN}")

    def test_deleting_a_conversation_is_a_DELETE_with_the_csrf_header_and_a_validated_id(self):
        self.assertEqual(self.proxy.handle("conv_delete", GOOD, None, CONV)[0], 200)
        r = self.up.requests[0]
        self.assertEqual((r["method"], r["path"], r["headers"]["authorization"]), ("DELETE", f"/conversations/{CONV}", f"Bearer {TOKEN}"))
        self.up.requests.clear()
        no_csrf = {k: v for k, v in GOOD.items() if k != "x-requested-with"}
        self.assertEqual(self.proxy.handle("conv_delete", no_csrf, None, CONV)[0], 403)
        for bad in (JOB, "../x", "c-1", "", None, CONV + "/../x", CONV + "/review"):
            self.assertEqual(self.proxy.handle("conv_delete", GOOD, None, bad)[0], 400, bad)
        self.assertEqual(self.proxy.handle("conv_delete", {**GOOD, "host": "evil.example"}, None, CONV)[0], 403)
        self.assertEqual(self.up.requests, [], "nothing reached the AI Builder")
        self.up.reply = (409, {"error": "this conversation is still answering: wait for the reply, then delete it"})
        status, payload = self.proxy.handle("conv_delete", GOOD, None, CONV)
        self.assertEqual((status, payload["error"][:22]), (409, "this conversation is s"))

    def test_the_lab_editing_operations_reach_the_right_upstream_path(self):
        cases = (("conv_review", "GET", None), ("conv_undo", "POST", None), ("conv_reset", "POST", None), ("conv_discard", "POST", None),
                 ("conv_publish", "POST", {"approve": True, "tree_hash": "a" * 64}))
        for op, method, body in cases:
            self.up.requests.clear()
            self.assertEqual(self.proxy.handle(op, GOOD, None if body is None else json.dumps(body).encode(), CONV)[0], 200, op)
            r = self.up.requests[0]
            self.assertEqual((r["method"], r["path"], r["headers"]["authorization"]), (method, f"/conversations/{CONV}/{op[5:]}", f"Bearer {TOKEN}"), op)
        self.up.requests.clear()
        for op in ("conv_review", "conv_undo", "conv_reset", "conv_discard", "conv_publish"):
            self.assertEqual(self.proxy.handle(op, GOOD, b"{}", JOB)[0], 400, "a job id is not a conversation id")
            self.assertEqual(self.proxy.handle(op, GOOD, b"{}", "c-1/../x")[0], 400)
        self.assertEqual(self.up.requests, [])

    def test_the_state_changing_editing_operations_need_the_csrf_header(self):
        no_csrf = {k: v for k, v in GOOD.items() if k != "x-requested-with"}
        for op in ("conv_undo", "conv_reset", "conv_discard", "conv_publish"):
            self.assertEqual(self.proxy.handle(op, no_csrf, b"{}", CONV)[0], 403, op)
        self.assertEqual(self.proxy.handle("conv_review", no_csrf, None, CONV)[0], 200, "reading needs no header")
        self.assertEqual(self.proxy.handle("conv_publish", GOOD, b"nope", CONV)[0], 400)
        self.assertEqual(self.proxy.handle("conv_publish", {**GOOD, "content-type": "text/plain"}, b"{}", CONV)[0], 415)

    def test_conflict_and_validation_answers_pass_through_and_a_big_review_is_accepted(self):
        self.up.reply = (409, {"error": "conflict: usecases/x changed since the working copy was made", "details": ["conflict"]})
        status, payload = self.proxy.handle("conv_publish", GOOD, b'{"approve": true, "tree_hash": "x"}', CONV)
        self.assertEqual((status, payload["error"][:9]), (409, "conflict:"))
        self.up.reply = (200, {"diff": ["x" * 1500000]})
        self.assertEqual(self.proxy.handle("conv_review", GOOD, None, CONV)[0], 200)

    def test_a_conversation_id_is_validated_and_a_job_id_is_not_accepted_for_it(self):
        for bad in (JOB, "../x", "c-1", "", None, CONV + "/../x", "c-20261117-120000-ABCDEF"):
            self.assertEqual(self.proxy.handle("conv_get", GOOD, None, bad)[0], 400, bad)
            self.assertEqual(self.proxy.handle("conv_send", GOOD, b'{"message":"x"}', bad)[0], 400, bad)
        self.assertEqual(self.proxy.handle("status", GOOD, None, CONV)[0], 400, "and a conversation id is not a job id")
        self.assertEqual(self.up.requests, [])

    def test_sending_needs_the_csrf_header_and_a_json_object(self):
        no_csrf = {k: v for k, v in GOOD.items() if k != "x-requested-with"}
        self.assertEqual(self.proxy.handle("conv_send", no_csrf, b'{"message":"x"}', CONV)[0], 403)
        self.assertEqual(self.proxy.handle("conv_create", no_csrf, b"{}")[0], 403)
        self.assertEqual(self.proxy.handle("conv_send", GOOD, b"[1]", CONV)[0], 400)
        self.assertEqual(self.proxy.handle("conv_send", GOOD, b"nope", CONV)[0], 400)
        self.assertEqual(self.proxy.handle("conv_send", {**GOOD, "content-type": "text/plain"}, b'{"message":"x"}', CONV)[0], 415)
        self.assertEqual(self.up.requests, [])

    def test_a_message_is_forwarded_without_escaping_inflation(self):
        message = "é漢" * 2000
        self.assertEqual(self.proxy.handle("conv_send", GOOD, json.dumps({"message": message}).encode(), CONV)[0], 200)
        raw = self.up.requests[0]["body"]
        self.assertEqual(json.loads(raw)["message"], message); self.assertLess(len(raw), 16 * 1024)

    def test_a_large_conversation_answer_is_accepted_but_not_a_huge_one(self):
        self.up.reply = (200, {"messages": ["x" * 1500000]})
        self.assertEqual(self.proxy.handle("conv_get", GOOD, None, CONV)[0], 200)
        self.assertEqual(self.proxy.handle("status", GOOD, None, JOB)[0], 502, "the default 1 MB limit still applies elsewhere")
        self.up.reply = (200, {"messages": ["x" * 2500000]})
        self.assertEqual(self.proxy.handle("conv_get", GOOD, None, CONV)[0], 502)

    def test_conversation_answers_never_carry_the_token_and_upstream_errors_pass_through(self):
        self.up.reply = (409, {"error": "the conversation budget of $10 is used up: start a new conversation"})
        status, payload = self.proxy.handle("conv_send", GOOD, b'{"message":"x"}', CONV)
        self.assertEqual((status, payload["error"][:16]), (409, "the conversation")); self.assertNotIn(TOKEN, json.dumps(payload))
        self.up.reply = (401, {"error": "bad token"})
        self.assertEqual(self.proxy.handle("conv_list", GOOD)[0], 502)


class Errors(Base):
    def test_upstream_status_and_message_are_preserved(self):
        for code, body in ((400, {"error": "invalid request", "details": ["name: bad"]}), (404, {"error": "unknown job"}),
                           (409, {"error": "a generation job is already running", "details": ["x"]}), (500, {"error": "the publish directory is not writable"}),
                           (202, {"job_id": JOB, "status": "running"})):
            self.up.reply = (code, body)
            self.assertEqual(self.proxy.handle("status", GOOD, None, JOB), (code, body))

    def test_credential_rejection_is_a_server_error_not_a_browser_one(self):
        for code in (401, 403):
            self.up.reply = (code, {"error": "missing or invalid bearer token"})
            status, body = self.proxy.handle("status", GOOD, None, JOB)
            self.assertEqual(status, 502); self.assertIn("rejected", body["error"])

    def test_stopped_upstream(self):
        port = self.up.port; self.up.close()
        status, body = self.proxy.handle("status", GOOD, None, JOB)
        self.assertEqual((status, body["state"]), (503, "stopped")); self.assertIn("./playground ai-builder start", body["error"])
        status, body = self.proxy.handle("health", GOOD)
        self.assertEqual((status, body["available"], body["state"]), (200, False, "stopped"))
        self.assertEqual(port, self.up.port)

    def test_missing_or_short_token_file(self):
        self.tokenfile.unlink()
        status, body = self.proxy.handle("status", GOOD, None, JOB)
        self.assertEqual((status, body["state"]), (503, "not_configured")); self.assertEqual(self.up.requests, [])
        self.assertEqual(self.proxy.handle("health", GOOD)[1]["state"], "not_configured")
        self.tokenfile.write_text("tiny"); self.assertEqual(self.proxy.handle("status", GOOD, None, JOB)[0], 503)

    def test_upstream_timeout(self):
        self.up.delay = 1.0
        proxy = P.Proxy(f"http://127.0.0.1:{self.up.port}", str(self.tokenfile), scale=0.05)       # 5 s read timeout -> 0.25 s
        t = time.time(); status, body = proxy.handle("health", GOOD)
        self.assertLess(time.time() - t, 0.9)
        self.assertEqual((status, body["available"], body["state"]), (200, False, "timeout"))
        self.assertEqual(proxy.handle("status", GOOD, None, JOB)[0], 504)

    def test_bad_upstream_responses(self):
        self.up.raw = b"<html>nope</html>"; self.assertEqual(self.proxy.handle("status", GOOD, None, JOB)[0], 502)
        self.up.raw = b"[1,2]"; self.assertEqual(self.proxy.handle("status", GOOD, None, JOB)[0], 502)
        self.up.raw = b'{"x": "' + b"a" * (P.MAX_RESPONSE + 10) + b'"}'; self.assertEqual(self.proxy.handle("status", GOOD, None, JOB)[0], 502)

    def test_health_states(self):
        ok = {"status": "ok", "version": "1", "claude_available": True, "claude_credentials_present": True, "busy": False}
        cases = ((ok, "ready"), ({**ok, "claude_credentials_present": False}, "not_signed_in"), ({**ok, "claude_credentials_present": None}, "ready"),
                 ({**ok, "claude_available": False}, "claude_missing"))
        for payload, state in cases:
            self.up.reply = (200, payload); status, body = self.proxy.handle("health", GOOD)
            self.assertEqual((status, body["available"], body["state"]), (200, True, state))
        self.up.reply = (200, {"status": "ok"})          # an unauthenticated (minimal) answer must not look "ready" with details
        self.assertTrue(self.proxy.handle("health", GOOD)[1]["available"])


class RequestRules(Base):
    def test_post_needs_the_custom_header_and_a_local_host(self):
        for op in ("generate", "approve", "publish"):
            h = {k: v for k, v in GOOD.items() if k != "x-requested-with"}
            self.assertEqual(self.proxy.handle(op, h, b"{}", JOB)[0], 403, op)
            self.assertEqual(self.proxy.handle(op, {**GOOD, "x-requested-with": "XMLHttpRequest"}, b"{}", JOB)[0], 403, op)
        for host in ("evil.example", "evil.example:8080", "ai-builder:8099", "10.0.0.5"):
            self.assertEqual(self.proxy.handle("health", {**GOOD, "host": host})[0], 403, host)
        for host in ("localhost:8080", "127.0.0.1", "LOCALHOST:8080", "[::1]:8080"):
            self.assertEqual(self.proxy.handle("health", {**GOOD, "host": host})[0], 200, host)
        self.assertEqual(self.up.requests and len(self.up.requests), 4)       # only the four good-host health calls got through

    def test_extra_allowed_hosts_come_from_configuration(self):
        p = P.Proxy(f"http://127.0.0.1:{self.up.port}", str(self.tokenfile), allowed_hosts="playground.local")
        self.assertEqual(p.handle("health", {**GOOD, "host": "playground.local:8080"})[0], 200)

    def test_generate_body_rules(self):
        self.up.requests.clear()
        self.assertEqual(self.proxy.handle("generate", {**GOOD, "content-type": "text/plain"}, b"{}")[0], 415)
        self.assertEqual(self.proxy.handle("generate", GOOD, None)[0], 413)                    # the route passes None when over the limit
        self.assertEqual(self.proxy.handle("generate", GOOD, b"{not json")[0], 400)
        self.assertEqual(self.proxy.handle("generate", GOOD, b"[1]")[0], 400)
        self.assertEqual(self.proxy.handle("generate", GOOD, b"\xff\xfe")[0], 400)
        self.assertEqual(self.up.requests, [], "invalid requests must not reach the AI Builder")

    def test_only_validated_json_is_forwarded(self):
        self.proxy.handle("generate", GOOD, b'{"name":  "a",   "description": "b"}  \n  ')
        self.assertEqual(self.up.requests[0]["body"], b'{"name": "a", "description": "b"}')

    def test_approve_and_publish_forward_no_body(self):
        self.proxy.handle("approve", GOOD, b"ignored", JOB); self.proxy.handle("publish", GOOD, b"ignored", JOB)
        self.assertEqual([r["body"] for r in self.up.requests], [b"", b""])

    def test_default_configuration(self):
        p = P.Proxy()
        self.assertEqual((p.host, p.port, p.token_file), ("ai-builder", 8099, "/workspace/.ai-builder-token"))


class AuthOperations(Base):
    SECRET = "Zx9aQ-test_CODE.value~1234#state567890"

    def test_each_auth_operation_reaches_its_route_with_the_token(self):
        for op, method, path, body in (("auth_status", "GET", "/auth/status", None), ("auth_login", "POST", "/auth/login", b"{}"),
                                       ("auth_code", "POST", "/auth/code", json.dumps({"code": self.SECRET}).encode()),
                                       ("auth_cancel", "POST", "/auth/cancel", None), ("auth_logout", "POST", "/auth/logout", None)):
            self.up.requests.clear()
            self.assertEqual(self.proxy.handle(op, GOOD, body)[0], 200, op)
            r = self.up.requests[0]
            self.assertEqual((r["method"], r["path"], r["headers"]["authorization"]), (method, path, f"Bearer {TOKEN}"))

    def test_posts_need_the_csrf_header_json_and_a_local_host(self):
        no_csrf = {k: v for k, v in GOOD.items() if k != "x-requested-with"}
        for op in ("auth_login", "auth_code", "auth_cancel", "auth_logout"):
            self.assertEqual(self.proxy.handle(op, no_csrf, b"{}")[0], 403, op)
        self.assertEqual(self.proxy.handle("auth_code", {**GOOD, "content-type": "text/plain"}, b"{}")[0], 415)
        self.assertEqual(self.proxy.handle("auth_code", GOOD, None)[0], 413)
        self.assertEqual(self.proxy.handle("auth_code", GOOD, b"[]")[0], 400)
        self.assertEqual(self.proxy.handle("auth_status", {**GOOD, "host": "evil.example"})[0], 403)
        self.assertEqual(self.up.requests, [])

    def test_only_allowlisted_fields_reach_the_browser(self):
        self.up.reply = (200, {"logged_in": True, "expires_at": None, "access_token": "sk-ant-LEAK", "refresh_token": "r-LEAK", "email": "p@example.com", "raw_output": "screen text",
                               "session": {"state": "awaiting_browser", "url": "https://claude.ai/oauth/authorize?x=1", "awaiting_code": True, "seconds_left": 9, "method": "claudeai",
                                           "error": None, "pty": "raw screen", "code": "LEAK-CODE-123"}})
        status, out = self.proxy.handle("auth_status", GOOD)
        self.assertEqual(status, 200)
        self.assertEqual(sorted(out), ["expires_at", "logged_in", "session"])
        self.assertEqual(sorted(out["session"]), ["awaiting_code", "error", "method", "seconds_left", "state", "url"])
        self.assertNotIn("LEAK", json.dumps(out)); self.assertNotIn("p@example.com", json.dumps(out)); self.assertNotIn("screen", json.dumps(out))

    def test_the_submitted_code_is_never_echoed_back(self):
        self.up.reply = (400, {"error": f"bad code {self.SECRET} was refused", "session": {"state": "awaiting_browser", "error": self.SECRET}})
        status, out = self.proxy.handle("auth_code", GOOD, json.dumps({"code": self.SECRET}).encode())
        self.assertEqual(status, 400); self.assertNotIn(self.SECRET, json.dumps(out)); self.assertIn("[redacted]", out["error"])

    def test_stopped_and_credential_problems_are_reported_like_the_other_operations(self):
        self.up.reply = (401, {"error": "missing or invalid bearer token"})
        status, out = self.proxy.handle("auth_status", GOOD); self.assertEqual(status, 502); self.assertIn("rejected", out["error"])
        self.up.close()
        status, out = self.proxy.handle("auth_login", GOOD, b"{}"); self.assertEqual((status, out["state"]), (503, "stopped"))
        self.assertNotIn(TOKEN, json.dumps(out))

    def test_conflicts_pass_through(self):
        self.up.reply = (409, {"error": "a sign-in is already in progress"})
        self.assertEqual(self.proxy.handle("auth_login", GOOD, b"{}"), (409, {"error": "a sign-in is already in progress"}))


class AppWiring(unittest.TestCase):
    """web/app.py cannot be imported on the host (no FastAPI): check the thin routes statically."""

    @classmethod
    def setUpClass(cls):
        cls.src = (REPO / "web" / "app.py").read_text(); cls.tree = ast.parse(cls.src)

    def routes(self):
        out = {}
        for fn in ast.walk(self.tree):
            if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for d in fn.decorator_list:
                    if isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute) and d.func.attr in ("get", "post", "delete") and d.args \
                            and isinstance(d.args[0], ast.Constant) and d.args[0].value.startswith("/api/ai-builder/"):
                        out[(d.func.attr.upper(), d.args[0].value)] = fn
        return out

    def test_the_routes_exist_with_the_right_methods(self):
        self.assertEqual(sorted(self.routes()), sorted([("GET", "/api/ai-builder/health"), ("POST", "/api/ai-builder/generate"),
                         ("GET", "/api/ai-builder/status/{job_id}"), ("GET", "/api/ai-builder/review/{job_id}"),
                         ("POST", "/api/ai-builder/approve/{job_id}"), ("POST", "/api/ai-builder/publish/{job_id}"),
                         ("GET", "/api/ai-builder/auth/status"), ("POST", "/api/ai-builder/auth/login"), ("POST", "/api/ai-builder/auth/code"),
                         ("POST", "/api/ai-builder/auth/cancel"), ("POST", "/api/ai-builder/auth/logout"),
                         ("POST", "/api/ai-builder/conversations"), ("GET", "/api/ai-builder/conversations"),
                         ("GET", "/api/ai-builder/conversations/{conv_id}"), ("DELETE", "/api/ai-builder/conversations/{conv_id}"), ("POST", "/api/ai-builder/conversations/{conv_id}/messages"),
                         ("GET", "/api/ai-builder/conversations/{conv_id}/review"), ("POST", "/api/ai-builder/conversations/{conv_id}/undo"),
                         ("POST", "/api/ai-builder/conversations/{conv_id}/reset"), ("POST", "/api/ai-builder/conversations/{conv_id}/discard"),
                         ("POST", "/api/ai-builder/conversations/{conv_id}/publish"),
                         ("POST", "/api/ai-builder/conversations/{conv_id}/context"),
                         ("POST", "/api/ai-builder/conversations/{conv_id}/meta"),
                         ("POST", "/api/ai-builder/conversations/{conv_id}/lab"),
                         ("POST", "/api/ai-builder/conversations/{conv_id}/delete_check"), ("POST", "/api/ai-builder/conversations/{conv_id}/delete_lab")]))

    def test_each_route_delegates_to_its_own_operation_and_forwards_nothing_else(self):
        for (method, path), fn in self.routes().items():
            conv_ops = {("POST", "/api/ai-builder/conversations"): "conv_create", ("GET", "/api/ai-builder/conversations"): "conv_list",
                        ("GET", "/api/ai-builder/conversations/{conv_id}"): "conv_get", ("DELETE", "/api/ai-builder/conversations/{conv_id}"): "conv_delete", ("POST", "/api/ai-builder/conversations/{conv_id}/messages"): "conv_send",
                        **{(("GET" if a == "review" else "POST"), f"/api/ai-builder/conversations/{{conv_id}}/{a}"): f"conv_{a}" for a in ("review", "undo", "reset", "discard", "publish", "context", "meta", "lab", "delete_check", "delete_lab")}}
            op = conv_ops.get((method, path)) or (("auth_" + path.rsplit("/", 1)[-1]) if "/auth/" in path else path.rsplit("/", 2)[-2] if "{" in path else path.rsplit("/", 1)[-1])
            text = ast.get_source_segment(self.src, fn)
            self.assertIn(f'"{op}"', text, path)
            self.assertIn("_aib", text, path)
            self.assertNotIn("request.url", text); self.assertNotIn("query_params", text); self.assertNotIn("cookies", text)
        self.assertIn("async def aib_generate", self.src)            # the routes that read a body do it with the size cap
        self.assertIn("async def aib_auth_code", self.src); self.assertIn("async def aib_auth_login", self.src)
        self.assertIn("_read_limited(request, ai_builder_proxy.MAX_BODY)", self.src)

    def test_routes_are_registered_before_the_static_catch_all_mount(self):
        self.assertLess(self.src.index("/api/ai-builder/health"), self.src.index('app.mount("/"'))

    def test_no_token_or_destination_in_the_app_module(self):
        self.assertNotIn("ai-builder:8099", self.src); self.assertNotIn("Bearer", self.src); self.assertNotIn("ai-builder-token", self.src)


import lab_delete  # noqa: E402
CONV = "c-20261117-120000-abc123"


class DeleteLabProxy(Base):
    """P4.3.2: the server builds the body of a deletion call; the browser can never supply the infrastructure verdict."""

    def go(self, op, body, transform, headers=None):
        self.up.requests.clear()
        return self.proxy.handle(op, {**GOOD, **(headers or {})}, json.dumps(body).encode(), CONV, transform)

    def test_the_forwarded_body_is_built_by_the_server_and_a_forged_verdict_is_dropped(self):
        seen = []
        def transform(b):
            seen.append(b); return {"lab": b["lab"], "confirm": b.get("confirm"), "infrastructure": "running"}
        st, _ = self.go("conv_delete_lab", {"lab": "demo-lab", "confirm": "demo-lab", "infrastructure": "stopped", "extra": 1}, transform)
        self.assertEqual(st, 200); r = self.up.requests[-1]
        self.assertEqual((r["method"], r["path"]), ("POST", f"/conversations/{CONV}/delete_lab")); self.assertEqual(json.loads(r["body"]), {"lab": "demo-lab", "confirm": "demo-lab", "infrastructure": "running"})
        self.assertEqual(r["headers"]["authorization"], f"Bearer {TOKEN}"); self.assertEqual(seen[0]["infrastructure"], "stopped", "the browser's value only reaches server code, never upstream")

    def test_a_refusal_by_the_server_never_reaches_upstream_and_the_usual_gates_still_apply(self):
        self.assertEqual(self.go("conv_delete_lab", {}, lambda b: (400, {"error": "lab"}))[0], 400); self.assertEqual(self.up.requests, [])
        called = []
        for headers in ({"x-requested-with": ""}, {"host": "evil.example"}, {"content-type": "text/plain"}):
            st, _ = self.go("conv_delete_lab", {"lab": "demo-lab"}, lambda b: called.append(b) or b, headers); self.assertIn(st, (403, 415)); self.assertEqual(self.up.requests, [])
        self.assertEqual(called, [], "the transform runs only after the gates")
        self.assertEqual(self.proxy.handle("conv_delete_check", GOOD, b"[]", CONV, lambda b: b)[0], 400)
        self.assertEqual(self.proxy.handle("conv_delete_check", GOOD, b"{}", "../etc", lambda b: {"lab": "x"})[0], 400)


class Gate(unittest.TestCase):
    def mk(self, found=None, error=None, ops=None):
        lock = threading.Lock(); ops = {} if ops is None else ops
        def discover():
            if error: raise error
            return found if found is not None else [("demo-lab", 0), ("busy-lab", 2)]
        return lab_delete.DeleteGate(lock, ops, discover), ops

    def test_stopped_only_when_a_fresh_query_lists_the_lab_with_no_cluster(self):
        g, _ = self.mk(); self.assertEqual(g.infra("demo-lab"), "stopped"); self.assertEqual(g.infra("busy-lab"), "running")
        for bad in ("ghost-lab", None, "", "../x", "A", 5):
            self.assertEqual(g.infra(bad), "unknown", repr(bad))
        for err in (RuntimeError("docker"), TimeoutError(), OSError()):
            self.assertEqual(self.mk(error=err)[0].infra("demo-lab"), "unknown", "fail closed")
        for state in ("starting", "stopping"):
            self.assertEqual(self.mk(ops={"demo-lab": {"state": state}})[0].infra("demo-lab"), state)
        self.assertEqual(self.mk(ops={"demo-lab": {"state": "succeeded"}})[0].infra("demo-lab"), "stopped")

    def test_begin_marks_the_lab_blocks_a_second_deletion_and_end_releases_it(self):
        g, _ = self.mk(); self.assertEqual(g.begin("demo-lab"), (True, "stopped")); self.assertTrue(g.deleting("demo-lab")); self.assertFalse(g.deleting("busy-lab"))
        self.assertEqual(g.begin("demo-lab"), (False, "unknown")); self.assertEqual(g.infra("demo-lab"), "unknown"); g.end("demo-lab"); self.assertFalse(g.deleting("demo-lab"))
        self.assertEqual(g.begin("busy-lab"), (True, "running"), "acquired, but the verdict is running: the AI Builder refuses")
        g.end("busy-lab"); self.assertEqual(g.begin("../x"), (False, "unknown"))

    def test_a_start_registered_before_the_check_blocks_it_and_one_after_the_mark_is_refused(self):
        g, ops = self.mk(); ops["demo-lab"] = {"state": "starting"}; self.assertEqual(g.begin("demo-lab"), (False, "starting")); self.assertFalse(g.deleting("demo-lab"))
        ops.clear(); self.assertTrue(g.begin("demo-lab")[0])
        launch = lambda: (_ for _ in ()).throw(RuntimeError("409")) if g.deleting("demo-lab") else ops.setdefault("demo-lab", {"state": "starting"})   # what _launch does under the lock
        with self.assertRaises(RuntimeError): launch()
        self.assertEqual(ops, {}); g.end("demo-lab"); launch(); self.assertEqual(ops["demo-lab"]["state"], "starting")

    def test_concurrent_start_and_deletion_never_both_win(self):
        for _ in range(200):
            g, ops = self.mk(); results = {}
            def starter():
                with g.lock:
                    if g.deleting("demo-lab"): results["start"] = False
                    else: ops["demo-lab"] = {"state": "starting"}; results["start"] = True
            t = threading.Thread(target=starter); t2 = threading.Thread(target=lambda: results.setdefault("del", g.begin("demo-lab")))
            t.start(); t2.start(); t.join(); t2.join()
            self.assertFalse(results["start"] and results["del"][0], "a deletion and a start can never both proceed")

    def test_app_wiring_uses_the_gate_for_starts_and_for_both_deletion_routes(self):
        src = (REPO / "web" / "app.py").read_text(); launch = src[src.index("def _launch"):src.index('@app.post("/api/usecases/{name}/start")')]
        self.assertIn("_gate.deleting(name)", launch); self.assertLess(launch.index("_gate.deleting(name)"), launch.index("subprocess.Popen"))
        route = src[src.index("async def aib_delete_lab"):src.index('@app.post("/api/ai-builder/conversations/{conv_id}/undo")')]
        for needle in ("_gate.begin(lab)", "_gate.end(lab)", "finally:", '"infrastructure": state', "conv_delete_lab"):
            self.assertIn(needle, route)
        self.assertNotIn('b.get("infrastructure")', src); self.assertIn("_gate.infra(lab)", src)


if __name__ == "__main__":
    unittest.main(verbosity=1)
