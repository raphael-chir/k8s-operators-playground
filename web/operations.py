"""Cancelling a use case start (standard library only, testable without FastAPI). Cancel is the existing Stop, made available while the
use case is starting: first the start's whole process group is ended (the shell, kind / k3d / helm / kubectl and everything they spawned),
and only when nothing of it is left does the ordinary `usecase stop` run. So the start can never create a resource after the stop began,
and there is one cleanup implementation (engine/usecase.sh usecase_delete -> provider_destroy), not two."""
import os
import signal
import time


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
