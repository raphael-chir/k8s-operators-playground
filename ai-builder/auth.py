"""Claude Code sign-in from the browser, for the AI Builder container.

What the installed CLI offers (Claude Code 2.1.x): `claude auth login [--claudeai|--console|--sso] [--email E]` is an
interactive terminal screen. It shows an official sign-in address and the prompt "Paste code here if prompted >";
after the user signs in with their browser, the web page shows a code that is pasted back; then the screen says
"Login successful". `claude auth status --json` and `claude auth logout` are non-interactive. There is no device flow and
no way to pass the code as an argument, so this module drives that one screen through a PTY. It is NOT a terminal for
the browser and NOT an OAuth client: it starts exactly the fixed command above, reads the sign-in address from its
output and writes the one code the user pastes.

Secrets: the raw terminal output is never stored, returned or logged (it may echo the code or the account e-mail);
only a rolling in-memory window is scanned and it is cleared after a code is sent. The authorization code is written to
the PTY and forgotten: it is never kept on the session, in a job file, in an exception or in a response. Credentials
themselves stay in the Claude config directory (the `claude-auth` volume) and are never read here.
"""
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import termios
import threading
import time
from urllib.parse import urlsplit

METHODS = {"claudeai": ["--claudeai"], "console": ["--console"], "sso": ["--sso"]}
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$")
CODE_RE = re.compile(r"^[A-Za-z0-9_\-#.~%+=/]{8,2048}$")           # what an authorization code looks like; no spaces, no URL
URL_RE = re.compile(r"https://[^\s\x00-\x1f\"'<>]+")
ANSI_RE = re.compile(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78]|\r")
LOGIN_HOSTS = ("claude.ai", "claude.com", "anthropic.com")      # the official sign-in pages (and their sub-domains)
WINDOW_START = 16 * 1024        # while looking for the sign-in address
WINDOW_LATER = 96               # afterwards only phrases are looked for (they are shorter than this); never the screen
STATES_ACTIVE = ("starting", "awaiting_browser", "verifying")
# Fixed messages: raw CLI output is never copied into an error.
HOST_MODE_MESSAGE = ("Browser sign-in is only available in the AI Builder container (host mode uses your own Claude login on this machine: "
                     "run `claude auth login` yourself).")
MESSAGES = {
    "no_url": "Claude Code did not show a sign-in address in time. Try again.",
    "timeout": "The sign-in was not completed in time. Start again.",
    "invalid_code": "Claude did not accept the code. Codes are single-use: start the sign-in again to get a new one.",
    "not_confirmed": "The sign-in ended but Claude does not report a login. Start again.",
    "exited": "Claude Code stopped before the sign-in finished. Start again.",
    "start_failed": "Claude Code could not be started.",
}


def strip_ansi(text):
    return ANSI_RE.sub("", text)


def allowed_login_url(url):
    """Only an https address of an official Claude/Anthropic host may be shown to the user as the sign-in link."""
    try:
        u = urlsplit(url)
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    return u.scheme == "https" and not u.username and len(url) <= 4096 and any(host == h or host.endswith("." + h) for h in LOGIN_HOSTS)


def extract_login_url(text):
    """The first official sign-in address in terminal output (ANSI removed, trailing punctuation trimmed), or None."""
    for m in URL_RE.finditer(strip_ansi(text)):
        url = m.group(0).rstrip(".,;:)]}")
        if allowed_login_url(url):
            return url
    return None


class AuthError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


