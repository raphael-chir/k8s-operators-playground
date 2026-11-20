"""Server-side proxy from the Playground API (/api/ai-builder/*) to the AI Builder container.

Standard library only. The browser never sees the AI Builder's address or its bearer token: the token is read from a
file on the server for every request and only ever sent to the one configured upstream.

Safety properties (each one is covered by tests/ai_builder_proxy_test.py):
  * the destination is fixed (AI_BUILDER_URL, default DEFAULT_UPSTREAM); the request chooses only an operation
    name and a job id, and the path is built from a template after the id is validated: no arbitrary proxying;
  * no header, query string or cookie of the browser request is forwarded; a fresh Authorization header is added;
  * request body: at most MAX_BODY bytes, a JSON object, re-serialized (only validated JSON is forwarded);
  * response: at most MAX_RESPONSE bytes, JSON only; the token is never part of any message returned to the browser;
  * state-changing calls need the header X-Requested-With: playground (a custom header cannot be sent cross-site
    without a CORS preflight, which this API never grants) and the Host must be a local name.
"""
import http.client
import json
import os
import re
import socket
from urllib.parse import urlsplit

MAX_BODY = 16 * 1024            # same limit as the AI Builder
MAX_RESPONSE = 1024 * 1024      # a review of a use case is a few hundred KB at most
JOB_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$")
CONV_ID_RE = re.compile(r"^c-[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$")
CSRF_HEADER, CSRF_VALUE = "x-requested-with", "playground"
START_HINT = "./playground ai-builder start"

# operation -> (HTTP method, path template, read timeout in seconds, takes a job id, takes a JSON body)
OPERATIONS = {
    "health":   ("GET",  "/health",           5,  False, False),
    "generate": ("POST", "/generate",         30, False, True),
    "status":   ("GET",  "/status/{job}",     10, True,  False),
    "review":   ("GET",  "/review/{job}",     15, True,  False),
    "approve":  ("POST", "/approve/{job}",    30, True,  False),
    "publish":  ("POST", "/publish/{job}",    60, True,  False),
    # Claude sign-in: narrow routes, not a terminal. The code is forwarded once and never logged here.
    "auth_status": ("GET",  "/auth/status", 25, False, False),
    "auth_login":  ("POST", "/auth/login",  20, False, True),
    "auth_code":   ("POST", "/auth/code",   20, False, True),
    "auth_cancel": ("POST", "/auth/cancel", 15, False, False),
    "auth_logout": ("POST", "/auth/logout", 55, False, False),
    # AI Lab Assistant conversations: the id is a conversation id (validated), the message text is a JSON field.
    "conv_create": ("POST", "/conversations",                 20, False, True),
    "conv_list":   ("GET",  "/conversations",                 10, False, False),
    "conv_get":    ("GET",  "/conversations/{conv}",          15, True,  False),
    "conv_send":   ("POST", "/conversations/{conv}/messages", 30, True,  True),
    "conv_delete": ("DELETE", "/conversations/{conv}",        30, True,  False),
    # Conversational Lab editing: the working copy of a Lab conversation. Publication is an explicit POST with the reviewed hash.
    "conv_review":  ("GET",  "/conversations/{conv}/review",  40, True,  False),
    "conv_undo":    ("POST", "/conversations/{conv}/undo",    30, True,  False),
    "conv_reset":   ("POST", "/conversations/{conv}/reset",   30, True,  False),
    "conv_discard": ("POST", "/conversations/{conv}/discard", 30, True,  False),
    "conv_publish": ("POST", "/conversations/{conv}/publish", 90, True,  True),
    # Lab context of a conversation (P3.1b): focus / activate / deactivate / detach a Lab, allow / stop edits.
    "conv_meta":    ("POST", "/conversations/{conv}/meta",    20, True,  True),     # rename / archive
    "conv_lab":     ("POST", "/conversations/{conv}/lab",     90, True,  True),     # review / undo / reset / discard / publish of ONE Lab's copy
    "conv_context": ("POST", "/conversations/{conv}/context", 30, True,  True),
    # Deleting a whole Lab (P4.3.2): the server builds the body itself (it adds the verified infrastructure state), see `transform`.
    "conv_delete_check": ("POST", "/conversations/{conv}/delete_check", 30, True, True),
    "conv_delete_lab":   ("POST", "/conversations/{conv}/delete_lab",   90, True, True),
}
RESPONSE_LIMITS = {"conv_lab": 2 * 1024 * 1024, "conv_get": 2 * 1024 * 1024,      # a full conversation (100 messages) can exceed the default limit
                   "conv_review": 2 * 1024 * 1024}   # the bounded diffs of a working copy
