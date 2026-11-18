"""Working copy of ONE existing Lab for ONE conversation (SPEC-023).

    <state>/workspaces/<conversation>/
        work/            the editable copy: exactly the files of the Lab (this is what Claude edits and what gets published)
        objects/<sha256> contents of the initial state and of the state before each edit turn (deduplicated)
        meta.json        lab, hash of the published Lab it was copied from, the initial manifest, the undo stack

A manifest is {relative path: sha256}. A snapshot is therefore a small JSON map plus the few file contents that are not in
the store yet: nothing is copied per message, Undo restores the previous manifest, Reset restores the initial one, and the
diff compares the initial manifest with the work directory. No Git, no database.

The published Lab is only ever READ here (to make the copy and to detect that it changed). Every path that comes out of a
manifest is checked before it is used, and symbolic links are never followed or kept.
"""
import difflib
import hashlib
import json
import os
import re
import shutil
from pathlib import Path

import publishing

MAX_UNDO = 20
MAX_DIFF_BYTES = 200 * 1024
MAX_DIFF_LINES = 400


class WorkspaceError(Exception):
    def __init__(self, message, status=409):
        super().__init__(message)
        self.status = status


def safe_rel(rel):
    """True for a normal relative path (no absolute path, no '..', no empty or NUL part)."""
    if not isinstance(rel, str) or not rel or "\0" in rel or rel.startswith("/"):
        return False
    return all(part not in ("", ".", "..") for part in rel.split("/"))


