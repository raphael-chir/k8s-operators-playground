"""Publishing a validated, approved tree into the use case directory.

This is the ONLY code that writes into published Labs. In the container deployment it runs inside the separate `ai-publisher`
service (publisher.py), the only container with a writable mount of `usecases/`; the AI Builder, where Claude Code runs, has
that directory read-only. In host mode (no containers) the AI Builder calls it directly.

publish_tree() never trusts its caller: it recomputes the content hash of the source, re-validates the tree and, when it
replaces a Lab, checks that the published Lab is still the one the working copy was made from.
"""
import hashlib
import http.client
import json
import os
import re
import secrets
import shutil
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

import validator

NAME_RE = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")
MAX_FILES = 300
MAX_TREE_BYTES = 4 * 1024 * 1024
TRASH = ".trash"            # usecases/.trash/<lab>-<UTC time>-<token>/: where a deleted Lab goes (recoverable, never purged here)
_LOCK = threading.Lock()     # publications and deletions of this publisher never overlap


class PublishError(Exception):
    def __init__(self, errors, status=409):
        super().__init__("; ".join(errors))
        self.errors, self.status = errors, status


def tree_hash(root):
    """SHA-256 of every file of a tree (relative path + content), the identity of a Lab's content."""
    h = hashlib.sha256()
    for p in sorted(Path(root).rglob("*")):
        if p.is_file():
            h.update(str(p.relative_to(root)).encode() + b"\0" + p.read_bytes() + b"\0")
    return h.hexdigest()


def check_source(source):
    """A plain directory tree: no symlinks, not too many files, not too large."""
    source = Path(source)
    if not source.is_dir() or source.is_symlink():
        raise PublishError(["the source is not a directory"], 404)
    count = total = 0
    for p in source.rglob("*"):
        if p.is_symlink():
            raise PublishError([f"{p.relative_to(source)}: symbolic links are not allowed"])
        if p.is_file():
            count += 1
            total += p.stat().st_size
    if count > MAX_FILES or total > MAX_TREE_BYTES:
        raise PublishError([f"the tree is too large ({count} files, {total} bytes)"])


def _exchange(a, b):
    """Atomically swap two directories (Linux renameat2 RENAME_EXCHANGE). False when the platform or filesystem cannot."""
    try:
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        rc = libc.renameat2(-100, os.fsencode(str(a)), -100, os.fsencode(str(b)), 2)
        return rc == 0
    except (OSError, AttributeError):
        return False


def publish_tree(publish_dir, name, source, expected_hash, base_hash=None, replace=False):
    with _LOCK:
        return _publish_tree(publish_dir, name, source, expected_hash, base_hash, replace)


def _publish_tree(publish_dir, name, source, expected_hash, base_hash=None, replace=False):
    """Copy `source` to <publish_dir>/<name>. New Lab (replace=False): the name must be free. Replace: the published Lab must
    still hash to `base_hash`. Returns {"name", "published", "tree_hash"}; raises PublishError(409 conflict / 404 / 500)."""
    publish_dir = Path(publish_dir)
    if not isinstance(name, str) or not NAME_RE.match(name) or len(name) > 40:
        raise PublishError(["invalid use case name"], 400)
    check_source(source)
    if not isinstance(expected_hash, str) or tree_hash(source) != expected_hash:
        raise PublishError(["the draft changed after approval: review and approve it again"])
    root_file = Path(source) / "usecase.yaml"
    if root_file.is_symlink() or not root_file.is_file():
        raise PublishError(["the draft no longer validates", "usecase.yaml is required: a Lab cannot lose it (removing a whole Lab is a separate operation)"])
    errors = validator.validate_draft(Path(source), name)
    if errors:
        raise PublishError(["the draft no longer validates"] + errors[:10])
    target = publish_dir / name
    if replace:
        if not target.is_dir() or target.is_symlink():
            raise PublishError([f"usecases/{name} no longer exists: it cannot be replaced"])
        if base_hash is None or tree_hash(target) != base_hash:
            raise PublishError([f"conflict: usecases/{name} changed since the working copy was made. Nothing was overwritten"])
    elif os.path.lexists(target):
        raise PublishError([f"usecases/{name} already exists: nothing was overwritten"])
    token = secrets.token_hex(4)
    staging, old = publish_dir / f".staging-{name}-{token}", publish_dir / f".old-{name}-{token}"
    try:
        shutil.copytree(source, staging, symlinks=False)
        for sh in staging.glob("*.sh"):
            sh.chmod(0o755)
        if replace:
            if not _exchange(staging, target):           # fallback: two renames, the previous Lab is put back if the second fails
                os.rename(target, old)
                try:
                    os.rename(staging, target)
                except OSError:
                    os.rename(old, target)
                    raise
            # either way the replaced Lab now sits in `staging` (exchange) or `old` (fallback); both are removed below
        else:
            try:
                os.rename(staging, target)
            except OSError:
                raise PublishError([f"usecases/{name} could not be created (it may have appeared meanwhile): nothing was overwritten"])
    except PermissionError:
        raise PublishError(["the publish directory is not writable by the AI Builder"], 500)
    except OSError:
        raise PublishError([f"usecases/{name} could not be updated: nothing was overwritten"])
    finally:
        for leftover in (staging, old):
            shutil.rmtree(leftover, ignore_errors=True)   # staging, or the replaced Lab; never the new one
    return {"name": name, "published": f"usecases/{name}", "tree_hash": tree_hash(target)}


