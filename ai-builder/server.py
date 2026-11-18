"""Local AI Builder service: a tiny HTTP API on 127.0.0.1 (standard library only).

  GET  /health            liveness (open); version, Claude availability and login presence with the token

Every other route needs "Authorization: Bearer <token>" when AI_BUILDER_TOKEN_FILE is set (always the case in the container).
  POST /generate          {"name", "description", "reference_usecase"?} -> 202 {"job_id", "status"}
  GET  /status/<job_id>   progress, generated files, validation
  GET  /auth/status       Claude sign-in state (booleans only) and the current sign-in session
  POST /auth/login        {"method"?: claudeai|sso|console, "email"?} start a browser sign-in (one at a time)
  POST /auth/code         {"code"} the authorization code shown by the sign-in page (never stored or logged)
  POST /auth/cancel, /auth/logout
  GET  /review/<job_id>   validation plus the content of every draft file
  POST /approve/<job_id>  human approval of a validated draft (bound to its content hash)
  POST /publish/<job_id>  move the approved, unchanged draft to usecases/<name> (never overwrites; runs nothing)
  POST /conversations                 {"title"?, "lab"?} -> 201 a new read-only conversation (optionally about an existing Lab)
  GET  /conversations                 {"conversations": [summaries, newest first]}
  GET  /conversations/<id>            the conversation: messages, usage per turn and total, budget, context
  POST /conversations/<id>/messages   {"message"} -> 202 one turn is answering (poll GET /conversations/<id>)
  DELETE /conversations/<id>          delete it with its Claude session files and its own working copy (409 while it answers)
  GET  /conversations/<id>/review    pending changes of a Lab conversation: files, diffs, validation, conflict, hash to approve
  POST /conversations/<id>/undo|reset|discard   undo the last change / back to the original Lab / drop the working copy
  POST /conversations/<id>/publish    {"approve": true, "tree_hash"} publish the reviewed working copy (never automatic)

Only these predefined operations exist: nothing from a request becomes a command-line argument or a path.
"""
import hmac
import json
import re
import shutil
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import auth
import builder
import conversations

MAX_BODY = 16 * 1024
HOST_RE = re.compile(r"^([a-z0-9.-]+)(:[0-9]{1,5})?$")


MAX_MESSAGE_BODY = 32 * 1024     # 4000 characters, even all escaped as \\uXXXX, fit