PROTECTED = frozenset({"usecase.yaml"})        # the mandatory root file of a Lab: it can be replaced, never deleted on its own
DELETE_PATH_RE = re.compile(r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$")


def delete_file(work, rel):
    """Delete ONE regular file of a working copy (the only deletion Claude is given). Raises WorkspaceError(message, 400/404/409) and
    changes nothing unless every check passes: a plain relative path (no absolute path, no '..', no odd characters), not the root
    usecase.yaml, no symbolic link anywhere on the path (the file or a parent), a regular file (never a directory, never recursive),
    and inside the working copy once resolved. Empty parent directories left behind are removed (never the working copy itself)."""
    if not isinstance(rel, str) or not safe_rel(rel) or not DELETE_PATH_RE.match(rel) or len(rel) > 200:
        raise WorkspaceError("path: a relative file path inside the Lab (no absolute path, no '..')", 400)
    if rel in PROTECTED:
        raise WorkspaceError(f"{rel} is mandatory and cannot be deleted (edit or replace it instead)", 400)
    root = Path(work)
    if root.is_symlink() or not root.is_dir():
        raise WorkspaceError("the working copy is not available", 409)
    parts = rel.split("/")
    cur = root
    for part in parts[:-1]:
        cur = cur / part
        if cur.is_symlink():
            raise WorkspaceError("a symbolic link on the path: refused", 400)
        if not cur.is_dir():
            raise WorkspaceError(f"{rel} does not exist", 404)
    target = cur / parts[-1]
    if target.is_symlink():
        raise WorkspaceError("a symbolic link: refused", 400)
    if not target.exists():
        raise WorkspaceError(f"{rel} does not exist", 404)
    if target.is_dir() or not target.is_file():
        raise WorkspaceError("directories cannot be deleted (delete the files one by one)", 400)
    try:
        target.resolve().relative_to(root.resolve())
    except ValueError:
        raise WorkspaceError("the path resolves outside the working copy: refused", 400)
    target.unlink()
    for parent in reversed([root.joinpath(*parts[:i]) for i in range(1, len(parts))]):
        try:
            parent.rmdir()                        # only if now empty
        except OSError:
            break


def _sha(data):
    return hashlib.sha256(data).hexdigest()


class Workspace:
    def __init__(self, root):
        self.root = Path(root)
        self.work, self.objects, self.meta_file = self.root / "work", self.root / "objects", self.root / "meta.json"

    # --- state ---------------------------------------------------------------------------------------------------------------
    def exists(self):
        return self.meta_file.is_file() and self.work.is_dir()

    def _meta(self):
        return json.loads(self.meta_file.read_text(encoding="utf-8"))

    def _save(self, meta):
        tmp = self.meta_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(meta), encoding="utf-8")
        tmp.replace(self.meta_file)

    def info(self):
        meta = self._meta()
        return {"lab": meta["lab"], "created": meta["created"], "base_hash": meta["base_hash"], "can_undo": bool(meta["undo"]),
                "undo_depth": len(meta["undo"])}

    # --- manifests ---------------------------------------------------------------------------------------------------------------
    def sanitize(self):
        """Remove anything that is not a plain file or directory (a symbolic link must never survive in the working copy)."""
        for p in list(self.work.rglob("*")):
            if p.is_symlink():
                p.unlink()
            elif not (p.is_file() or p.is_dir()):
                try:
                    p.unlink()
                except OSError:
                    pass

    def manifest(self, sanitize=True):
        """{path: sha256} of the working copy. `sanitize=False` is for read-only views: it removes nothing but still skips links."""
        if sanitize:
            self.sanitize()
        out = {}
        for p in sorted(self.work.rglob("*")):
            if p.is_file() and not p.is_symlink():
                out[p.relative_to(self.work).as_posix()] = _sha(p.read_bytes())
        return out

    def _store_current(self, manifest):
        """Put the contents of the files listed in `manifest` (as they are now in work/) into the object store."""
        self.objects.mkdir(parents=True, exist_ok=True)
        for rel, sha in manifest.items():
            obj = self.objects / sha
            if not obj.exists():
                obj.write_bytes((self.work / rel).read_bytes())

    def _gc(self, meta):
        keep = set(meta["base"].values())
        for entry in meta["undo"]:
            keep.update(entry["before"].values())
        for obj in self.objects.glob("*"):
            if obj.name not in keep:
                obj.unlink(missing_ok=True)

    def _restore(self, manifest):
        """Make work/ equal to `manifest` using stored objects. Raises WorkspaceError when an object or a path is not trustworthy."""
        for rel, sha in manifest.items():
            if not safe_rel(rel) or not isinstance(sha, str) or not (self.objects / sha).is_file():
                raise WorkspaceError("the saved state is damaged: use Reset or discard the working copy")
        keep = set(manifest)
        for p in sorted(self.work.rglob("*"), reverse=True):
            if p.is_symlink() or (p.is_file() and p.relative_to(self.work).as_posix() not in keep):
                p.unlink()
            elif p.is_dir() and not any(p.iterdir()):
                p.rmdir()
        for rel, sha in manifest.items():
            dest = self.work / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            data = (self.objects / sha).read_bytes()
            if not dest.is_file() or dest.is_symlink() or _sha(dest.read_bytes()) != sha:
                if dest.is_symlink():
                    dest.unlink()
                dest.write_bytes(data)
            if rel.endswith(".sh"):
                dest.chmod(0o755)

    # --- lifecycle ---------------------------------------------------------------------------------------------------------------
    def create(self, published_dir, lab, now):
        """Copy the published Lab into a new working copy. The published directory is only read."""
        published_dir = Path(published_dir)
        publishing.check_source(published_dir)
        if self.root.exists():
            raise WorkspaceError("a working copy already exists", 409)
        try:
            self.work.mkdir(parents=True)
            shutil.copytree(published_dir, self.work, symlinks=False, dirs_exist_ok=True)
            manifest = self.manifest()
            self._store_current(manifest)
            self._save({"lab": lab, "created": now, "base_hash": publishing.tree_hash(published_dir), "base": manifest, "undo": []})
        except Exception:
            shutil.rmtree(self.root, ignore_errors=True)
            raise
        return self.info()

    def create_empty(self, lab, now):
        """A working copy for a Lab that does not exist yet: empty, with no base hash (publishing it creates the Lab, never replaces one)."""
        if self.root.exists():
            raise WorkspaceError("a working copy already exists", 409)
        try:
            self.work.mkdir(parents=True)
            self._store_current({})
            self._save({"lab": lab, "created": now, "base_hash": None, "base": {}, "undo": []})
        except Exception:
            shutil.rmtree(self.root, ignore_errors=True)
            raise
        return self.info()

    def begin_turn(self, turn):
        """Called before an editing turn: remember the state to go back to (only new file contents are stored)."""
        meta = self._meta()
        before = self.manifest()
        self._store_current(before)
        meta["undo"].append({"turn": turn, "before": before})
        meta["undo"] = meta["undo"][-MAX_UNDO:]
        self._gc(meta)
        self._save(meta)

    def end_turn(self, turn):
        """Called after an editing turn. Returns the manifest after it; an unchanged turn leaves no undo step; a working copy that grew
        past the limits is rolled back to before the turn."""
        meta = self._meta()
        after = self.manifest()
        entry = meta["undo"][-1] if meta["undo"] and meta["undo"][-1]["turn"] == turn else None
        if entry is None:
            return after
        total = sum((self.work / rel).stat().st_size for rel in after)
        if len(after) > publishing.MAX_FILES or total > publishing.MAX_TREE_BYTES:
            self._restore(entry["before"])
            meta["undo"].pop()
            self._gc(meta)
            self._save(meta)
            raise WorkspaceError("the edit made the Lab too large and was rolled back")
        if after == entry["before"]:
            meta["undo"].pop()
            self._gc(meta)
            self._save(meta)
        return after

    def undo(self):
        meta = self._meta()
        if not meta["undo"]:
            raise WorkspaceError("nothing to undo")
        entry = meta["undo"].pop()
        self._restore(entry["before"])
        self._gc(meta)
        self._save(meta)
        return entry["turn"]

    def reset(self):
        """Back to the initial state (the published Lab as it was when the copy was made)."""
        meta = self._meta()
        self._restore(meta["base"])
        meta["undo"] = []
        self._gc(meta)
        self._save(meta)

    def rebase(self):
        """After a publication: the working copy IS the published Lab now; it becomes the new initial state."""
        meta = self._meta()
        manifest = self.manifest()
        self._store_current(manifest)
        meta.update(base=manifest, base_hash=publishing.tree_hash(self.work), undo=[])
        self._gc(meta)
        self._save(meta)

    def discard(self):
        shutil.rmtree(self.root, ignore_errors=True)

    # --- comparing ---------------------------------------------------------------------------------------------------------------
    def changes(self, sanitize=True):
        base, now = self._meta()["base"], self.manifest(sanitize)
        return {"added": sorted(set(now) - set(base)), "deleted": sorted(set(base) - set(now)),
                "modified": sorted(p for p in set(base) & set(now) if base[p] != now[p])}

    def tree_hash(self):
        self.sanitize()
        return publishing.tree_hash(self.work)

    def _text(self, data):
        try:
            return data.decode("utf-8").splitlines(keepends=True)
        except UnicodeDecodeError:
            return None

    def diff(self):
        """Readable unified diffs of every changed file, bounded in size: [{path, change, diff, truncated}]."""
        meta, ch = self._meta(), self.changes()
        out, used = [], 0
        for change in ("modified", "added", "deleted"):
            for rel in ch[change]:
                old = (self.objects / meta["base"][rel]).read_bytes() if change != "added" else b""
                new = (self.work / rel).read_bytes() if change != "deleted" else b""
                a, b = self._text(old), self._text(new)
                if a is None or b is None:
                    text, cut = f"(binary file {change})\n", False
                else:
                    lines = list(difflib.unified_diff(a, b, f"a/{rel}", f"b/{rel}", n=2))
                    cut = len(lines) > MAX_DIFF_LINES or used > MAX_DIFF_BYTES
                    text = "".join(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n" for line in lines[:MAX_DIFF_LINES])
                used += len(text)
                out.append({"path": rel, "change": change, "diff": text, "truncated": cut})
        return out