class AuthManager:
    """One sign-in session at most. Independent of generation jobs (its own lock, state and process)."""

    def __init__(self, cfg, generation_busy=lambda: False, spawn=None, clock=time.monotonic):
        self.cfg, self.generation_busy, self.clock = cfg, generation_busy, clock
        # CLAUDE_CONFIG_DIR is set only in the container image. In host mode `claude auth ...` would act on the developer's own
        # login (and a logout would sign them out of their terminal): refused unless AI_BUILDER_ALLOW_HOST_AUTH=1 says otherwise.
        self.enabled = bool(cfg.config_dir) or os.environ.get("AI_BUILDER_ALLOW_HOST_AUTH") == "1"
        self.lock = threading.Lock()
        self.session = None                  # dict, see _new_session
        self._proc, self._fd = None, None
        self._cache = (0.0, None)
        self._spawn = spawn or self._spawn_pty

    # --- the non-interactive CLI calls -------------------------------------------------------------------------------------
    def _run(self, args, timeout):
        return subprocess.run([self.cfg.claude, *args], capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, errors="replace")

    def cli_status(self, force=False):
        """{'logged_in': bool|None, 'expires_at': str|None}. Only booleans and an expiry date leave this function."""
        at, cached = self._cache
        if not force and cached is not None and self.clock() - at < 4:
            return cached
        try:
            r = self._run(["auth", "status", "--json"], 20)
            try:
                data = json.loads(r.stdout) if r.stdout.strip() else {}
            except ValueError:
                data = {}
            logged = data.get("loggedIn") if isinstance(data, dict) else None
            exp = data.get("loginExpiresAt") if isinstance(data, dict) else None
            if not isinstance(logged, bool) and r.returncode != 0 and "not logged in" in (r.stdout + r.stderr).lower():
                logged = False                                     # a plain-text answer; any other failure stays "unknown", never "expired"
            result = {"logged_in": logged if isinstance(logged, bool) else None,
                      "expires_at": exp if isinstance(exp, (str, int)) and not isinstance(exp, bool) else None}
        except FileNotFoundError:
            result = {"logged_in": None, "expires_at": None, "error": "claude_missing"}
        except (subprocess.TimeoutExpired, ValueError, OSError):
            result = {"logged_in": None, "expires_at": None, "error": "status_unavailable"}
        self._cache = (self.clock(), result)
        return result

    # --- public API ------------------------------------------------------------------------------------------------------------
    def active(self):
        with self.lock:
            return bool(self.session and self.session["state"] in STATES_ACTIVE)

    def status(self):
        if not self.enabled:
            return {"logged_in": None, "expires_at": None, "enabled": False, "session": None}
        st = self.cli_status()
        with self.lock:
            return {**st, "enabled": True, "session": self._public_session()}

    def _need_enabled(self):
        if not self.enabled:
            raise AuthError(HOST_MODE_MESSAGE, 403)

    def start(self, method="claudeai", email=None):
        self._need_enabled()
        if method not in METHODS:
            raise AuthError("method must be claudeai, sso or console")
        if email is not None and (not isinstance(email, str) or not EMAIL_RE.match(email)):
            raise AuthError("invalid e-mail address")
        if self.generation_busy():
            raise AuthError("a generation job is running: sign in after it ends", 409)
        with self.lock:
            if self.session and self.session["state"] in STATES_ACTIVE:
                raise AuthError("a sign-in is already in progress", 409)
            args = [self.cfg.claude, "auth", "login", *METHODS[method], *(["--email", email] if email else [])]
            self.session = self._new_session(method)
            session = self.session
            try:
                proc, fd = self._spawn(args)
            except (OSError, ValueError):
                session.update(state="failed", error=MESSAGES["start_failed"], ended=self.clock())
                return self._snapshot()
            self._proc, self._fd = proc, fd
        threading.Thread(target=self._pump, args=(session, proc, fd), daemon=True).start()
        return self._snapshot()

    def public(self):
        with self.lock:
            return self._public_session()

    def _snapshot(self):
        """The status() shape, from the cached CLI status: no process is spawned (used by the quick POST answers)."""
        cached = self._cache[1] or {"logged_in": None, "expires_at": None}
        return {**cached, "enabled": self.enabled, "session": self._public_session()}

    def submit_code(self, code):
        """Send the pasted code to the login screen. The value is validated, written once and not kept."""
        self._need_enabled()
        if not isinstance(code, str) or not CODE_RE.match(code.strip()):
            raise AuthError("that does not look like an authorization code: paste the code shown on the last page of the sign-in, not a web address")
        with self.lock:
            s = self.session
            if not s or s["state"] != "awaiting_browser" or not s["url"] or self._fd is None:
                raise AuthError("no sign-in is waiting for a code", 409)
            fd = self._fd
            s["state"], s["code_sent"], s["buffer"] = "verifying", self.clock(), ""     # the echo of the code must not stay in memory
        try:
            payload = (code.strip() + "\r").encode()
            os.write(fd, payload)
        except OSError:
            with self.lock:
                if self.session is s:
                    s.update(state="failed", error=MESSAGES["exited"], ended=self.clock(), buffer="")
        finally:
            code = payload = None                                                       # noqa: F841 (drop the references)
        return self._snapshot()

    def cancel(self):
        with self.lock:
            s = self.session
            if not s or s["state"] not in STATES_ACTIVE:
                return self._snapshot()
            s.update(state="cancelled", error=None, ended=self.clock(), buffer="")
            proc = self._proc
        self._terminate(proc)
        return self._snapshot()

    def logout(self):
        self._need_enabled()
        if self.active():
            raise AuthError("a sign-in is in progress: cancel it first", 409)
        if self.generation_busy():
            raise AuthError("a generation job is running: disconnect after it ends", 409)
        try:
            r = self._run(["auth", "logout"], 45)
        except FileNotFoundError:
            raise AuthError("Claude Code is not available", 503)
        except subprocess.TimeoutExpired:
            raise AuthError("the sign-out did not finish in time", 504)
        self._cache = (0.0, None)
        with self.lock:
            self.session = None
        if r.returncode != 0:
            raise AuthError("the sign-out failed", 500)
        return self.status()

    # --- internals ------------------------------------------------------------------------------------------------------------------
    def _new_session(self, method):
        now = self.clock()
        return {"state": "starting", "method": method, "url": None, "error": None, "started": now, "deadline": now + self.cfg.login_timeout,
                "ended": None, "code_sent": None, "buffer": ""}

    def _public_session(self):
        s = self.session
        if not s:
            return None
        now = self.clock()
        active = s["state"] in STATES_ACTIVE
        return {"state": s["state"], "method": s["method"], "url": s["url"] if active else None, "error": s["error"],
                "awaiting_code": s["state"] == "awaiting_browser" and bool(s["url"]),
                "seconds_left": max(0, int(s["deadline"] - now)) if active else 0}

    def _spawn_pty(self, args):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 1000, 0, 0))       # wide: the address must not wrap
        env = {**os.environ, "TERM": "xterm-256color", "NO_COLOR": "1", "COLUMNS": "1000", "LINES": "50"}
        try:
            proc = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True, close_fds=True)
        finally:
            os.close(slave)
        return proc, master

    def _terminate(self, proc):
        """Stop the login process group and always reap it (no zombie), even if it already exited by itself."""
        if proc is None:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                proc.wait(timeout=3)
                return
            except subprocess.TimeoutExpired:
                continue

    def _fail(self, s, key):
        with self.lock:
            if self.session is s and s["state"] in STATES_ACTIVE:
                s.update(state="failed", error=MESSAGES[key], ended=self.clock(), buffer="")
                return True
        return False

    def _pump(self, s, proc, fd):
        """Read the login screen, never keep or expose it: only the sign-in address and a few phrases are looked for."""
        try:
            while True:
                with self.lock:
                    if self.session is not s or s["state"] not in STATES_ACTIVE:
                        break
                    now = self.clock()
                    state, url_seen = s["state"], s["url"]
                if now > s["deadline"]:
                    self._fail(s, "timeout")
                    break
                if state == "verifying" and s["code_sent"] and now - s["code_sent"] > 90:
                    self._fail(s, "timeout")
                    break
                if state == "starting" and now - s["started"] > 45 and not url_seen:
                    self._fail(s, "no_url")
                    break
                ready, _, _ = select.select([fd], [], [], 0.25)
                chunk = b""
                if ready:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        break
                if chunk:
                    self._scan(s, chunk.decode("utf-8", "replace"))
                elif proc.poll() is not None:
                    break
            with self.lock:
                still = self.session is s and s["state"] in STATES_ACTIVE
            if still:                                       # the screen ended: its exit code (not yet reaped) says how
                try:
                    rc = proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    rc = None
                self._finish(s, rc)
        finally:
            with self.lock:
                s["buffer"] = ""
            self._terminate(proc)
            try:
                os.close(fd)
            except OSError:
                pass
            with self.lock:
                if self._proc is proc:
                    self._proc, self._fd = None, None

    def _scan(self, s, text):
        with self.lock:
            if self.session is not s or s["state"] not in STATES_ACTIVE:
                return
            s["buffer"] = (s["buffer"] + strip_ansi(text))[-(WINDOW_START if s["state"] == "starting" else WINDOW_LATER):]
            buf = s["buffer"]
            if s["state"] == "starting":
                url = extract_login_url(buf)
                if url:
                    s.update(state="awaiting_browser", url=url)
                    s["buffer"] = buf = ""
            low = buf.lower()
            if s["state"] == "verifying" and ("invalid authorization code" in low or "authentication failed" in low or "oauth error" in low):
                s.update(state="failed", error=MESSAGES["invalid_code"], ended=self.clock(), buffer="")
                return
            success = "login successful" in low
            fd = self._fd
        if success:
            try:
                os.write(fd, b"\r")                    # "Press Enter to continue": the credentials were saved before this screen
            except (OSError, TypeError):
                pass
            self._finish(s, 0)

    def _finish(self, s, rc):
        """The login screen is over: believe `claude auth status`, not the screen."""
        st = self.cli_status(force=True)
        with self.lock:
            if self.session is not s or s["state"] not in STATES_ACTIVE:
                return
            if st.get("logged_in") is True:
                s.update(state="succeeded", error=None, url=None, ended=self.clock(), buffer="")
            else:
                s.update(state="failed", error=MESSAGES["not_confirmed" if rc == 0 else "exited"], ended=self.clock(), buffer="")