AUTH_OPERATIONS = {"auth_status", "auth_login", "auth_code", "auth_cancel", "auth_logout"}
# Allowlist of what an auth answer may carry to the browser: booleans, states, the official sign-in address, fixed messages.
AUTH_TOP = {"logged_in", "expires_at", "enabled", "error", "session"}
AUTH_SESSION = {"state", "method", "url", "error", "awaiting_code", "seconds_left"}

CONNECT_TIMEOUT = 3
DEFAULT_UPSTREAM = "http://ai-builder:8099"     # the compose service name and port


class Proxy:
    def __init__(self, upstream=None, token_file=None, allowed_hosts=None, scale=1.0):
        upstream = upstream or os.environ.get("AI_BUILDER_URL", DEFAULT_UPSTREAM)
        u = urlsplit(upstream)
        if u.scheme != "http" or not u.hostname or u.path not in ("", "/") or u.username or u.query:
            raise ValueError("AI_BUILDER_URL must look like http://host:port")
        self.host, self.port = u.hostname, u.port or 80
        # In the container the repository (and so the token file the CLI creates) is bind-mounted at /workspace.
        self.token_file = token_file or os.environ.get("AI_BUILDER_TOKEN_FILE", "/workspace/.ai-builder-token")
        hosts = allowed_hosts if allowed_hosts is not None else os.environ.get("AI_BUILDER_PROXY_ALLOWED_HOSTS", "")
        self.allowed_hosts = {h.strip().lower() for h in (hosts.split(",") if isinstance(hosts, str) else hosts) if h.strip()} | {"localhost", "127.0.0.1", "[::1]"}
        self.scale = scale      # tests shorten the timeouts

    # --- the token never leaves this object ------------------------------------------------------------------------
    def _token(self):
        try:
            with open(self.token_file, encoding="utf-8") as fh:
                token = fh.read().strip()
        except OSError:
            return None
        return token if len(token) >= 32 else None

    def path_for(self, operation, job_id=None):
        _, template, _, needs_job, _ = OPERATIONS[operation]
        if needs_job:
            pattern = CONV_ID_RE if "{conv}" in template else JOB_ID_RE
            if not isinstance(job_id, str) or not pattern.match(job_id):
                raise ValueError("invalid job id")
            return template.format(job=job_id, conv=job_id)
        return template

    # --- one upstream call -------------------------------------------------------------------------------------------
    def call(self, operation, job_id=None, body=None):
        """Return (http_status, payload). Never raises: every failure is a JSON error with a useful message."""
        method, _, read_timeout, _, has_body = OPERATIONS[operation]
        try:
            path = self.path_for(operation, job_id)
        except ValueError:
            return 400, {"error": "invalid job id"}
        token = self._token()
        if token is None:
            return 503, {"error": f"The AI Builder is not set up on this machine. Start it with: {START_HINT}", "state": "not_configured"}
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        data = None
        if has_body:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")      # no \\uXXXX expansion: a message keeps its size
            headers["Content-Type"] = "application/json"
        conn = http.client.HTTPConnection(self.host, self.port, timeout=CONNECT_TIMEOUT * self.scale)
        try:
            conn.connect()
            conn.sock.settimeout(read_timeout * self.scale)
            conn.request(method, path, body=data, headers=headers)
            resp = conn.getresponse()
            raw = resp.read(RESPONSE_LIMITS.get(operation, MAX_RESPONSE) + 1)
            status = resp.status
        except socket.timeout:
            return 504, {"error": "The AI Builder did not answer in time.", "state": "timeout"}
        except http.client.HTTPException:
            return 502, {"error": "The AI Builder returned a malformed HTTP response.", "state": "error"}
        except (ConnectionError, socket.gaierror, OSError):
            return 503, {"error": f"The AI Builder is not running or not reachable. Start it with: {START_HINT}", "state": "stopped"}
        finally:
            conn.close()
        if len(raw) > RESPONSE_LIMITS.get(operation, MAX_RESPONSE):
            return 502, {"error": "The AI Builder response is too large.", "state": "error"}
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {}
        except (ValueError, UnicodeDecodeError):
            return 502, {"error": "The AI Builder returned an invalid response.", "state": "error"}
        if not isinstance(payload, dict):
            return 502, {"error": "The AI Builder returned an unexpected response.", "state": "error"}
        if status in (401, 403):     # the browser has no credential to fix: this is a server-side configuration problem
            return 502, {"error": "The AI Builder rejected the server's credentials. Recreate it: "
                                  "./playground ai-builder stop && rm .ai-builder-token && ./playground ai-builder start", "state": "error"}
        return status, payload       # success and upstream errors alike: same status, same "error"/"details"

    # --- the API-level behavior (one function per HTTP route; app.py only converts Request <-> these values) -------------------
    def handle(self, operation, headers, body=None, job_id=None, transform=None):
        """headers: a case-insensitive mapping with lowercase keys (Starlette's Headers). Returns (status, payload).
        `transform(body)` (server code only) replaces the browser's validated JSON object by the body to forward, or returns (status, payload) to refuse."""
        host = (headers.get("host") or "").lower()
        host = host[: host.rfind(":")] if re.search(r":[0-9]+$", host) else host
        if host not in self.allowed_hosts:
            return 403, {"error": "forbidden host"}
        method, _, _, _, has_body = OPERATIONS[operation]
        if method != "GET" and headers.get(CSRF_HEADER, "").lower() != CSRF_VALUE:
            return 403, {"error": f"missing header X-Requested-With: {CSRF_VALUE}"}
        if has_body:
            if headers.get("content-type", "").split(";")[0].strip().lower() != "application/json":
                return 415, {"error": "Content-Type must be application/json"}
            if body is None:
                return 413, {"error": f"the request body is limited to {MAX_BODY} bytes"}
            try:
                body = json.loads(body.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return 400, {"error": "invalid JSON"}
            if not isinstance(body, dict):
                return 400, {"error": "the body must be a JSON object"}
        if transform is not None:
            body = transform(body)
            if isinstance(body, tuple):
                return body
        secret = body.get("code") if operation == "auth_code" and isinstance(body, dict) else None
        status, payload = self.call(operation, job_id, body)
        body = None                                                  # the pasted code is not kept any longer than needed
        if operation in AUTH_OPERATIONS:
            payload = self._auth_filter(payload)
            if isinstance(secret, str) and len(secret) >= 8 and secret in json.dumps(payload):      # never echo it back, whatever upstream says
                payload = json.loads(json.dumps(payload).replace(secret, "[redacted]"))
        if operation == "health":
            return 200, self._health(status, payload)
        return status, payload

    @staticmethod
    def _auth_filter(payload):
        """Defense in depth: whatever the AI Builder sends, only the allowlisted fields reach the browser."""
        out = {k: v for k, v in payload.items() if k in AUTH_TOP and k != "session"}
        out.update({k: payload[k] for k in ("state",) if k in payload})                 # proxy-made errors carry a state
        sess = payload.get("session")
        if isinstance(sess, dict):
            out["session"] = {k: v for k, v in sess.items() if k in AUTH_SESSION}
        elif "session" in payload:
            out["session"] = None
        return out

    @staticmethod
    def _health(status, payload):
        """Health is always answerable: 'available' tells the UI what to show (200 even when the AI Builder is stopped)."""
        if status == 200 and payload.get("status") == "ok":
            state = "ready" if payload.get("claude_credentials_present") is not False and payload.get("claude_available", True) else "not_signed_in"
            if payload.get("claude_available") is False:
                state = "claude_missing"
            keep = ("status", "version", "claude_available", "claude_credentials_present", "busy")
            return {"available": True, "state": state, **{k: payload[k] for k in keep if k in payload}}
        return {"available": False, "state": payload.get("state", "error"), "error": payload.get("error", "unavailable"),
                "hint": START_HINT}