def make_handler(manager, cfg, version="unknown", authm=None, convs=None):
    state = {}
    convs = convs or conversations.ConversationManager(cfg, other_busy=lambda: bool(state["auth"].active()), jobs_busy=manager.busy)
    authm = authm or auth.AuthManager(cfg, generation_busy=lambda: manager.busy() or convs.busy())
    state["auth"] = authm

    class Handler(BaseHTTPRequestHandler):
        server_version = "ai-builder"
        sys_version = ""

        def log_message(self, fmt, *args):
            if cfg.quiet:
                return
            sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

        def _send(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _host_ok(self):
            # Refuses DNS-rebinding style requests: only the configured names are served.
            m = HOST_RE.match(self.headers.get("Host", "").lower())
            if m and m.group(1) in cfg.allowed_hosts:
                return True
            self._send(403, {"error": "forbidden host"})
            return False

        def _small_json(self, limit=4096, required=True):
            """(payload, None) or (None, (status, message)). The body is parsed and dropped: it is never logged."""
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return None, (400, "invalid Content-Length")
            if length == 0 and not required:
                return {}, None
            if length <= 0 or length > limit:
                return None, (413 if length > limit else 400, f"body must be 1-{limit} bytes")
            if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
                return None, (415, "Content-Type must be application/json")
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return None, (400, "invalid JSON")
            return (payload, None) if isinstance(payload, dict) else (None, (400, "the body must be a JSON object"))

        def _auth_call(self, fn, *args):
            try:
                return self._send(200, fn(*args))
            except auth.AuthError as exc:
                return self._send(exc.status, {"error": str(exc)})

        def _conv_call(self, fn, *args):
            try:
                return self._send(200, fn(*args))
            except builder.RequestError as exc:
                return self._send(exc.status, {"error": str(exc), "details": exc.errors})

        def _token_ok(self):
            """True without a configured token (loopback host mode); otherwise a constant-time Bearer comparison."""
            if cfg.token is None:
                return True
            supplied = self.headers.get("Authorization", "")
            return supplied.startswith("Bearer ") and hmac.compare_digest(supplied[len("Bearer "):].strip().encode(), cfg.token.encode())

        def _authorized(self):
            if self._token_ok():
                return True
            self._send(401, {"error": "missing or invalid bearer token"})
            return False

        def do_GET(self):
            if not self._host_ok():
                return
            if self.path == "/health":     # liveness is open; details need the token. No credential is ever returned.
                body = {"status": "ok"}
                if self._token_ok():
                    body.update(version=version, claude_available=shutil.which(cfg.claude) is not None, busy=manager.busy(),
                                claude_credentials_present=cfg.credentials_present())
                return self._send(200, body)
            if not self._authorized():
                return
            m = re.fullmatch(r"/status/([^/?#]+)", self.path)
            if m:
                job = manager.get(m.group(1))
                return self._send(200, builder.public_view(job, detail=True)) if job else self._send(404, {"error": "unknown job"})
            if self.path == "/auth/status":
                return self._auth_call(authm.status)
            if self.path == "/conversations":
                return self._send(200, {"conversations": convs.list()})
            m = re.fullmatch(r"/conversations/([^/?#]+)/review", self.path)
            if m:
                return self._conv_call(convs.review, m.group(1))
            m = re.fullmatch(r"/conversations/([^/?#]+)", self.path)
            if m:
                view = convs.get(m.group(1))
                return self._send(200, view) if view else self._send(404, {"error": "unknown conversation"})
            m = re.fullmatch(r"/review/([^/?#]+)", self.path)
            if m:
                view = manager.review(m.group(1))
                return self._send(200, view) if view else self._send(404, {"error": "unknown job"})
            self._send(404, {"error": "not found"})

        def do_DELETE(self):
            if not self._host_ok() or not self._authorized():
                return
            m = re.fullmatch(r"/conversations/([^/?#]+)", self.path)
            if not m:
                return self._send(404, {"error": "not found"})
            return self._conv_call(convs.delete, m.group(1))

        def do_POST(self):
            if not self._host_ok() or not self._authorized():
                return
            if self.path.startswith("/auth/"):
                route = self.path[len("/auth/"):]
                if route == "login":
                    body, err = self._small_json(required=False)
                    if err:
                        return self._send(err[0], {"error": err[1]})
                    return self._auth_call(authm.start, body.get("method", "claudeai"), body.get("email"))
                if route == "code":
                    body, err = self._small_json()
                    if err:
                        return self._send(err[0], {"error": err[1]})
                    return self._auth_call(authm.submit_code, body.get("code"))
                if route == "cancel":
                    return self._auth_call(authm.cancel)
                if route == "logout":
                    return self._auth_call(authm.logout)
                return self._send(404, {"error": "not found"})
            m = re.fullmatch(r"/conversations/([^/?#]+)/(undo|reset|discard|publish)", self.path)
            if m:
                cid, action = m.groups()
                if action == "publish":
                    body, err = self._small_json(limit=1024)
                    if err:
                        return self._send(err[0], {"error": err[1]})
                    return self._conv_call(convs.publish, cid, body.get("approve"), body.get("tree_hash"))
                return self._conv_call(getattr(convs, action), cid)
            m = re.fullmatch(r"/conversations/([^/?#]+)/meta", self.path)
            if m:
                body, err = self._small_json(limit=1024)
                if err:
                    return self._send(err[0], {"error": err[1]})
                return self._conv_call(convs.update, m.group(1), body.get("title"), body.get("archived"))
            m = re.fullmatch(r"/conversations/([^/?#]+)/context", self.path)
            if m:
                body, err = self._small_json(limit=1024)
                if err:
                    return self._send(err[0], {"error": err[1]})
                return self._conv_call(convs.set_context, m.group(1), body.get("action"), body.get("lab"), body.get("labs"))
            m = re.fullmatch(r"/conversations/([^/?#]+)/(delete_check|delete_lab)", self.path)    # whole-Lab deletion (P4.3.2): the Playground's server supplies `infrastructure`
            if m:
                body, err = self._small_json(limit=1024)
                if err:
                    return self._send(err[0], {"error": err[1]})
                if m.group(2) == "delete_check":
                    return self._conv_call(convs.delete_check, m.group(1), body.get("lab"), body.get("infrastructure"))
                return self._conv_call(convs.delete_lab, m.group(1), body.get("lab"), body.get("confirm"), body.get("infrastructure"))
            m = re.fullmatch(r"/conversations/([^/?#]+)/lab", self.path)           # one Lab's working copy: review, undo, reset, discard, publish
            if m:
                body, err = self._small_json(limit=1024)
                if err:
                    return self._send(err[0], {"error": err[1]})
                return self._conv_call(convs.lab_op, m.group(1), body.get("lab"), body.get("action"), body.get("approve"), body.get("tree_hash"))
            if self.path == "/conversations" or re.fullmatch(r"/conversations/[^/?#]+/messages", self.path):
                body, err = self._small_json(limit=MAX_MESSAGE_BODY, required=self.path != "/conversations")
                if err:
                    return self._send(err[0], {"error": err[1]})
                try:
                    if self.path == "/conversations":
                        return self._send(201, convs.create(body.get("title"), body.get("lab")))
                    return self._send(202, convs.send(self.path.split("/")[2], body.get("message")))
                except builder.RequestError as exc:
                    return self._send(exc.status, {"error": str(exc), "details": exc.errors})
            if self.path.startswith(("/approve/", "/publish/")):
                action, _, job_id = self.path[1:].partition("/")
                try:
                    result = manager.approve(job_id) if action == "approve" else manager.publish(job_id)
                except builder.RequestError as exc:
                    return self._send(exc.status, {"error": str(exc), "details": exc.errors})
                return self._send(200, builder.public_view(result) if action == "approve" else result)
            if self.path != "/generate":
                return self._send(404, {"error": "not found"})
            if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
                return self._send(415, {"error": "Content-Type must be application/json"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self._send(400, {"error": "invalid Content-Length"})
            if length <= 0 or length > MAX_BODY:
                return self._send(413 if length > MAX_BODY else 400, {"error": f"body must be 1-{MAX_BODY} bytes"})
            if authm.active():
                return self._send(409, {"error": "a Claude sign-in is in progress: wait for it to finish"})
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                req = builder.validate_request(payload, cfg)
                if shutil.which(cfg.claude) is None:
                    raise builder.RequestError([f"Claude Code CLI not found ('{cfg.claude}')"], 503)
                job = manager.submit(req)
            except (ValueError, UnicodeDecodeError) as exc:
                if isinstance(exc, builder.RequestError):
                    return self._send(exc.status, {"error": "invalid request" if exc.status == 400 else str(exc), "details": exc.errors})
                return self._send(400, {"error": "invalid JSON"})
            self._send(202, {"job_id": job["job_id"], "status": "running"})

    return Handler


def main():
    cfg = builder.Config()
    version = (builder.ROOT / "VERSION").read_text().strip() if (builder.ROOT / "VERSION").exists() else "unknown"
    if cfg.host != "127.0.0.1" and cfg.token is None:      # fail closed: no token, no network listener
        sys.exit("AI Builder refuses to listen on a non-loopback address without AI_BUILDER_TOKEN_FILE")
    manager = builder.JobManager(cfg)
    httpd = ThreadingHTTPServer((cfg.host, cfg.port), make_handler(manager, cfg, version))      # conversations live in <state>/conversations/
    print(f"AI Builder listening on http://{cfg.host}:{cfg.port} (repository {cfg.root})", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