def trash_tree(publish_dir, name, expected_hash):
    """Remove a whole Lab from the active Playground WITHOUT deleting it: one atomic rename of usecases/<name> to
    usecases/.trash/<name>-<UTC time>-<token>/ (same filesystem, unique destination, nothing overwritten, no rm -rf, no purge).
    Refused unless the Lab is a real directory (no symlink) whose content hash is `expected_hash` (what the user confirmed).
    A small <destination>.json next to it records what it was and how to put it back. Returns {"name", "trash", "tree_hash"}."""
    publish_dir = Path(publish_dir)
    if not isinstance(name, str) or not NAME_RE.match(name) or len(name) > 40:
        raise PublishError(["invalid use case name"], 400)
    if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        raise PublishError(["expected_hash: the content hash of the Lab the user confirmed"], 400)
    with _LOCK:
        target = publish_dir / name
        if target.is_symlink() or not target.is_dir():
            raise PublishError([f"usecases/{name} does not exist"], 404)
        if tree_hash(target) != expected_hash:
            raise PublishError([f"usecases/{name} changed since it was confirmed: nothing was deleted"])
        trash = publish_dir / TRASH
        if trash.is_symlink():
            raise PublishError(["the trash directory is not a plain directory"], 500)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        try:
            trash.mkdir(exist_ok=True)
            dest = trash / f"{name}-{stamp}-{secrets.token_hex(4)}"
            if os.path.lexists(dest):
                raise PublishError(["the trash destination already exists: nothing was deleted"], 500)
            os.rename(target, dest)                          # atomic; fails (never overwrites) if the destination exists
        except PermissionError:
            raise PublishError(["the publish directory is not writable by the AI Builder"], 500)
        except OSError:
            raise PublishError([f"usecases/{name} could not be moved to the trash: nothing was deleted"], 500)
        try:                                                 # recovery information (best effort: the Lab itself is already safe)
            (trash / f"{dest.name}.json").write_text(json.dumps({"name": name, "deleted_at": stamp, "tree_hash": expected_hash,
                "restore": f"mv usecases/{TRASH}/{dest.name} usecases/{name}"}, indent=1), encoding="utf-8")
        except OSError:
            pass
    return {"name": name, "trash": f"usecases/{TRASH}/{dest.name}", "tree_hash": expected_hash}


def remote_delete(url, token, payload, timeout=60):
    """Ask the ai-publisher service to move a Lab to the trash. Same transport and errors as remote_publish."""
    return _remote(url, token, "/delete", payload, timeout)


def remote_publish(url, token, payload, timeout=60):
    return _remote(url, token, "/publish", payload, timeout)


def _remote(url, token, path, payload, timeout):
    """Ask the ai-publisher service. Returns its answer; raises PublishError with its status and message."""
    u = urlsplit(url)
    if u.scheme != "http" or not u.hostname:
        raise PublishError(["the publisher address is invalid"], 500)
    conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=timeout)
    try:
        conn.request("POST", path, body=json.dumps(payload).encode(),
                     headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
        resp = conn.getresponse()
        data = json.loads(resp.read(1024 * 1024).decode("utf-8") or "{}")
        status = resp.status
    except (OSError, ValueError, http.client.HTTPException):
        raise PublishError(["the publisher is not reachable: start the AI Builder with ./playground ai-builder start"], 503)
    finally:
        conn.close()
    if status != 200:
        raise PublishError(data.get("details") or [data.get("error", "the publisher refused the request")], status if status in (400, 404, 409, 500) else 502)
    return data
