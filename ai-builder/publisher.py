"""ai-publisher: the only process allowed to write published Labs (SPEC-023). Standard library only. No Claude Code here.

It runs in its own container (compose service `ai-publisher`): <state> is mounted READ-ONLY, usecases/ is the one writable
mount, no port is published on the host, and it needs no login. The AI Builder (where Claude Code runs, with usecases/
read-only) asks it to publish; it does not trust the request:

  POST /publish {"name", "source": "drafts/<..>" | "workspaces/<..>" (relative to the state directory), "expected_hash",
                 "base_hash"?, "replace"?}
    * the source must be a real directory under <state>/drafts or <state>/workspaces (no symlinks, no '..');
    * its content hash must equal expected_hash (what the user approved), it is validated again, and a replacement is
      refused when the published Lab no longer hashes to base_hash (somebody changed it since the working copy was made);
    * the swap is atomic where the filesystem allows it (publishing.publish_tree).
  POST /delete {"name", "expected_hash"}  (a whole Lab, SPEC-026): usecases/<name> is renamed into usecases/.trash/ if it is a real
    directory whose content hash is expected_hash; nothing is removed.
  GET /health  liveness.

Requests need the same bearer token as the AI Builder (secret file), and a known Host header.
"""
import hmac
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import builder
import publishing

MAX_BODY = 4096
HOST_RE = re.compile(r"^([a-z0-9.-]+)(:[0-9]{1,5})?$")
ALLOWED_PARENTS = ("drafts", "workspaces")


def resolve_source(state, rel):
    """<state>/<rel> when it is a directory below drafts/ or workspaces/, never through a symlink; otherwise PublishError."""
    if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in Path(rel).parts or "\0" in rel:
        raise publishing.PublishError(["invalid source"], 400)
    parts = Path(rel).parts
    if parts[0] not in ALLOWED_PARENTS or len(parts) < 2:
        raise publishing.PublishError(["the source must be a draft or a working copy"], 400)
    path = Path(state)
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise publishing.PublishError(["invalid source"], 400)
    try:
        path.resolve().relative_to(Path(state).resolve())
    except ValueError:
        raise publishing.PublishError(["invalid source"], 400)
    return path


def make_handler(cfg):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ai-publisher"
        sys_version = ""

        def log_message(self, fmt, *args):
            if not cfg.quiet:
                sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

        def _send(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _gate(self, need_token=True):
            m = HOST_RE.match(self.headers.get("Host", "").lower())
            if not (m and m.group(1) in cfg.allowed_hosts):
                self._send(403, {"error": "forbidden host"})
                return False
            if need_token:
                supplied = self.headers.get("Authorization", "")
                ok = cfg.token is not None and supplied.startswith("Bearer ") and \
                    hmac.compare_digest(supplied[len("Bearer "):].strip().encode(), cfg.token.encode())
                if not ok:
                    self._send(401, {"error": "missing or invalid bearer token"})
                    return False
            return True

        def do_GET(self):
            if self.path == "/health" and self._gate(need_token=False):
                return self._send(200, {"status": "ok", "writable": os.access(cfg.publish_dir, os.W_OK)})
            if self.path != "/health":
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path not in ("/publish", "/delete"):
                return self._send(404, {"error": "not found"})
            if not self._gate():
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > MAX_BODY:
                    return self._send(413 if length > MAX_BODY else 400, {"error": f"body must be 1-{MAX_BODY} bytes"})
                if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
                    return self._send(415, {"error": "Content-Type must be application/json"})
                body = json.loads(self.rfile.read(length).decode("utf-8"))
                if not isinstance(body, dict):
                    raise ValueError("object expected")
            except (ValueError, UnicodeDecodeError):
                return self._send(400, {"error": "invalid JSON"})
            if self.path == "/delete":
                try:
                    return self._send(200, publishing.trash_tree(cfg.publish_dir, body.get("name"), body.get("expected_hash")))
                except publishing.PublishError as exc:
                    return self._send(exc.status, {"error": str(exc), "details": exc.errors})
            try:
                source = resolve_source(cfg.state, body.get("source"))
                result = publishing.publish_tree(cfg.publish_dir, body.get("name"), source, body.get("expected_hash"),
                                                 body.get("base_hash"), body.get("replace") is True)
            except publishing.PublishError as exc:
                return self._send(exc.status, {"error": str(exc), "details": exc.errors})
            self._send(200, result)

    return Handler


def main():
    cfg = builder.Config()
    if cfg.token is None:
        sys.exit("ai-publisher refuses to start without AI_BUILDER_TOKEN_FILE")
    port = int(os.environ.get("AI_PUBLISHER_PORT", "8098"))
    httpd = ThreadingHTTPServer((cfg.host, port), make_handler(cfg))
    print(f"ai-publisher listening on {cfg.host}:{port} (publish directory {cfg.publish_dir})", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
