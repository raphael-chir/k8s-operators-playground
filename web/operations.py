"""Cancelling a use case start (standard library only, testable without FastAPI). Cancel is the existing Stop, made available while the
use case is starting: first the start's whole process group is ended (the shell, kind / k3d / helm / kubectl and everything they spawned),
and only when nothing of it is left does the ordinary `usecase stop` run. So the start can never create a resource after the stop began,
and there is one cleanup implementation (engine/usecase.sh usecase_delete -> provider_destroy), not two."""
import os
import signal
import time
from pathlib import Path


def terminate_group(proc, grace=5.0):
    """End the process group of a child started with start_new_session=True: SIGTERM, then SIGKILL after `grace` seconds, and always a final
    SIGKILL of whatever is left of the group (a child that ignored SIGTERM, or outlived its parent). Returns once the leader is reaped."""
    def send(sig):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):      # nothing of the group is left
            pass
    send(signal.SIGTERM)
    deadline = time.time() + grace
    while proc.poll() is None and time.time() < deadline:
        time.sleep(0.05)
    send(signal.SIGKILL)
    proc.wait()


def cancel_then_stop(lock, old_op, stop_op, spawn, watch):
    """Runs in its own thread. `old_op` is the running start (its "proc" is the child); `stop_op` is the already registered stop operation.
    `spawn()` starts the stop and returns (log_file, proc); `watch(proc)` waits for it and records the outcome. A stop that cannot even be
    started is recorded as failed, so the use case is not left "stopping" for ever and Stop can be retried."""
    terminate_group(old_op["proc"])
    try:
        log_file, proc = spawn()
    except OSError:
        with lock:
            stop_op.update(state="failed", exit_code=-1, finished=time.time())
        return
    stop_op["log_file"], stop_op["proc"] = log_file, proc
    watch(proc)


def host_issues(path, provider_type, now=None, max_age=20):
    """The WARNING / CRITICAL host findings the host-side sampler (engine/host-metrics.sh) last wrote to `path`, for the confirmation shown before a
    start. This code runs in the container and must not present its own view as the host's, so it only reads that file. Returns [] when there is
    nothing to confirm: no issue, an external use case (its cluster is not on this host), or no fresh measurement (file missing or older than
    `max_age` seconds: unavailable diagnostics never block a start). Each issue: {id, status, title, current, current_lines, recommended, recommended_lines, impact, fix, restore}; fix and restore are lists of {text, command}."""
    if provider_type == "external":
        return []
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
        stamp = float(lines[0].split("=", 1)[1]) if lines and lines[0].startswith("#ts=") else None
    except (OSError, ValueError, IndexError, UnicodeDecodeError):
        return []
    if stamp is None or (time.time() if now is None else now) - stamp > max_age:
        return []
    issues = []
    for line in lines[1:]:
        f = (line.split("|") + [""] * 8)[:8]
        if f[1] in ("WARNING", "CRITICAL") and f[2]:
            issues.append({"id": f[0], "status": f[1], "title": f[2], "current": f[3].replace(";;", " / "), "current_lines": _lines(f[3]),
                           "recommended": f[4].replace(";;", " / "), "recommended_lines": _lines(f[4]), "impact": f[5], "fix": _steps(f[6]), "restore": _steps(f[7])})
    return issues


def _lines(text):
    return [t for t in text.split(";;") if t]


def _steps(text):
    """The fix / restore lines of a record (engine/lib/hostcheck.sh): "$ cmd" is a command to copy, anything else an explanation."""
    return [{"text": t[2:], "command": True} if t.startswith("$ ") else {"text": t, "command": False} for t in _lines(text)]
