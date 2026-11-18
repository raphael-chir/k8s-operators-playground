"""Lifecycle coordination for deleting a whole Lab (P4.3.2). Standard library only (testable without FastAPI).

Only this server can see the Docker infrastructure, so it is the one that decides whether a Lab may be deleted: the AI Builder is told the
verdict ("infrastructure") and refuses anything but "stopped". Two rules:

  * fail closed: "stopped" only when a fresh query of the Playground's own discovery (engine/usecase-list.sh through `discover`) lists the Lab
    with zero clusters. Starting, stopping, deleting, unknown, a failed query or a Lab that is not listed are all NOT stopped;
  * no start can slip in: begin() marks the Lab as being deleted under the same lock that registers start/stop operations, so a start is
    either already registered (the deletion is refused) or refused (409) until end(). Only that Lab is affected, there is no global lock.
A cluster started outside this server (the CLI in a terminal) cannot be excluded by a lock: the fresh Docker query right before the move is
the protection for that case."""
import re

LAB_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
BUSY = ("starting", "stopping")


class DeleteGate:
    def __init__(self, lock, ops, discover):
        self.lock, self.ops, self.discover = lock, ops, discover      # app.py's own lock, operations registry and discovery
        self._deleting = set()

    def deleting(self, name):
        return name in self._deleting

    def _live(self, name):
        try:
            found = dict(self.discover())
        except Exception:                                     # Docker unreachable, timeout, bad output: not "stopped"
            return "unknown"
        if name not in found:
            return "unknown"
        return "running" if found[name] > 0 else "stopped"

    def infra(self, name):
        """The Lab's infrastructure state for presenting a confirmation: stopped | running | starting | stopping | unknown."""
        if not isinstance(name, str) or not LAB_RE.match(name):
            return "unknown"
        with self.lock:
            if name in self._deleting:
                return "unknown"
            op = self.ops.get(name)
            if op and op["state"] in BUSY:
                return op["state"]
        return self._live(name)

    def begin(self, name):
        """Start a deletion: (acquired, state). `state` is "stopped" only when acquired and verified just now. Pair with end() when acquired."""
        if not isinstance(name, str) or not LAB_RE.match(name):
            return False, "unknown"
        with self.lock:
            if name in self._deleting:
                return False, "unknown"
            op = self.ops.get(name)
            if op and op["state"] in BUSY:
                return False, op["state"]
            self._deleting.add(name)
        return True, self._live(name)

    def end(self, name):
        with self.lock:
            self._deleting.discard(name)
