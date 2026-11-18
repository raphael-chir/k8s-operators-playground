"""Tests of conversational Lab editing (SPEC-023): working copy, publisher, permissions, review, undo/reset, conflicts, publication.
A scripted runner stands in for Claude Code: no real Claude call, no Docker, Kubernetes or Helm. Run: tests/ai-builder.sh"""
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "ai-builder"))
sys.path.insert(0, str(REPO / "tests"))
import builder, conversations, publisher, publishing, server, validator, workspace as wsmod  # noqa: E402
from ai_builder_conversation_test import arg_after, result  # noqa: E402
from ai_builder_test import fake_repo, write_good  # noqa: E402

LAB = "demo-lab"
TOKEN = "t" * 64


def make_lab(root, name=LAB):
    write_good(Path(root) / "usecases" / name)
    return Path(root) / "usecases" / name


def work_of(args):
    """The working-copy path granted to Write in an argument list (None when the call cannot write)."""
    import re
    m = re.search(r"Write\(/(/[^)]*?)/\*\*\)", " ".join(a for a in args if a.startswith("--allowedTools=")))
    return Path(m.group(1)) if m else None


def works_of(args):
    """Every working-copy path granted to Write (several when several Labs are approved)."""
    import re
    return [Path(m) for m in re.findall(r"Write\(/(/[^)]*?)/\*\*\)", " ".join(a for a in args if a.startswith("--allowedTools=")))]


class Base(unittest.TestCase):
    def setUp(self):
        self.root = fake_repo()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.lab = make_lab(self.root)
        self.calls, self.script, self.gate = [], [], None            # gate: an Event that holds a Claude call "in flight"

    def runner(self, args, cwd, timeout, env=None):
        self.calls.append(list(args))
        if self.gate:
            self.gate.wait(10)
        step = self.script.pop(0) if self.script else None
        if callable(step):
            for work in works_of(args):                  # the same scripted edit in every writable working copy
                step(work)
        sid = arg_after(args, "--resume" if "--resume" in args else "--session-id")
        return 0, json.dumps({**result(getattr(self, "reply", "an answer"), uuid=sid), "session_id": sid}), "", False

    def manager(self, env=None, jobs_busy=lambda: False):
        self.cfg = builder.Config(env=env or {}, root=self.root)
        self.cfg.claude_missing = lambda: False
        return conversations.ConversationManager(self.cfg, runner=self.runner, jobs_busy=jobs_busy)

    def lab_conv(self, m):
        return m.create("about the lab", LAB)["id"]

    def say(self, m, cid, text):
        conv = m.convs[cid]
        if conv["lab"] and conversations.EDIT_RE.search(text) and not m._edit_on(conv):
            m.set_context(cid, "allow_edit")              # the user's approval (Context menu): a request alone never enables editing
        m.send(cid, text, background=False)
        return m.get(cid)

    def tree(self, path):
        return {p.relative_to(path).as_posix(): p.read_bytes() for p in sorted(Path(path).rglob("*")) if p.is_file()}


# ===================================================================== the working copy itself
class WorkspaceTests(Base):
    def setUp(self):
        super().setUp()
        self.ws = wsmod.Workspace(Path(tempfile.mkdtemp()) / "ws")
        self.addCleanup(shutil.rmtree, self.ws.root.parent, True)
        self.before = self.tree(self.lab)
        self.ws.create(self.lab, LAB, "2026-01-01T00:00:00+00:00")

    def edit(self, turn, fn):
        self.ws.begin_turn(turn); fn(self.ws.work); return self.ws.end_turn(turn)

    def test_the_copy_equals_the_lab_and_the_published_lab_is_untouched(self):
        self.assertEqual(self.tree(self.ws.work), self.before)
        self.assertEqual(self.tree(self.lab), self.before)
        self.assertEqual(self.ws.info()["base_hash"], publishing.tree_hash(self.lab))
        self.assertEqual(self.ws.changes(), {"added": [], "deleted": [], "modified": []})
        self.assertTrue(os.access(self.ws.work / "01_demo.sh", os.R_OK))

    def test_editing_the_copy_never_changes_the_published_lab(self):
        self.edit(1, lambda w: ((w / "README.md").write_text("changed\n"), (w / "01_demo.sh").unlink(), (w / "02_new.sh").write_text("#!/bin/bash\n")))
        self.assertEqual(self.tree(self.lab), self.before)
        self.assertEqual(self.ws.changes(), {"added": ["02_new.sh"], "deleted": ["01_demo.sh"], "modified": ["README.md"]})

    def test_diff_is_readable_for_modified_added_deleted_and_binary(self):
        def go(w):
            (w / "README.md").write_text("# Demo\nsecond line\n"); (w / "new.txt").write_text("hello\n"); (w / "01_demo.sh").unlink(); (w / "blob.bin").write_bytes(b"\xff\xfe\x00")
        self.edit(1, go)
        diff = {d["path"]: d for d in self.ws.diff()}
        self.assertIn("+second line", diff["README.md"]["diff"]); self.assertIn("--- a/README.md", diff["README.md"]["diff"])
        self.assertIn("+hello", diff["new.txt"]["diff"]); self.assertEqual(diff["new.txt"]["change"], "added")
        self.assertTrue(diff["01_demo.sh"]["diff"].startswith("--- a/01_demo.sh")); self.assertEqual(diff["01_demo.sh"]["change"], "deleted")
        self.assertIn("binary", diff["blob.bin"]["diff"])

    def test_a_long_diff_is_cut(self):
        self.edit(1, lambda w: (w / "README.md").write_text("\n".join(f"line {i}" for i in range(2000)) + "\n"))
        d = self.ws.diff()[0]
        self.assertTrue(d["truncated"]); self.assertLessEqual(d["diff"].count("\n"), wsmod.MAX_DIFF_LINES + 5)

    def test_undo_restores_the_state_before_the_last_edit_only(self):
        self.edit(1, lambda w: (w / "README.md").write_text("one\n"))
        self.edit(2, lambda w: ((w / "README.md").write_text("two\n"), (w / "extra.sh").write_text("x\n")))
        self.assertEqual(self.ws.undo(), 2)
        self.assertEqual((self.ws.work / "README.md").read_text(), "one\n"); self.assertFalse((self.ws.work / "extra.sh").exists())
        self.assertEqual(self.ws.undo(), 1)
        self.assertEqual(self.tree(self.ws.work), self.before)
        with self.assertRaises(wsmod.WorkspaceError):
            self.ws.undo()

    def test_a_turn_that_changes_nothing_leaves_no_undo_step(self):
        self.edit(1, lambda w: None)
        self.assertFalse(self.ws.info()["can_undo"])
        self.edit(2, lambda w: (w / "README.md").write_text("x\n")); self.assertTrue(self.ws.info()["can_undo"])

    def test_reset_returns_to_the_initial_lab_including_deleted_and_added_files(self):
        self.edit(1, lambda w: ((w / "01_demo.sh").unlink(), (w / "manifests" / "cluster.yaml").write_text("kind: Other\n")))
        self.edit(2, lambda w: ((w / "new" / "deep").mkdir(parents=True), (w / "new" / "deep" / "f.txt").write_text("1")))
        self.ws.reset()
        self.assertEqual(self.tree(self.ws.work), self.before)
        self.assertFalse((self.ws.work / "new").exists(), "emptied directories are removed")
        self.assertFalse(self.ws.info()["can_undo"]); self.assertEqual(self.ws.changes(), {"added": [], "deleted": [], "modified": []})

    def test_no_full_copy_per_message_and_unreferenced_objects_are_removed(self):
        files = len(self.before)
        for turn in range(1, 8):
            self.edit(turn, lambda w, t=turn: (w / "README.md").write_text(f"version {t}\n"))
        count = len(list(self.ws.objects.glob("*")))
        self.assertEqual(count, (files - 1) + 7, "unchanged files are stored once; only the 7 successive README versions are kept for undo")
        self.assertLess(count, files * 7, "far fewer objects than one full copy per message")
        self.ws.reset()
        self.assertEqual(len(list(self.ws.objects.glob("*"))), len(set(wsmod.Workspace.manifest(self.ws).values())), "after a reset only the initial contents remain")

    def test_the_undo_stack_is_bounded(self):
        for turn in range(1, wsmod.MAX_UNDO + 6):
            self.edit(turn, lambda w, t=turn: (w / "README.md").write_text(f"v{t}\n"))
        self.assertEqual(self.ws.info()["undo_depth"], wsmod.MAX_UNDO)
        self.ws.reset(); self.assertEqual(self.tree(self.ws.work), self.before)

    def test_rebase_makes_the_copy_the_new_initial_state(self):
        self.edit(1, lambda w: (w / "README.md").write_text("published text\n"))
        self.ws.rebase()
        self.assertEqual(self.ws.changes(), {"added": [], "deleted": [], "modified": []}); self.assertFalse(self.ws.info()["can_undo"])
        self.assertEqual(self.ws.info()["base_hash"], self.ws.tree_hash())
        self.edit(2, lambda w: (w / "README.md").write_text("more\n")); self.ws.reset()
        self.assertEqual((self.ws.work / "README.md").read_text(), "published text\n")

    def test_a_growing_working_copy_is_rolled_back(self):
        with mock.patch.object(publishing, "MAX_FILES", 5):
            with self.assertRaises(wsmod.WorkspaceError):
                self.edit(1, lambda w: [(w / f"f{i}.txt").write_text("x") for i in range(10)])
        self.assertEqual(self.tree(self.ws.work), self.before)

    def test_paths_in_a_damaged_manifest_cannot_escape(self):
        for bad in ("../evil.txt", "/tmp/evil.txt", "a/../../evil", "", "a//b", "a/./b"):
            self.assertFalse(wsmod.safe_rel(bad), bad)
        outside = self.ws.root.parent / "evil.txt"
        sha = next(iter(self.ws.objects.glob("*"))).name
        meta = json.loads(self.ws.meta_file.read_text()); meta["undo"].append({"turn": 9, "before": {"../evil.txt": sha}})
        self.ws.meta_file.write_text(json.dumps(meta))
        with self.assertRaises(wsmod.WorkspaceError):
            self.ws.undo()
        self.assertFalse(outside.exists())

    def test_symbolic_links_never_survive_and_are_never_followed(self):
        secret = Path(tempfile.mkdtemp()) / "secret.txt"; secret.write_text("TOP-SECRET"); self.addCleanup(shutil.rmtree, secret.parent, True)
        (self.ws.work / "link.txt").symlink_to(secret)
        self.assertNotIn("link.txt", self.ws.manifest(sanitize=False))
        self.assertNotIn("link.txt", self.ws.manifest())
        self.assertFalse((self.ws.work / "link.txt").is_symlink() or (self.ws.work / "link.txt").exists())
        self.assertNotIn(b"TOP-SECRET", b"".join(p.read_bytes() for p in self.ws.objects.glob("*")))

    def test_a_lab_with_a_symlink_cannot_be_copied(self):
        (self.lab / "evil").symlink_to("/etc/hosts")
        with self.assertRaises(publishing.PublishError):
            wsmod.Workspace(self.ws.root.parent / "second").create(self.lab, LAB, "now")
        self.assertFalse((self.ws.root.parent / "second").exists())

    def test_discard_removes_everything(self):
        self.ws.discard(); self.assertFalse(self.ws.root.exists()); self.assertFalse(self.ws.exists())


# ===================================================================== the only code that writes published Labs
class PublishingTests(Base):
    def setUp(self):
        super().setUp()
        self.pub = self.root / "usecases"
        self.src = Path(tempfile.mkdtemp()) / "src"; self.addCleanup(shutil.rmtree, self.src.parent, True)
        shutil.copytree(self.lab, self.src)

    def go(self, name=LAB, replace=True, base=None, **kw):
        base = publishing.tree_hash(self.lab) if base is None and replace else base
        return publishing.publish_tree(self.pub, name, self.src, kw.get("expected", publishing.tree_hash(self.src)), base, replace)

    def hidden(self):
        return [p.name for p in self.pub.iterdir() if p.name.startswith(".")]

    def test_a_new_lab_is_created_and_an_existing_one_is_never_overwritten(self):
        out = self.go("fresh-lab", replace=False)
        self.assertEqual((out["published"], (self.pub / "fresh-lab" / "usecase.yaml").is_file()), ("usecases/fresh-lab", True)); self.assertEqual(self.hidden(), [])
        with self.assertRaises(publishing.PublishError) as cm:
            self.go(LAB, replace=False)
        self.assertEqual(cm.exception.status, 409)

    def test_replace_swaps_the_content_and_leaves_nothing_behind(self):
        (self.src / "README.md").write_text("# Replaced\n")
        out = self.go()
        self.assertEqual((self.pub / LAB / "README.md").read_text(), "# Replaced\n"); self.assertEqual(self.hidden(), [])
        self.assertEqual(out["tree_hash"], publishing.tree_hash(self.pub / LAB))
        self.assertTrue(os.access(self.pub / LAB / "01_demo.sh", os.X_OK))

    def test_replace_works_with_and_without_the_atomic_exchange(self):
        for exchange in (True, False):
            shutil.rmtree(self.pub / LAB); write_good(self.pub / LAB)
            base = publishing.tree_hash(self.pub / LAB)
            (self.src / "README.md").write_text(f"# exchange={exchange}\n")
            real = publishing._exchange
            with mock.patch.object(publishing, "_exchange", side_effect=(real if exchange else (lambda a, b: False))):
                publishing.publish_tree(self.pub, LAB, self.src, publishing.tree_hash(self.src), base, True)
            self.assertEqual((self.pub / LAB / "README.md").read_text(), f"# exchange={exchange}\n"); self.assertEqual(self.hidden(), [])

    def test_a_failed_second_rename_puts_the_previous_lab_back(self):
        (self.src / "README.md").write_text("# new\n"); calls = []
        real = os.rename
        def flaky(a, b):
            calls.append(1)
            if len(calls) == 2:
                raise OSError("boom")
            return real(a, b)
        with mock.patch.object(publishing, "_exchange", return_value=False), mock.patch.object(publishing.os, "rename", side_effect=flaky):
            with self.assertRaises(publishing.PublishError):
                self.go()
        self.assertEqual(self.tree(self.pub / LAB), self.tree(self.lab)); self.assertEqual(self.hidden(), [])

    def test_conflict_when_the_published_lab_changed_since_the_copy(self):
        base = publishing.tree_hash(self.lab)
        (self.lab / "README.md").write_text("# edited by someone else\n")
        with self.assertRaises(publishing.PublishError) as cm:
            self.go(base=base)
        self.assertEqual(cm.exception.status, 409); self.assertIn("conflict", str(cm.exception))
        self.assertEqual((self.lab / "README.md").read_text(), "# edited by someone else\n"); self.assertEqual(self.hidden(), [])

    def test_the_approved_hash_is_enforced_and_the_tree_is_validated_again(self):
        with self.assertRaises(publishing.PublishError) as cm:
            self.go(expected="0" * 64)
        self.assertIn("changed after approval", str(cm.exception))
        (self.src / "usecase.yaml").unlink()
        with self.assertRaises(publishing.PublishError) as cm:
            self.go()
        self.assertIn("no longer validates", str(cm.exception)); self.assertEqual(self.tree(self.pub / LAB), self.tree(self.lab))

    def test_symlinks_bad_names_and_missing_labs_are_refused(self):
        (self.src / "x").symlink_to("/etc/hosts")
        with self.assertRaises(publishing.PublishError):
            self.go()
        (self.src / "x").unlink()
        for bad in ("../x", "A", "a/b", "", None, "x" * 41):
            with self.assertRaises(publishing.PublishError) as cm:
                publishing.publish_tree(self.pub, bad, self.src, publishing.tree_hash(self.src), None, False)
            self.assertEqual(cm.exception.status, 400, bad)
        with self.assertRaises(publishing.PublishError):
            publishing.publish_tree(self.pub, "ghost-lab", self.src, publishing.tree_hash(self.src), "x" * 64, True)

    def test_an_unwritable_publish_directory_is_reported(self):
        with mock.patch.object(publishing.shutil, "copytree", side_effect=PermissionError("ro")):
            with self.assertRaises(publishing.PublishError) as cm:
                self.go("fresh-lab", replace=False)
        self.assertEqual(cm.exception.status, 500)


# ===================================================================== the publisher service
class PublisherService(Base):
    def setUp(self):
        super().setUp()
        self.state = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.state, True)
        tf = self.state / "token"; tf.write_text(TOKEN)
        self.cfg = builder.Config(env={"AI_BUILDER_ROOT": str(self.root), "AI_BUILDER_STATE_DIR": str(self.state / "s"), "AI_BUILDER_PUBLISH_DIR": str(self.root / "usecases"),
                                       "AI_BUILDER_TOKEN_FILE": str(tf), "AI_BUILDER_QUIET": "1", "AI_BUILDER_ALLOWED_HOSTS": "ai-publisher"}, root=self.root)
        (self.cfg.state / "workspaces" / "c-1").mkdir(parents=True)
        shutil.copytree(self.lab, self.cfg.state / "workspaces" / "c-1" / "work")
        self.src = self.cfg.state / "workspaces" / "c-1" / "work"
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), publisher.make_handler(self.cfg)); self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close); self.addCleanup(self.httpd.shutdown)

    def post(self, body, token=TOKEN, host="ai-publisher", path="/publish"):
        c = HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            h = {"Content-Type": "application/json", "Host": host}
            if token:
                h["Authorization"] = f"Bearer {token}"
            c.request("POST", path, body=json.dumps(body).encode() if not isinstance(body, bytes) else body, headers=h)
            r = c.getresponse(); return r.status, json.loads(r.read() or b"{}")
        finally:
            c.close()

    def body(self, **kw):
        return {"name": LAB, "source": "workspaces/c-1/work", "expected_hash": publishing.tree_hash(self.src), "base_hash": publishing.tree_hash(self.lab), "replace": True, **kw}

    def test_publishes_a_working_copy_and_replaces_the_lab(self):
        (self.src / "README.md").write_text("# via publisher\n")
        st, out = self.post(self.body(expected_hash=publishing.tree_hash(self.src)))
        self.assertEqual((st, out["published"]), (200, f"usecases/{LAB}")); self.assertEqual((self.lab / "README.md").read_text(), "# via publisher\n")

    def test_the_delete_route_moves_a_lab_to_the_trash_and_needs_the_same_gates(self):
        h = publishing.tree_hash(self.lab); lab = {"name": LAB, "expected_hash": h}
        self.assertEqual(self.post(lab, token=None, path="/delete")[0], 401); self.assertEqual(self.post(lab, host="evil.example", path="/delete")[0], 403)
        self.assertEqual(self.post({"name": LAB, "expected_hash": "0" * 64}, path="/delete")[0], 409); self.assertTrue(self.lab.is_dir())
        self.assertEqual(self.post({"name": "../x", "expected_hash": h}, path="/delete")[0], 400)
        st, out = self.post(lab, path="/delete"); self.assertEqual(st, 200); self.assertFalse(self.lab.exists()); self.assertTrue((self.root / out["trash"] / "usecase.yaml").is_file())
        self.assertEqual(self.post(lab, path="/delete")[0], 404, "a second request finds nothing")

    def test_token_and_host_are_required(self):
        self.assertEqual(self.post(self.body(), token=None)[0], 401); self.assertEqual(self.post(self.body(), token="x" * 64)[0], 401)
        self.assertEqual(self.post(self.body(), host="evil.example")[0], 403); self.assertEqual(self.post(self.body(), path="/other")[0], 404)
        self.assertEqual(self.tree(self.lab), self.tree(self.src))

    def test_the_source_must_be_a_draft_or_working_copy_inside_the_state_directory(self):
        outside = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, outside, True); shutil.copytree(self.lab, outside / "lab")
        (self.cfg.state / "evil").symlink_to(outside); (self.cfg.state / "workspaces" / "link").symlink_to(outside)
        for source in ("../etc", "/etc", "workspaces/../../x", "usecases/demo-lab", "", None, 5, "workspaces", "evil/lab", "workspaces/link/lab", "workspaces/c-1/../../../x"):
            st, _ = self.post(self.body(source=source)); self.assertIn(st, (400, 404), repr(source))
        self.assertEqual(self.post(self.body(source="drafts/none"))[0], 404)
        self.assertEqual(publishing.tree_hash(self.lab), publishing.tree_hash(self.src))

    def test_conflict_hash_mismatch_and_bad_json(self):
        base = publishing.tree_hash(self.lab)                                  # what the working copy was made from
        (self.lab / "README.md").write_text("# someone else\n")
        st, out = self.post(self.body(base_hash=base)); self.assertEqual(st, 409); self.assertIn("conflict", out["error"])
        self.assertEqual(self.post(self.body(expected_hash="0" * 64, base_hash=publishing.tree_hash(self.lab)))[0], 409)
        self.assertEqual(self.post(b"nope")[0], 400); self.assertEqual(self.post(b"[1]")[0], 400); self.assertEqual(self.post(b"x" * 5000)[0], 413)
        self.assertEqual((self.lab / "README.md").read_text(), "# someone else\n")

    def test_health_is_open_but_host_checked(self):
        c = HTTPConnection("127.0.0.1", self.port, timeout=5); c.request("GET", "/health", headers={"Host": "ai-publisher"}); self.assertEqual(c.getresponse().status, 200); c.close()
        c = HTTPConnection("127.0.0.1", self.port, timeout=5); c.request("GET", "/health", headers={"Host": "evil"}); self.assertEqual(c.getresponse().status, 403); c.close()

    def test_without_a_token_file_it_refuses_to_start(self):
        with mock.patch.dict(os.environ, {"AI_BUILDER_STATE_DIR": str(self.state / "x")}, clear=True):
            with self.assertRaises(SystemExit):
                publisher.main()


# ===================================================================== conversational editing
class EditingPermissions(Base):
    def test_a_question_keeps_the_read_only_tools_and_makes_no_working_copy(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.say(m, cid, "What does scenario 01 do?")
        args = self.calls[0]
        self.assertEqual(arg_after(args, "--output-format"), "json")
        self.assertEqual(next(a for a in args if a.startswith("--tools=")), "--tools=Read,Glob,Grep,WebSearch,WebFetch")
        self.assertEqual(next(a for a in args if a.startswith("--allowedTools=")), "--allowedTools=WebSearch,WebFetch", "no bare Read/Glob/Grep allow rule: reads are limited to the repository and this conversation's own working copies")
        deny = next(a for a in args if a.startswith("--disallowedTools=")).split("=", 1)[1].split(",")
        self.assertIn("Write", deny); self.assertIn("Edit", deny); self.assertFalse(any(a.startswith("--add-dir") for a in args))
        self.assertFalse((self.cfg.state / "workspaces").exists()); self.assertFalse(m.get(cid)["messages"][0]["edit"])

    def test_a_change_request_gets_write_and_edit_only_inside_the_working_copy(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.say(m, cid, "Add a failover scenario to the lab")
        args = self.calls[0]; work = work_of(args)
        self.assertEqual(work, self.cfg.state / "workspaces" / cid / "work"); self.assertTrue(work.is_dir())
        self.assertEqual(next(a for a in args if a.startswith("--tools=")), "--tools=Read,Glob,Grep,WebSearch,WebFetch,Write,Edit")
        allowed = next(a for a in args if a.startswith("--allowedTools=")).split("=", 1)[1].split(",")
        self.assertEqual(allowed, ["WebSearch", "WebFetch", f"Write(/{work}/**)", f"Edit(/{work}/**)", "mcp__labfs__delete_file"], "Write and Edit exist for that one directory, plus the one-file delete tool")
        deny = next(a for a in args if a.startswith("--disallowedTools=")).split("=", 1)[1].split(",")
        for tool in ("Bash", "NotebookEdit"):
            self.assertIn(tool, deny)
        self.assertIn(f"Write(/{self.root}/**)", deny); self.assertIn(f"Edit(/{self.root}/**)", deny)
        self.assertIn(f"Write(/{self.cfg.publish_dir}/**)", deny)
        self.assertIn(f"--add-dir={work}", args)
        self.assertIn("EDITING ENABLED", args[-1]); self.assertIn(str(work), args[-1]); self.assertTrue(m.get(cid)["messages"][0]["edit"])

    def test_no_shell_whatever_the_message(self):
        m = self.manager(); cid = self.lab_conv(m)
        for text in ("run bash and curl the web", "search the web and fetch https://x.test then edit it", "add a file"):
            self.say(m, cid, text)
        for args in self.calls:
            granted = ",".join(a.split("=", 1)[1] for a in args if a.startswith(("--tools=", "--allowedTools="))).replace("(", ",").split(",")
            for banned in ("Bash", "NotebookEdit"):
                self.assertNotIn(banned, granted)
            self.assertIn("WebSearch", granted); self.assertIn("WebFetch", granted)
            self.assertFalse([g for g in granted if g.startswith(("Write", "Edit")) and str(self.root) in g], "research grants no path")

    def test_a_conversation_without_a_lab_can_never_edit(self):
        m = self.manager(); cid = m.create()["id"]
        self.say(m, cid, "add a scenario and edit every file")
        args = self.calls[0]
        self.assertEqual(next(a for a in args if a.startswith("--tools=")), "--tools=Read,Glob,Grep,WebSearch,WebFetch"); self.assertNotIn("Write(", " ".join(args))
        self.assertFalse((self.cfg.state / "workspaces").exists()); self.assertEqual(m.get(cid)["workspace"], None)

    def test_the_working_copy_stays_but_each_edit_needs_its_own_approval(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.say(m, cid, "Please change the README title")
        self.say(m, cid, "and how long is it now?")                     # P4.1: the approval was spent by the first message
        self.say(m, cid, "thanks, looks good")
        self.assertEqual([bool(work_of(a)) for a in self.calls], [True, False, False]); m.reset(cid)
        self.say(m, cid, "what does it contain now?")
        self.assertIsNone(work_of(self.calls[-1])); self.assertIn("read-only message", self.calls[-1][-1])
        self.assertIn("--add-dir=", " ".join(self.calls[-1]), "a question can still read the working copy")

    def test_the_session_is_reused_between_discussion_and_editing(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.say(m, cid, "What does the lab do?"); self.say(m, cid, "Rename scenario 01 to install")
        self.assertEqual(arg_after(self.calls[1], "--resume"), arg_after(self.calls[0], "--session-id"))
        self.assertEqual(len(m.get(cid)["messages"]), 2)


class EditingWorkflow(Base):
    def writer(self, relpath="README.md", text="# Edited by Claude\n"):
        return lambda work: (work / relpath).write_text(text)

    def edit(self, m, cid, text="Please update the README", fn=None):
        self.script.append(fn or self.writer())
        return self.say(m, cid, text)

    def test_claude_edits_land_in_the_working_copy_and_the_published_lab_is_untouched(self):
        m = self.manager(); cid = self.lab_conv(m); published = self.tree(self.lab)
        view = self.edit(m, cid)
        self.assertEqual(self.tree(self.lab), published, "the published Lab never changes")
        self.assertEqual(view["messages"][0]["changed"], ["README.md"])
        self.assertEqual((view["workspace"]["exists"], view["workspace"]["editing"], view["workspace"]["changes"]["modified"], view["workspace"]["can_undo"]), (True, True, 1, True))

    def test_review_lists_files_diff_validation_and_the_approval_hash(self):
        (self.lab / "manifests" / "extra.yaml").write_text("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: extra\n")
        m = self.manager(); cid = self.lab_conv(m)
        self.edit(m, cid, fn=lambda w: ((w / "README.md").write_text("# New\n"), (w / "02_extra.sh").write_text((w / "01_demo.sh").read_text()), (w / "manifests" / "extra.yaml").unlink()))
        r = m.review(cid)
        self.assertEqual((r["changes"]["modified"], r["changes"]["added"], r["changes"]["deleted"], r["total"]), (["README.md"], ["02_extra.sh"], ["manifests/extra.yaml"], 3))
        self.assertTrue(any("+# New" in d["diff"] for d in r["diff"])); self.assertEqual(r["validation"], {"passed": True, "errors": []})
        self.assertEqual((r["conflict"], r["can_publish"], r["lab"]), (False, True, LAB)); self.assertEqual(r["tree_hash"], publishing.tree_hash(self.cfg.state / "workspaces" / cid / "work"))

    def test_an_invalid_result_is_reported_and_cannot_be_published(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.edit(m, cid, fn=lambda w: (w / "usecase.yaml").unlink())
        r = m.review(cid)
        self.assertFalse(r["validation"]["passed"]); self.assertFalse(r["can_publish"])
        with self.assertRaises(builder.RequestError) as cm:
            m.publish(cid, True, r["tree_hash"])
        self.assertEqual(cm.exception.status, 409); self.assertIn("does not validate", str(cm.exception)); self.assertIn("usecase.yaml", self.tree(self.lab))

    def test_undo_then_reset_and_discard(self):
        m = self.manager(); cid = self.lab_conv(m); published = self.tree(self.lab)
        self.edit(m, cid); self.edit(m, cid, "also change the scenario", fn=self.writer("01_demo.sh", "#!/usr/bin/env bash\n"))
        self.assertEqual(m.get(cid)["workspace"]["changes"]["modified"], 2)
        view = m.undo(cid); self.assertEqual(view["workspace"]["changes"]["modified"], 1)
        work = self.cfg.state / "workspaces" / cid / "work"
        self.assertEqual((work / "README.md").read_text(), "# Edited by Claude\n")
        view = m.reset(cid); self.assertEqual((view["workspace"]["changes"]["total"], view["workspace"]["can_undo"], view["workspace"]["editing"]), (0, False, False))
        self.assertEqual(self.tree(work), published)
        self.edit(m, cid, "change it again")
        view = m.discard(cid); self.assertEqual((view["workspace"]["exists"], view["workspace"]["editing"]), (False, False)); self.assertFalse(work.parent.exists())
        self.assertEqual(self.tree(self.lab), published)

    def test_claude_is_told_what_the_user_undid(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.edit(m, cid); m.undo(cid)
        self.say(m, cid, "what is the README now?")
        self.assertIn("undid your change from message 1", self.calls[-1][-1]); self.say(m, cid, "and now?"); self.assertNotIn("undid", self.calls[-1][-1])

    def test_the_actions_are_refused_without_a_working_copy_a_lab_or_while_answering(self):
        m = self.manager(); cid = self.lab_conv(m); free = m.create()["id"]
        for fn in (m.undo, m.reset, m.review):
            with self.assertRaises(builder.RequestError) as cm:
                fn(cid)
            self.assertEqual(cm.exception.status, 409, fn.__name__)
            with self.assertRaises(builder.RequestError) as cm:
                fn(free)
            self.assertEqual(cm.exception.status, 409); self.assertIn("not about a Lab", str(cm.exception))
            with self.assertRaises(builder.RequestError) as cm:
                fn("c-20200101-000000-aaaaaa")
            self.assertEqual(cm.exception.status, 404)
        with self.assertRaises(builder.RequestError):
            m.publish(cid, True, "x")
        m.convs[cid]["status"] = "running"
        for fn in (m.undo, m.reset, m.discard, m.review):
            with self.assertRaises(builder.RequestError) as cm:
                fn(cid)
            self.assertEqual(cm.exception.status, 409)

    def test_publish_needs_explicit_approval_of_the_reviewed_content(self):
        m = self.manager(); cid = self.lab_conv(m); self.edit(m, cid); r = m.review(cid); before = self.tree(self.lab)
        for approve in (None, False, "yes", 1):
            with self.assertRaises(builder.RequestError) as cm:
                m.publish(cid, approve, r["tree_hash"])
            self.assertEqual(cm.exception.status, 400)
        with self.assertRaises(builder.RequestError) as cm:
            m.publish(cid, True, "0" * 64)
        self.assertIn("changed since you reviewed", str(cm.exception)); self.assertEqual(self.tree(self.lab), before, "nothing is ever published automatically")
        self.edit(m, cid, "change more", fn=self.writer("README.md", "# changed after the review\n"))
        with self.assertRaises(builder.RequestError):
            m.publish(cid, True, r["tree_hash"])                       # the approval was for the earlier content
        self.assertEqual(self.tree(self.lab), before)

    def test_publication_replaces_the_lab_rebases_the_copy_and_the_conversation_continues(self):
        m = self.manager(); cid = self.lab_conv(m); self.edit(m, cid, fn=self.writer("README.md", "# Published text\n"))
        r = m.review(cid); out = m.publish(cid, True, r["tree_hash"])
        self.assertIn("published your changes", m.convs[cid]["notice"], "Claude is told on its next message")
        self.assertEqual((out["published"], out["changes"]["modified"], out["run"]), (f"usecases/{LAB}", 1, f"./playground usecase start {LAB}"))
        self.assertEqual((self.lab / "README.md").read_text(), "# Published text\n")
        self.assertEqual([p.name for p in (self.root / "usecases").iterdir() if p.name.startswith(".")], [])
        ws = out["conversation"]["workspace"]; self.assertEqual((ws["changes"]["total"], ws["can_undo"], ws["editing"], ws["conflict"], ws["publications"]), (0, False, False, False, 1))
        self.edit(m, cid, "now add another detail", fn=self.writer("README.md", "# Published text\nmore\n"))
        self.assertEqual(m.get(cid)["workspace"]["changes"]["modified"], 1); m.reset(cid)
        self.assertEqual((self.lab / "README.md").read_text(), "# Published text\n")

    def test_conflict_is_detected_when_the_published_lab_changed_after_the_copy(self):
        m = self.manager(); cid = self.lab_conv(m); self.edit(m, cid)
        self.assertFalse(m.get(cid)["workspace"]["conflict"])
        (self.lab / "README.md").write_text("# changed by someone else\n")
        self.assertTrue(m.get(cid)["workspace"]["conflict"])
        r = m.review(cid); self.assertTrue(r["conflict"]); self.assertFalse(r["can_publish"])
        with self.assertRaises(builder.RequestError) as cm:
            m.publish(cid, True, r["tree_hash"])
        self.assertEqual(cm.exception.status, 409); self.assertIn("conflict", str(cm.exception))
        self.assertEqual((self.lab / "README.md").read_text(), "# changed by someone else\n")
        m.discard(cid); self.edit(m, cid, "redo the change")              # a fresh copy starts from what is published now
        work = self.cfg.state / "workspaces" / cid / "work"; self.assertFalse(m.get(cid)["workspace"]["conflict"])
        self.assertEqual((work / "README.md").read_text(), "# Edited by Claude\n")

    def test_a_deleted_published_lab_is_a_conflict_not_a_crash(self):
        m = self.manager(); cid = self.lab_conv(m); self.edit(m, cid); shutil.rmtree(self.lab)
        self.assertTrue(m.get(cid)["workspace"]["conflict"]); r = m.review(cid); self.assertFalse(r["can_publish"])
        with self.assertRaises(builder.RequestError):
            m.publish(cid, True, r["tree_hash"])

    def test_publication_is_refused_while_a_generation_job_runs(self):
        busy = [True]; m = self.manager(jobs_busy=lambda: busy[0]); cid = self.lab_conv(m); self.edit(m, cid); r = m.review(cid)
        with self.assertRaises(builder.RequestError) as cm:
            m.publish(cid, True, r["tree_hash"])
        self.assertIn("generation job is running", str(cm.exception)); busy[0] = False; m.publish(cid, True, r["tree_hash"])

    def test_nothing_to_publish(self):
        m = self.manager(); cid = self.lab_conv(m); self.edit(m, cid, fn=lambda w: None)
        with self.assertRaises(builder.RequestError) as cm:
            m.publish(cid, True, m.review(cid)["tree_hash"])
        self.assertIn("no changes", str(cm.exception))

    def test_working_copy_and_session_survive_a_restart(self):
        m = self.manager(); cid = self.lab_conv(m); self.edit(m, cid)
        again = self.manager(); view = again.get(cid)
        self.assertEqual((view["workspace"]["exists"], view["workspace"]["changes"]["modified"], view["workspace"]["editing"], view["workspace"]["can_undo"]), (True, 1, True, True))
        self.assertEqual(view["messages"][0]["changed"], ["README.md"])
        again.undo(cid); self.assertEqual(again.get(cid)["workspace"]["changes"]["total"], 0)
        self.script.append(self.writer("README.md", "# after restart\n")); self.say(again, cid, "change it once more")
        self.assertEqual(arg_after(self.calls[-1], "--resume"), arg_after(self.calls[0], "--session-id"))
        self.assertEqual(again.get(cid)["workspace"]["changes"]["modified"], 1)

    def test_a_timed_out_edit_keeps_its_partial_changes_undoable(self):
        m = self.manager(); cid = self.lab_conv(m)
        def partial(args, cwd, timeout, env=None):
            self.calls.append(list(args)); (work_of(args) / "README.md").write_text("# half done\n"); return -9, "", "", True
        m.runner = partial; view = self.say(m, cid, "rewrite the README")
        self.assertEqual(view["messages"][0]["status"], "error"); self.assertTrue(view["workspace"]["can_undo"])
        self.assertEqual(m.undo(cid)["workspace"]["changes"]["total"], 0)

    def test_usage_and_cost_are_tracked_for_edit_turns_like_any_other(self):
        m = self.manager(); cid = self.lab_conv(m); self.script = [None]
        self.say(m, cid, "What is it?"); view = self.edit(m, cid, "change the README")
        self.assertEqual([t["cost_usd"] is not None for t in view["messages"]], [True, True]); self.assertEqual(view["usage"]["turns"], 2)

    def test_other_conversations_working_copies_are_separate(self):
        m = self.manager(); a, b = self.lab_conv(m), self.lab_conv(m)
        self.edit(m, a); self.assertEqual(m.get(b)["workspace"]["exists"], False)
        self.edit(m, b, fn=self.writer("README.md", "# B\n"))
        self.assertEqual((self.cfg.state / "workspaces" / a / "work" / "README.md").read_text(), "# Edited by Claude\n")
        self.assertEqual((self.cfg.state / "workspaces" / b / "work" / "README.md").read_text(), "# B\n")


class RemotePublication(Base):
    """Container deployment: the AI Builder has NO local write path to usecases/ and goes through the publisher service."""
    def setUp(self):
        super().setUp()
        self.keep = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.keep, True)
        (self.keep / "token").write_text(TOKEN)
        self.state = self.root / ".ai-builder"
        pcfg = builder.Config(env={"AI_BUILDER_ROOT": str(self.root), "AI_BUILDER_STATE_DIR": str(self.state), "AI_BUILDER_PUBLISH_DIR": str(self.root / "usecases"),
                                   "AI_BUILDER_TOKEN_FILE": str(self.keep / "token"), "AI_BUILDER_QUIET": "1", "AI_BUILDER_ALLOWED_HOSTS": "127.0.0.1"}, root=self.root)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), publisher.make_handler(pcfg)); self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close); self.addCleanup(self.httpd.shutdown)

    def remote_manager(self, port=None):
        env = {"AI_BUILDER_PUBLISHER_URL": f"http://127.0.0.1:{port or self.port}", "AI_BUILDER_TOKEN_FILE": str(self.keep / "token"),
               "AI_BUILDER_PUBLISH_DIR": str(self.keep / "not-writable-here")}
        return self.manager(env)

    def test_a_conversation_publishes_through_the_publisher(self):
        m = self.remote_manager(); cid = self.lab_conv(m)
        self.script.append(lambda w: (w / "README.md").write_text("# remote\n")); self.say(m, cid, "update the README")
        m.publish(cid, True, m.review(cid)["tree_hash"])
        self.assertEqual((self.lab / "README.md").read_text(), "# remote\n"); self.assertFalse((self.keep / "not-writable-here").exists(), "no local write path was used")

    def test_with_the_publisher_down_nothing_is_published_and_there_is_no_local_fallback(self):
        m = self.remote_manager(port=1); cid = self.lab_conv(m); before = self.tree(self.lab)
        self.script.append(lambda w: (w / "README.md").write_text("# nope\n")); self.say(m, cid, "update the README")
        with mock.patch.object(publishing, "publish_tree", side_effect=AssertionError("local publication must not happen")):
            with self.assertRaises(builder.RequestError) as cm:
                m.publish(cid, True, m.review(cid)["tree_hash"])
        self.assertEqual(cm.exception.status, 503); self.assertIn("publisher is not reachable", str(cm.exception)); self.assertEqual(self.tree(self.lab), before)
        self.assertEqual(m.get(cid)["workspace"]["changes"]["modified"], 1, "the working copy is kept")

    def test_the_publisher_conflict_answer_reaches_the_user(self):
        m = self.remote_manager(); cid = self.lab_conv(m)
        self.script.append(lambda w: (w / "README.md").write_text("# remote\n")); self.say(m, cid, "update the README"); r = m.review(cid)
        real = m._conflict; m._conflict = lambda conv, info, lab=None: False            # the local check passes, the publisher's own check must still catch it
        (self.lab / "README.md").write_text("# changed meanwhile\n")
        with self.assertRaises(builder.RequestError) as cm:
            m.publish(cid, True, r["tree_hash"])
        self.assertEqual(cm.exception.status, 409); self.assertIn("conflict", str(cm.exception)); self.assertEqual((self.lab / "README.md").read_text(), "# changed meanwhile\n")

    def test_a_generated_use_case_is_also_published_by_the_publisher(self):
        jm_cfg = builder.Config(env={"AI_BUILDER_PUBLISHER_URL": f"http://127.0.0.1:{self.port}", "AI_BUILDER_TOKEN_FILE": str(self.keep / "token")}, root=self.root)
        jm = builder.JobManager(jm_cfg, runner=lambda a, c, t: (write_good(self._draft(a)), (0, "", "", False))[1])
        req = {"name": "fresh-lab", "description": "Demonstrate something useful", "reference_usecase": "cnpg-standard"}
        job = jm.submit(req, background=False); jm.run(job["job_id"], req); jm.approve(job["job_id"])
        with mock.patch.object(publishing, "publish_tree", wraps=publishing.publish_tree) as p:
            out = jm.publish(job["job_id"])
        self.assertEqual(out["published"], "usecases/fresh-lab"); self.assertTrue((self.root / "usecases" / "fresh-lab" / "usecase.yaml").is_file())
        self.assertEqual(p.call_count, 1, "executed once, by the publisher service, never by the job manager itself")

    @staticmethod
    def _draft(args):
        from ai_builder_test import draft_from_args
        return draft_from_args(args)


class Http(Base):
    def setUp(self):
        super().setUp()
        self.cfg = builder.Config(env={"AI_BUILDER_CLAUDE": sys.executable, "AI_BUILDER_QUIET": "1"}, root=self.root)
        self.jobs = builder.JobManager(self.cfg, runner=lambda a, c, t: (0, "", "", False))
        self.convs = conversations.ConversationManager(self.cfg, runner=self.runner)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.jobs, self.cfg, "t", convs=self.convs)); self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close); self.addCleanup(self.httpd.shutdown)

    def call(self, method, path, body=None):
        c = HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            data = None if body is None else json.dumps(body).encode()
            c.request(method, path, body=data, headers={"Content-Type": "application/json"} if data is not None else {})
            r = c.getresponse(); raw = r.read(); return r.status, (json.loads(raw) if raw else {})
        finally:
            c.close()

    def test_review_undo_reset_discard_publish_over_http(self):
        cid = self.call("POST", "/conversations", {"lab": LAB})[1]["id"]
        self.script.append(lambda w: (w / "README.md").write_text("# http\n"))
        self.call("POST", f"/conversations/{cid}/context", {"action": "allow_edit"}); self.convs.send(cid, "update the README", background=False)
        st, r = self.call("GET", f"/conversations/{cid}/review"); self.assertEqual((st, r["changes"]["modified"], r["can_publish"]), (200, ["README.md"], True))
        self.assertEqual(self.call("POST", f"/conversations/{cid}/publish", {"approve": False, "tree_hash": r["tree_hash"]})[0], 400)
        self.assertEqual(self.call("POST", f"/conversations/{cid}/publish", {"tree_hash": r["tree_hash"]})[0], 400)
        self.assertEqual(self.call("POST", f"/conversations/{cid}/undo")[0], 200); self.assertEqual(self.call("POST", f"/conversations/{cid}/undo")[0], 409)
        self.assertEqual(self.call("POST", f"/conversations/{cid}/reset")[0], 200); self.assertEqual(self.call("POST", f"/conversations/{cid}/discard")[0], 200)
        self.script.append(lambda w: (w / "README.md").write_text("# http again\n")); self.call("POST", f"/conversations/{cid}/context", {"action": "allow_edit"}); self.convs.send(cid, "change the README again", background=False)
        r = self.call("GET", f"/conversations/{cid}/review")[1]
        st, out = self.call("POST", f"/conversations/{cid}/publish", {"approve": True, "tree_hash": r["tree_hash"]})
        self.assertEqual((st, out["published"]), (200, f"usecases/{LAB}")); self.assertEqual((self.lab / "README.md").read_text(), "# http again\n")

    def test_unknown_ids_and_routes(self):
        for method, path in (("GET", "/conversations/c-20200101-000000-aaaaaa/review"), ("POST", "/conversations/c-20200101-000000-aaaaaa/undo"),
                             ("POST", "/conversations/c-20200101-000000-aaaaaa/publish")):
            self.assertIn(self.call(method, path, {"approve": True} if "publish" in path else None)[0], (404,))
        self.assertEqual(self.call("POST", "/conversations/x/undo")[0], 404); self.assertEqual(self.call("POST", "/conversations/c-20200101-000000-aaaaaa/explode")[0], 404)

    def test_existing_routes_still_work(self):
        self.assertEqual(self.call("GET", "/health")[0], 200); self.assertEqual(self.call("POST", "/generate", {"name": "x"})[0], 400)
        self.assertEqual(self.call("GET", "/conversations")[0], 200)


# ===================================================================== deleting a conversation
class Deletion(Base):
    """DELETE of one conversation: its record, its Claude session files and its own working copy; nothing else."""
    def setUp(self):
        super().setUp()
        self.conf = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.conf, True)
        self.outside = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.outside, True)
        (self.outside / "precious.txt").write_text("keep me")

    def mgr(self, **kw):
        return self.manager({"CLAUDE_CONFIG_DIR": str(self.conf)}, **kw)

    def claude_files(self, sid, project="-workspace"):
        """What Claude Code leaves for a session (names only matter here)."""
        (self.conf / "projects" / project / sid).mkdir(parents=True, exist_ok=True)
        (self.conf / "projects" / project / sid / "tool-result.txt").write_text("x")
        (self.conf / "projects" / project / f"{sid}.jsonl").write_text("{}\n")
        (self.conf / "session-env" / sid).mkdir(parents=True, exist_ok=True)
        return [self.conf / "projects" / project / f"{sid}.jsonl", self.conf / "projects" / project / sid, self.conf / "session-env" / sid]

    def sid_of(self, m, cid):
        return json.loads((self.cfg.state / "conversations" / f"{cid}.json").read_text())["session_id"]

    def edit(self, m, cid, text="Please update the README"):
        self.script.append(lambda w: (w / "README.md").write_text("# Edited\n")); m.set_context(cid, "allow_edit"); m.send(cid, text, background=False)

    def test_one_conversation_goes_with_its_sessions_and_working_copy_and_nothing_else_does(self):
        m = self.mgr(); a, b = self.lab_conv(m), self.lab_conv(m); published = self.tree(self.lab)
        self.edit(m, a); self.edit(m, b)
        ca, cb = self.claude_files(self.sid_of(m, a)), self.claude_files(self.sid_of(m, b))
        other = self.claude_files("11111111-2222-4333-8444-555555555555", project="-other"); (self.conf / "projects" / "-workspace" / "unrelated.jsonl").write_text("{}")
        ws_a, ws_b = self.cfg.state / "workspaces" / a, self.cfg.state / "workspaces" / b; b_tree = self.tree(ws_b)
        out = m.delete(a)
        self.assertEqual((out["deleted"], out["workspace_removed"], out["sessions_removed"], out["warnings"]), (a, True, 3, []))
        self.assertFalse((self.cfg.state / "conversations" / f"{a}.json").exists()); self.assertFalse(ws_a.exists())
        self.assertTrue(all(not p.exists() for p in ca), "its Claude session files are gone")
        self.assertTrue(all(p.exists() for p in cb + other), "other sessions are untouched"); self.assertTrue((self.conf / "projects" / "-workspace" / "unrelated.jsonl").exists())
        self.assertEqual(self.tree(ws_b), b_tree); self.assertEqual([c["id"] for c in m.list()], [b]); self.assertIsNone(m.get(a))
        self.assertEqual(m.get(b)["workspace"]["changes"]["modified"], 1, "the other working copy still works")
        self.assertEqual(self.tree(self.lab), published, "published Labs are never touched")
        self.assertEqual(self.mgr().get(a), None, "and it stays deleted after a restart")

    def test_a_conversation_with_nothing_else_to_clean_up(self):
        m = self.mgr(); cid = m.create()["id"]; m.convs[cid]["turns"] = []
        out = m.delete(cid)
        self.assertEqual((out["workspace_removed"], out["sessions_removed"]), (False, 0)); self.assertEqual(m.list(), [])

    def test_a_missing_or_malformed_id_is_a_404_and_nothing_outside_is_reached(self):
        m = self.mgr(); keep = self.cfg.state / "secret.json"; keep.write_text("{}"); published = self.tree(self.lab); cid = self.lab_conv(m)
        for bad in ("c-20200101-000000-aaaaaa", "../secret", "../../etc", "", None, 5, f"{cid}/../..", f"{cid}/", "C-20200101-000000-AAAAAA", cid + "x"):
            with self.assertRaises(builder.RequestError) as cm:
                m.delete(bad)
            self.assertEqual(cm.exception.status, 404, repr(bad))
        self.assertTrue(keep.exists()); self.assertEqual(self.tree(self.lab), published); self.assertIsNotNone(m.get(cid)); self.assertTrue((self.outside / "precious.txt").exists())
        m.delete(cid)
        with self.assertRaises(builder.RequestError) as cm:
            m.delete(cid)
        self.assertEqual(cm.exception.status, 404, "a second deletion finds nothing")

    def test_it_is_refused_while_claude_is_answering_and_nothing_is_removed(self):
        m = self.mgr(); cid = self.lab_conv(m); self.edit(m, cid); files = self.claude_files(self.sid_of(m, cid)); ws = self.cfg.state / "workspaces" / cid
        m.convs[cid]["status"] = "running"
        with self.assertRaises(builder.RequestError) as cm:
            m.delete(cid)
        self.assertEqual(cm.exception.status, 409); self.assertIn("still answering", str(cm.exception))
        self.assertTrue(ws.is_dir() and all(p.exists() for p in files) and (self.cfg.state / "conversations" / f"{cid}.json").exists() and m.get(cid))
        m.convs[cid]["status"] = "idle"; m.delete(cid); self.assertFalse(ws.exists())

    def test_a_turn_really_in_flight_blocks_the_deletion_until_it_ends(self):
        m = self.mgr(); cid = self.lab_conv(m); self.gate = threading.Event()
        m.send(cid, "What does the lab do?")
        with self.assertRaises(builder.RequestError) as cm:
            m.delete(cid)
        self.assertEqual(cm.exception.status, 409); self.assertIsNotNone(m.get(cid))
        self.gate.set()
        for _ in range(100):
            if not m.busy():
                break
            time.sleep(0.05)
        self.assertEqual(m.delete(cid)["deleted"], cid)

    def test_symbolic_links_are_removed_never_followed(self):
        m = self.mgr(); cid = self.lab_conv(m); self.edit(m, cid); sid = self.sid_of(m, cid); published = self.tree(self.lab)
        ws = self.cfg.state / "workspaces" / cid; shutil.rmtree(ws); ws.symlink_to(self.lab)                 # a working copy that points at the PUBLISHED Lab
        link = self.conf / "projects" / "-workspace"; link.mkdir(parents=True); (link / f"{sid}.jsonl").symlink_to(self.outside / "precious.txt")
        (self.conf / "session-env").mkdir(parents=True); (self.conf / "session-env" / sid).symlink_to(self.outside)
        m.delete(cid)
        self.assertFalse(ws.is_symlink() or ws.exists()); self.assertEqual(self.tree(self.lab), published, "the published Lab is intact")
        self.assertEqual((self.outside / "precious.txt").read_text(), "keep me"); self.assertFalse((link / f"{sid}.jsonl").is_symlink() or (link / f"{sid}.jsonl").exists())
        self.assertTrue(self.outside.is_dir() and not (self.conf / "session-env" / sid).is_symlink())

    def test_only_session_ids_that_look_like_uuids_are_ever_used(self):
        m = self.mgr(); cid = self.lab_conv(m); self.edit(m, cid)
        victim = self.conf / "projects" / "victim.jsonl"; victim.parent.mkdir(parents=True, exist_ok=True); victim.write_text("keep"); (self.conf / "session-env").mkdir(exist_ok=True)
        f = self.cfg.state / "conversations" / f"{cid}.json"; rec = json.loads(f.read_text())
        rec["sessions"] += [{"id": "../victim", "turns": 1}, {"id": "*", "turns": 1}, {"id": "../../session-env", "turns": 1}, {"id": 7, "turns": 1}]; rec["session_id"] = "../victim"
        f.write_text(json.dumps(rec))
        again = self.mgr(); self.assertEqual(again.delete(cid)["deleted"], cid)
        self.assertEqual(victim.read_text(), "keep"); self.assertTrue((self.conf / "session-env").is_dir())

    def test_without_a_configured_claude_directory_nothing_is_guessed_outside_the_home_one(self):
        m = self.manager(); cid = self.lab_conv(m)
        with mock.patch.object(conversations.Path, "home", return_value=self.outside):
            self.assertEqual(m.delete(cid)["sessions_removed"], 0)
        self.assertTrue((self.outside / "precious.txt").exists())

    def test_deleting_does_not_disturb_a_running_conversation_elsewhere(self):
        m = self.mgr(); a, b = self.lab_conv(m), self.lab_conv(m); self.gate = threading.Event(); m.send(b, "slow question")
        m.delete(a); self.assertEqual(m.get(b)["status"], "running"); self.gate.set()
        for _ in range(100):
            if not m.busy():
                break
            time.sleep(0.05)
        self.assertEqual(len(m.get(b)["messages"]), 1)


class DeleteOverHttp(Base):
    def setUp(self):
        super().setUp()
        self.keep = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.keep, True); (self.keep / "token").write_text(TOKEN)
        self.cfg = builder.Config(env={"AI_BUILDER_CLAUDE": sys.executable, "AI_BUILDER_QUIET": "1", "AI_BUILDER_TOKEN_FILE": str(self.keep / "token")}, root=self.root)
        self.jobs = builder.JobManager(self.cfg, runner=lambda a, c, t: (0, "", "", False))
        self.convs = conversations.ConversationManager(self.cfg, runner=self.runner)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.jobs, self.cfg, "t", convs=self.convs)); self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close); self.addCleanup(self.httpd.shutdown)

    def call(self, method, path, token=TOKEN, host="127.0.0.1"):
        c = HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            headers = {"Host": host}
            if token:
                headers["Authorization"] = f"Bearer {token}"
            c.request(method, path, headers=headers); r = c.getresponse(); raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
        finally:
            c.close()

    def test_delete_route_end_to_end(self):
        cid = self.convs.create("t", LAB)["id"]; published = self.tree(self.lab)
        st, out = self.call("DELETE", f"/conversations/{cid}")
        self.assertEqual((st, out["deleted"]), (200, cid))
        self.assertEqual(self.call("GET", f"/conversations/{cid}")[0], 404); self.assertEqual(self.call("DELETE", f"/conversations/{cid}")[0], 404)
        self.assertEqual(self.call("GET", "/conversations")[1]["conversations"], []); self.assertEqual(self.tree(self.lab), published)

    def test_it_needs_the_token_and_a_known_host(self):
        cid = self.convs.create()["id"]
        for token in (None, "x" * 64, "short"):
            self.assertEqual(self.call("DELETE", f"/conversations/{cid}", token=token)[0], 401)
        self.assertEqual(self.call("DELETE", f"/conversations/{cid}", host="evil.example")[0], 403)
        self.assertIsNotNone(self.convs.get(cid), "still there")

    def test_a_running_conversation_gives_409_and_other_paths_are_not_deletable(self):
        cid = self.convs.create()["id"]; self.convs.convs[cid]["status"] = "running"
        st, out = self.call("DELETE", f"/conversations/{cid}"); self.assertEqual(st, 409); self.assertIn("still answering", out["error"]); self.assertIsNotNone(self.convs.get(cid))
        for path in ("/conversations", "/conversations/", f"/conversations/{cid}/messages", f"/conversations/{cid}/review", "/status/x", "/health", "/conversations/..%2fsecret", "/conversations/x"):
            self.assertIn(self.call("DELETE", path)[0], (404,), path)
        self.assertEqual(self.call("DELETE", "/generate")[0], 404)




# ===================================================================== Lab context (P3.1b)
class LabContext(Base):
    def other(self):
        shutil.copytree(self.root / "usecases" / LAB, self.root / "usecases" / "other-lab")

    def test_a_change_request_alone_never_enables_editing(self):
        m = self.manager(); cid = m.create("x", LAB)["id"]
        m.send(cid, "Add a failover scenario", background=False)
        self.assertFalse(m.get(cid)["messages"][0]["edit"]); self.assertFalse((self.cfg.state / "workspaces").exists())
        self.assertNotIn("[[context: edit]]", self.calls[0][-1], "the per-message note no longer primes the directive"); self.assertNotIn("Write(", " ".join(self.calls[0]))
        prompt = arg_after(self.calls[0], "--append-system-prompt"); self.assertIn("are answers", prompt); self.assertIn("only when the user's latest message orders files to be modified now", prompt)
        m.set_context(cid, "allow_edit"); self.script.append(self.writer_ok())
        m.send(cid, "Add a failover scenario", background=False)
        self.assertTrue(m.get(cid)["messages"][1]["edit"]); self.assertIn("EDITING ENABLED", self.calls[1][-1])

    def writer_ok(self):
        return lambda work: (work / "README.md").write_text("# x\n")

    def test_a_named_lab_is_focused_read_only_and_the_skill_is_told_once(self):
        m = self.manager(); cid = m.create()["id"]
        m.send(cid, f"What does {LAB} install?", background=False); v = m.get(cid)
        self.assertEqual((v["lab"], v["lab_active"], v["edit_approved"], v["labs"]), (LAB, True, False, [{"name": LAB, "active": True}]))
        self.assertIn(f"Lab '{LAB}' in focus", self.calls[0][-1]); self.assertIn("SKILL", self.calls[0][-1].upper())
        self.assertNotIn("Write(", " ".join(self.calls[0]))
        m.send(cid, "and the scenarios?", background=False)
        self.assertIn(f"Lab '{LAB}' in focus", self.calls[1][-1]); self.assertNotIn("Lab work begins", self.calls[1][-1])
        self.assertEqual(arg_after(self.calls[1], "--resume"), arg_after(self.calls[0], "--session-id"))

    def test_a_name_that_is_not_a_lab_or_a_negation_attaches_nothing(self):
        m = self.manager(); cid = m.create()["id"]
        m.send(cid, "tell me about demo-labs and nothing", background=False); self.assertIsNone(m.get(cid)["lab"])
        m.send(cid, f"forget {LAB}", background=False); self.assertIsNone(m.get(cid)["lab"])

    def test_deactivate_and_detach_deny_reading_the_lab_and_keep_the_session(self):
        m = self.manager(); cid = self.lab_conv(m); self.other()
        m.send(cid, "hello", background=False)
        m.set_context(cid, "deactivate"); v = m.get(cid); self.assertEqual((v["lab"], v["lab_active"], v["read_only"]), (LAB, False, True))
        m.send(cid, "general question", background=False); args = self.calls[-1]
        deny = next(a for a in args if a.startswith("--disallowedTools="))
        self.assertIn(f"Read(/{self.root}/usecases/{LAB}/**)", deny); self.assertIn("no Lab in focus", args[-1])
        self.assertEqual(arg_after(args, "--resume"), arg_after(self.calls[0], "--session-id"))
        m.set_context(cid, "activate"); m.send(cid, "back", background=False)
        self.assertNotIn(f"Read(/{self.root}/usecases/{LAB}/**)", next(a for a in self.calls[-1] if a.startswith("--disallowedTools=")))
        m.set_context(cid, "detach"); self.assertEqual((m.get(cid)["lab"], m.get(cid)["labs"]), (None, []))
        m.send(cid, "free", background=False)
        self.assertIn(f"Read(/{self.root}/usecases/{LAB}/**)", next(a for a in self.calls[-1] if a.startswith("--disallowedTools=")))
        m.set_context(cid, "focus", "other-lab"); self.assertEqual(m.get(cid)["lab"], "other-lab")
        with self.assertRaises(builder.RequestError) as e: m.set_context(cid, "focus", "no-such-lab")
        self.assertEqual(e.exception.status, 404)

    def test_detach_is_refused_when_changes_would_be_lost_and_context_is_refused_while_answering(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.script.append(self.writer_ok()); self.say(m, cid, "Please update the README")
        for action in ("detach",):
            with self.assertRaises(builder.RequestError) as e: m.set_context(cid, action)
            self.assertEqual(e.exception.status, 409); self.assertIn("unpublished changes", str(e.exception))
        with self.assertRaises(builder.RequestError): m.set_context(cid, "focus", "no-such")
        m.set_context(cid, "deactivate"); v = m.get(cid)                       # changes are kept, only the Lab is inactive
        self.assertEqual((v["workspace"]["changes"]["total"], v["edit_approved"]), (1, False))
        m.convs[cid]["status"] = "running"
        with self.assertRaises(builder.RequestError) as e: m.set_context(cid, "activate")
        self.assertEqual(e.exception.status, 409)

    def test_claude_directive_is_stripped_and_applied_with_the_same_checks(self):
        m = self.manager(); cid = m.create()["id"]; self.other()
        self.reply = f"Done.\n[[context: focus other-lab]]"
        m.send(cid, "please look at that other one", background=False); v = m.get(cid)
        self.assertEqual(v["lab"], "other-lab"); self.assertEqual(v["messages"][0]["assistant"], "Done.")
        self.reply = "[[context: detach]]"
        m.send(cid, "stop", background=False); self.assertIsNone(m.get(cid)["lab"]); self.assertEqual(m.get(cid)["messages"][1]["status"], "ok")

    def test_only_the_trailing_directive_block_is_applied_and_hidden(self):
        m = self.manager(); cid = m.create()["id"]; self.other()
        self.reply = "Before `[[context: detach]]` and **[[context: detach]]** after.\n\n[[context: focus other-lab]]\nMore text."
        m.send(cid, "hello", background=False); v = m.get(cid)                      # a directive followed by text is not a trailing block
        self.assertIsNone(v["lab"]); self.assertIn("[[context: focus other-lab]]", v["messages"][0]["assistant"])
        self.reply = "Looking at it.\n\n  **[[context: focus other-lab]]**  \n"
        m.send(cid, "look at other-lab", background=False); v = m.get(cid)
        self.assertEqual(v["lab"], "other-lab"); self.assertEqual(v["messages"][1]["assistant"], "Looking at it.")

    def test_an_edit_request_directive_only_shows_the_card_and_enables_nothing(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.reply = "I would rewrite the README title.\n[[context: edit]]"
        m.send(cid, "Rewrite the README title", background=False); v = m.get(cid)
        self.assertEqual((v["messages"][0]["edit_request"], v["messages"][0]["edit"], v["edit_approved"]), (True, False, False))
        self.assertNotIn("[[", v["messages"][0]["assistant"]); self.assertFalse((self.cfg.state / "workspaces").exists())

    def test_rename_and_archive_keep_the_id_the_session_and_the_order(self):
        m = self.manager(); a = m.create("first")["id"]; b = m.create("second")["id"]; m.send(a, "hello", background=False)
        sid = m.convs[a]["session_id"]; updated = m.convs[a]["updated"]
        v = m.update(a, title="  Renamed  "); self.assertEqual((v["id"], v["title"]), (a, "Renamed"))
        v = m.update(a, archived=True); self.assertEqual(m.convs[a]["session_id"], sid); self.assertEqual(m.convs[a]["updated"], updated)
        self.assertEqual({r["id"]: r["archived"] for r in m.list()}, {a: True, b: False})
        for bad in ({"title": ""}, {"title": "x" * 200}, {"archived": "yes"}, {}):
            with self.assertRaises(builder.RequestError): m.update(a, **bad)
        with self.assertRaises(builder.RequestError) as e: m.update("c-20200101-000000-aaaaaa", title="x")
        self.assertEqual(e.exception.status, 404)
        m.update(a, archived=False); self.assertFalse(m.list()[0]["archived"] and m.list()[1]["archived"])

    def test_a_session_from_before_the_workflow_change_is_told_once_that_the_context_menu_is_gone(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.assertEqual(m.convs[cid]["prompt_rev"], conversations.PROMPT_REV)       # new conversations: the system prompt is current
        m.send(cid, "hello", background=False); self.assertNotIn("Context menu", self.calls[-1][-1])
        del m.convs[cid]["prompt_rev"]                                                 # an older conversation record
        m.send(cid, "again", background=False); self.assertIn("Context menu", self.calls[-1][-1]); self.assertIn("Rules update", self.calls[-1][-1])
        self.assertEqual(arg_after(self.calls[-1], "--resume"), arg_after(self.calls[0], "--session-id"))
        m.send(cid, "third", background=False); self.assertNotIn("Rules update", self.calls[-1][-1])

    def test_a_cancelled_approval_request_is_forgotten_by_the_server(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.reply = "Proposal.\n[[context: edit]]"; m.send(cid, "Fix scenario 07", background=False)
        self.assertTrue(m.get(cid)["messages"][0]["edit_request"])
        v = m.set_context(cid, "decline_edit"); self.assertFalse(v["messages"][0]["edit_request"]); self.assertFalse(v["edit_approved"])
        self.assertFalse(m.get(cid)["messages"][0]["edit_request"], "persisted: a reload does not bring the card back")

    # --- P3.1c: conversational Lab creation ---------------------------------------------------------------------------------
    def test_a_lab_is_created_from_the_conversation_reviewed_published_and_improved_in_the_same_conversation(self):
        from ai_builder_test import write_good
        m = self.manager(); cid = m.create()["id"]; new = self.root / "usecases" / "clickhouse-demo"
        m.send(cid, "Let's discuss a ClickHouse operator Lab", background=False)
        self.reply = "Plan: operator, 2 scenarios.\n[[context: create clickhouse-demo]]"
        m.send(cid, "Create a Lab based on our discussion", background=False); v = m.get(cid)
        self.assertEqual(v["messages"][1]["create_request"], "clickhouse-demo"); self.assertNotIn("[[", v["messages"][1]["assistant"])
        self.assertFalse((self.cfg.state / "workspaces").exists(), "no file before approval"); self.assertFalse(new.exists())
        self.assertNotIn("Write(", " ".join(self.calls[-1]))
        v = m.set_context(cid, "create_lab", "clickhouse-demo")                       # the user clicked Create Lab
        self.assertEqual((v["lab"], v["edit_approved"], v["workspace"]["exists"], v["workspace"]["changes"]["total"], v["messages"][1]["create_request"]), ("clickhouse-demo", True, True, 0, None))
        self.script.append(lambda work: write_good(work)); self.reply = "Created."
        m.send(cid, "Lab creation approved: create it", background=False); args = self.calls[-1]; work = work_of(args)
        self.assertIn(f"Write(/{work}/**)", " ".join(args)); self.assertIn("does not exist yet", args[-1]); self.assertFalse(new.exists(), "nothing is published automatically")
        self.assertEqual(arg_after(args, "--resume"), arg_after(self.calls[0], "--session-id"), "same Claude session")
        r = m.review(cid); self.assertTrue(r["validation"]["passed"], r["validation"]); self.assertEqual((r["changes"]["added"] != [], r["conflict"], r["can_publish"]), (True, False, True))
        out = m.publish(cid, True, r["tree_hash"]); self.assertTrue((new / "usecase.yaml").is_file()); self.assertEqual(out["published"], "usecases/clickhouse-demo")
        v = out["conversation"]; self.assertEqual((v["lab"], v["workspace"]["changes"]["total"], v["workspace"]["conflict"]), ("clickhouse-demo", 0, False)); self.assertNotIn("new_lab", m.convs[cid])
        self.script.append(lambda w: (w / "README.md").write_text("# Improved\n")); self.say(m, cid, "Update the README")
        r = m.review(cid); m.publish(cid, True, r["tree_hash"]); self.assertEqual((new / "README.md").read_text(), "# Improved\n")

    def test_creation_rejects_bad_taken_and_busy_names_and_never_touches_other_labs(self):
        m = self.manager(); cid = m.create()["id"]; other = m.create()["id"]; before = self.tree(self.lab)
        for bad in ("Bad_Name", "", None, "x" * 41):
            with self.assertRaises(builder.RequestError) as e: m.set_context(cid, "create_lab", bad)
            self.assertEqual(e.exception.status, 400)
        with self.assertRaises(builder.RequestError) as e: m.set_context(cid, "create_lab", LAB)
        self.assertEqual(e.exception.status, 409)
        m.set_context(other, "create_lab", "fresh-lab")
        with self.assertRaises(builder.RequestError) as e: m.set_context(cid, "create_lab", "fresh-lab")
        self.assertEqual(e.exception.status, 409, "another conversation already holds that name")
        m.convs[cid]["status"] = "running"
        with self.assertRaises(builder.RequestError) as e: m.set_context(cid, "create_lab", "another-lab")
        self.assertEqual(e.exception.status, 409); m.convs[cid]["status"] = "idle"
        self.reply = "[[context: create cnpg-standard]]"; m.send(cid, "create a lab", background=False)
        self.assertIsNone(m.get(cid)["messages"][0].get("create_request")); self.assertIn("No Lab was proposed", m.get(cid)["messages"][0]["assistant"])
        self.assertEqual(self.tree(self.lab), before)

    def test_creating_from_a_lab_conversation_keeps_that_lab_readable_but_refuses_to_lose_its_changes(self):
        m = self.manager(); cid = self.lab_conv(m); self.script.append(self.writer_ok()); self.say(m, cid, "Please update the README")   # unpublished changes
        with self.assertRaises(builder.RequestError) as e: m.set_context(cid, "create_lab", "second-lab")
        self.assertIn("unpublished changes", str(e.exception)); self.assertEqual(m.get(cid)["lab"], LAB)
        m.reset(cid); m.set_context(cid, "create_lab", "second-lab"); v = m.get(cid)
        self.assertEqual((v["lab"], v["workspace"]["exists"]), ("second-lab", True)); self.assertNotIn(LAB, m.convs[cid]["released"])
        self.assertEqual(m.convs[cid]["turns"][-1].get("create_request"), None)

    def test_declining_a_creation_card_forgets_it(self):
        m = self.manager(); cid = m.create()["id"]
        self.reply = "Plan.\n[[context: create nice-lab]]"; m.send(cid, "Create a lab", background=False)
        self.assertEqual(m.get(cid)["messages"][0]["create_request"], "nice-lab")
        v = m.set_context(cid, "decline_edit"); self.assertIsNone(v["messages"][0]["create_request"]); self.assertFalse((self.cfg.state / "workspaces").exists())

    # --- P3.2a: several Labs in one conversation, read-only ---------------------------------------------------------------------
    def labs3(self):
        for n in ("pgd-lab", "third-lab"):
            shutil.copytree(self.root / "usecases" / LAB, self.root / "usecases" / n)

    def denied(self, args):
        return next(a for a in args if a.startswith("--disallowedTools=")).split("=", 1)[1].split(",")

    def test_naming_two_labs_puts_both_in_a_read_only_context_with_isolation_by_deny_rules(self):
        self.labs3(); m = self.manager(); cid = m.create()["id"]
        m.send(cid, f"Compare {LAB} and pgd-lab: architecture and scenarios", background=False); v = m.get(cid); args = self.calls[-1]
        self.assertEqual((v["lab"], [l["name"] for l in v["labs"]]), (LAB, [LAB, "pgd-lab"]))
        note = args[-1]; self.assertIn(f"Lab '{LAB}' in focus", note); self.assertIn("usecases/pgd-lab/", note); self.assertIn("SKILL", note.upper())
        d = self.denied(args); self.assertIn(f"Read(/{self.root}/usecases/third-lab/**)", d, "a Lab outside the context is denied by rule")
        self.assertNotIn(f"Read(/{self.root}/usecases/pgd-lab/**)", d); self.assertNotIn(f"Read(/{self.root}/usecases/{LAB}/**)", d)
        self.assertNotIn("Write(", " ".join(args)); self.assertIn("Write", d); self.assertIn("Edit", d); self.assertIn("Bash", d)
        self.assertIn("WebSearch", next(a for a in args if a.startswith("--tools=")), "web research stays available")
        with self.assertRaises(builder.RequestError) as e: m.set_context(cid, "allow_edit")
        self.assertEqual(e.exception.status, 409); self.assertFalse(m.get(cid)["messages"][0]["edit"])
        self.assertEqual(arg_after(args, "--session-id"), m.convs[cid]["session_id"])

    def test_detach_one_lab_focus_only_and_general_discussion_change_the_set_and_the_deny_rules(self):
        self.labs3(); m = self.manager(); cid = m.create()["id"]
        m.send(cid, f"Compare {LAB} with pgd-lab and third-lab", background=False)
        self.assertEqual([l["name"] for l in m.get(cid)["labs"]], [LAB, "pgd-lab", "third-lab"])
        self.reply = "OK\n[[context: detach pgd-lab]]"; m.send(cid, "forget pgd-lab please", background=False)
        self.assertEqual([l["name"] for l in m.get(cid)["labs"]], [LAB, "third-lab"])
        m.send(cid, "and now?", background=False); d = self.denied(self.calls[-1]); self.assertIn(f"Read(/{self.root}/usecases/pgd-lab/**)", d)
        self.assertEqual(arg_after(self.calls[-1], "--resume"), arg_after(self.calls[0], "--session-id"))
        self.reply = "[[context: focus third-lab]]"; m.send(cid, "focus only on third-lab", background=False)
        v = m.get(cid); self.assertEqual((v["lab"], [l["name"] for l in v["labs"]]), ("third-lab", ["third-lab"])); self.assertIn(LAB, m.convs[cid]["released"])
        m.set_context(cid, "add", LAB); m.set_context(cid, "detach", "third-lab")       # detaching the primary promotes the next Lab (still read-only)
        self.assertEqual(([l["name"] for l in m.get(cid)["labs"]], m.get(cid)["lab"]), ([LAB], LAB))
        m.set_context(cid, "add", "pgd-lab"); self.reply = "[[context: general]]"; m.send(cid, "back to general discussion", background=False)
        v = m.get(cid); self.assertEqual(v["labs"][0]["active"], False); self.assertEqual(len(v["labs"]), 1)
        self.assertEqual({LAB, "pgd-lab"} <= set(m.convs[cid]["released"]), True)
        with self.assertRaises(builder.RequestError) as e: m.set_context(cid, "detach", "ghost-lab")
        self.assertEqual(e.exception.status, 409)

    def test_editing_is_never_interrupted_by_a_mention_and_old_records_migrate(self):
        self.labs3(); m = self.manager(); cid = self.lab_conv(m); self.script.append(self.writer_ok()); self.say(m, cid, "Please update the README")
        m.send(cid, "use the same approach as pgd-lab", background=False)
        self.assertFalse(m.get(cid)["messages"][-1]["edit"], "one-shot: the second message is read-only, so the mention adds the Lab read-only")
        m.set_context(cid, "add", "pgd-lab")                                            # explicit: read-only set, editing off, changes kept
        v = m.get(cid); self.assertEqual((v["edit_approved"], v["workspace"]["changes"]["total"]), (False, 1))
        m.send(cid, "compare", background=False); self.assertFalse(m.get(cid)["messages"][-1]["edit"]); self.assertNotIn("Write(", " ".join(self.calls[-1]))
        old = m.convs[cid]; old.pop("labs"); m._save(old)                               # a record written before multi-Lab context
        m2 = self.manager(); v2 = m2.get(cid); self.assertEqual([l["name"] for l in v2["labs"]], [LAB]); self.assertEqual(len(v2["messages"]), len(old["turns"]))

    # --- P3.2b: several Labs edited in one conversation, each in its own working copy ---------------------------------------------
    def writes(self, text):
        return lambda work: (work / "README.md").write_text(text)

    def two(self):
        self.labs3(); m = self.manager(); cid = m.create()["id"]
        m.send(cid, f"Compare {LAB} and pgd-lab", background=False); return m, cid

    def test_one_card_names_every_affected_lab_and_nothing_is_written_before_approval(self):
        m, cid = self.two()
        self.reply = "For both Labs I would add monitoring.\n[[context: edit demo-lab]]\n[[context: edit pgd-lab]]"
        m.send(cid, "Apply the same monitoring improvements to both", background=False); v = m.get(cid); t = v["messages"][-1]
        self.assertEqual((t["edit_request"], t["edit_labs"]), (True, [LAB, "pgd-lab"])); self.assertNotIn("[[", t["assistant"])
        self.assertFalse((self.cfg.state / "workspaces").exists(), "no working copy and no write permission before approval"); self.assertNotIn("Write(", " ".join(self.calls[-1]))
        for bad in (["ghost-lab"], [], "pgd-lab", [LAB, LAB]):
            with self.assertRaises(builder.RequestError): m.set_context(cid, "allow_edit", None, bad)
        self.assertFalse(m.get(cid)["edit_approved"])

    def test_approved_labs_are_edited_in_their_own_copies_and_nothing_else_is_writable(self):
        m, cid = self.two(); pub = {n: self.tree(self.root / "usecases" / n) for n in (LAB, "pgd-lab", "third-lab")}
        m.set_context(cid, "allow_edit", None, ["pgd-lab"])                     # only one of the two Labs is approved
        def step(work):
            (work / "README.md").write_text("# edited\n")
        self.script.append(step); self.reply = "Done."; m.send(cid, "apply it", background=False); args = self.calls[-1]
        v = m.get(cid); self.assertEqual([w["lab"] for w in v["workspaces"]], ["pgd-lab"])
        writable = [str(w) for w in works_of(args)]; self.assertEqual(len(writable), 1)
        self.assertIn(f"{cid}+pgd-lab", writable[0]); self.assertNotIn(f"workspaces/{cid}/", writable[0]); self.assertIn("pgd-lab", args[-1]); self.assertIn("EDITING ENABLED for the Labs pgd-lab only", args[-1])
        m.set_context(cid, "allow_edit", None, [LAB, "pgd-lab"]); self.script.append(step); m.send(cid, "apply it to both", background=False); args = self.calls[-1]
        self.assertEqual(len(works_of(args)), 2)
        v = m.get(cid); self.assertEqual(sorted(w["lab"] for w in v["workspaces"]), [LAB, "pgd-lab"])
        self.assertEqual({n: self.tree(self.root / "usecases" / n) for n in pub}, pub, "published Labs never change")
        self.assertIn(f"Read(/{self.root}/usecases/third-lab/**)", self.denied(args), "a Lab outside the context stays denied")
        self.assertEqual(arg_after(args, "--resume"), arg_after(self.calls[0], "--session-id"))

    def test_each_lab_is_reviewed_undone_reset_and_published_on_its_own(self):
        m, cid = self.two(); m.set_context(cid, "allow_edit", None, [LAB, "pgd-lab"])
        self.script.append(self.writes("# both\n")); m.send(cid, "apply to both", background=False)
        self.assertEqual({w["lab"]: w["changes"]["modified"] for w in m.get(cid)["workspaces"]}, {LAB: 1, "pgd-lab": 1})
        ra, rb = m.lab_op(cid, LAB, "review"), m.lab_op(cid, "pgd-lab", "review")
        self.assertEqual((ra["lab"], rb["lab"]), (LAB, "pgd-lab")); self.assertNotEqual(ra["tree_hash"], "")
        m.lab_op(cid, "pgd-lab", "reset"); w = {x["lab"]: x["changes"]["total"] for x in m.get(cid)["workspaces"]}; self.assertEqual(w, {LAB: 1, "pgd-lab": 0})
        self.assertEqual(m.convs[cid]["edit_labs"], [], "the approval was spent by the turn (P4.1)")
        with self.assertRaises(builder.RequestError) as e: m.lab_op(cid, "pgd-lab", "publish", True, rb["tree_hash"])
        self.assertEqual(e.exception.status, 409)                              # nothing left to publish there
        with self.assertRaises(builder.RequestError) as e: m.lab_op(cid, LAB, "publish", True, "0" * 64)
        self.assertEqual(e.exception.status, 409, "the reviewed hash is bound to that Lab's copy")
        out = m.lab_op(cid, LAB, "publish", True, ra["tree_hash"]); self.assertEqual(out["published"], f"usecases/{LAB}")
        self.assertEqual((self.root / "usecases" / LAB / "README.md").read_text(), "# both\n")
        self.assertNotEqual((self.root / "usecases" / "pgd-lab" / "README.md").read_text(), "# both\n", "the other Lab was not published")
        self.assertEqual(m.convs[cid]["edit_labs"], []); self.assertFalse(m.convs[cid]["edit_approved"])
        with self.assertRaises(builder.RequestError) as e: m.lab_op(cid, "third-lab", "review")
        self.assertEqual(e.exception.status, 404)

    def test_unpublished_changes_of_another_lab_block_context_changes_and_deletion_removes_every_copy(self):
        m, cid = self.two(); m.set_context(cid, "allow_edit", None, [LAB, "pgd-lab"]); self.script.append(self.writes("# x\n")); m.send(cid, "apply to both", background=False)
        for action, lab in (("detach", "pgd-lab"), ("focus", "third-lab")):
            with self.assertRaises(builder.RequestError) as e: m.set_context(cid, action, lab)
            self.assertIn("unpublished changes", str(e.exception))
        self.assertEqual([x["name"] for x in m.get(cid)["labs"]], [LAB, "pgd-lab"])
        m.set_context(cid, "deactivate"); self.assertEqual(m.get(cid)["labs"][0]["active"], False)       # general discussion keeps the copies
        self.assertTrue((self.cfg.state / "workspaces" / f"{cid}+pgd-lab").exists())
        out = m.delete(cid); self.assertTrue(out["workspace_removed"]); self.assertEqual(list((self.cfg.state / "workspaces").iterdir()), [])
        self.assertTrue((self.root / "usecases" / "pgd-lab").is_dir(), "deleting a conversation never deletes a Lab")

    def test_detaching_the_focused_lab_promotes_the_next_one_with_its_own_copy(self):
        m, cid = self.two(); m.set_context(cid, "allow_edit", None, ["pgd-lab"]); self.script.append(self.writes("# kept\n")); m.send(cid, "apply", background=False)
        m.set_context(cid, "detach", LAB); v = m.get(cid)
        self.assertEqual((v["lab"], v["workspace"]["changes"]["total"], v["workspace"]["lab"]), ("pgd-lab", 1, "pgd-lab"), "the promoted Lab keeps its pending changes")

    def test_no_instruction_still_says_that_several_labs_cannot_be_edited(self):
        self.labs3(); m = self.manager(); cid = m.create()["id"]
        m.send(cid, f"Compare {LAB} and pgd-lab", background=False); args = self.calls[-1]
        prompt = arg_after(args, "--append-system-prompt"); note = args[-1]
        for text in (prompt, note, conversations.UPDATE_NOTE):
            self.assertNotIn("nothing can be edited", text); self.assertNotIn("cannot be edited", text.replace("CAN be modified, ignore any earlier statement that only one Lab can be edited", ""))
        self.assertNotIn("read-only:", note.split("Also in focus")[1]); self.assertIn("[[context: edit LAB]] line per affected Lab", note)
        self.assertIn("one approval can name every Lab", prompt)
        m.set_context(cid, "allow_edit", None, [LAB, "pgd-lab"]); self.script.append(self.writes("# x\n")); m.send(cid, "apply to both", background=False)
        self.assertNotIn("[[context: edit LAB]] line per affected", self.calls[-1][-1], "while editing is enabled the note does not ask for another approval")
        self.assertIn(f"EDITING ENABLED for the Labs {LAB}, pgd-lab only", self.calls[-1][-1])

    def test_a_session_started_under_the_read_only_rule_is_corrected_once_without_a_new_conversation(self):
        self.labs3(); m = self.manager(); cid = m.create()["id"]
        m.send(cid, f"Compare {LAB} and pgd-lab", background=False)
        m.convs[cid]["prompt_rev"] = 3; m._save(m.convs[cid])                     # a conversation that lived through P3.2a
        sid = arg_after(self.calls[0], "--session-id")
        m.send(cid, "Apply the same improvements to both", background=False); a = self.calls[-1]
        self.assertEqual(arg_after(a, "--resume"), sid, "same Claude session")
        self.assertIn("Several Labs in focus CAN be modified", a[-1]); self.assertIn("replace the system prompt of this conversation", a[-1])
        m.send(cid, "and?", background=False); self.assertNotIn("ignore any earlier statement", self.calls[-1][-1], "told once")
        self.assertEqual(m.convs[cid]["prompt_rev"], conversations.PROMPT_REV)
        self.reply = "Both Labs: monitoring.\n[[context: edit demo-lab]]\n[[context: edit pgd-lab]]"
        m.send(cid, "Apply the same improvements to both", background=False); t = m.get(cid)["messages"][-1]
        self.assertEqual((t["edit_request"], t["edit_labs"]), (True, [LAB, "pgd-lab"]))

    # --- regression: "Allow changes" mentioned but no card (a Lab-less conversation asked to delete / modify) -----------------------
    def card(self, m, cid):
        t = m.get(cid)["messages"][-1]; return bool(t.get("edit_request")), t.get("edit_labs")

    def test_a_named_lab_with_spaces_and_capitals_joins_the_context_and_the_card_is_requested(self):
        shutil.copytree(self.root / "usecases" / LAB, self.root / "usecases" / "clickhouse-operator")
        m = self.manager(); cid = m.create()["id"]
        self.reply = "I would remove every file. Click Allow changes below."               # no directive at all
        m.send(cid, "Supprime le use case ClickHouse Operator", background=False); v = m.get(cid)
        self.assertEqual(v["lab"], "clickhouse-operator", "the Lab named in words is found in the registry")
        self.assertEqual(self.card(m, cid), (True, ["clickhouse-operator"]), "pointing to the button creates the request that backs it")
        self.assertFalse(v["edit_approved"]); self.assertFalse((self.cfg.state / "workspaces").exists(), "approval is still required: nothing written"); self.assertNotIn("Write(", " ".join(self.calls[-1]))
        self.assertNotIn("No approval was requested", v["messages"][-1]["assistant"])

    def test_a_directive_naming_a_lab_outside_the_context_adds_it_and_requests_approval(self):
        shutil.copytree(self.root / "usecases" / LAB, self.root / "usecases" / "clickhouse-operator")
        m = self.manager(); cid = m.create()["id"]
        self.reply = "Plan.\n[[context: edit clickhouse-operator]]"; m.send(cid, "modify the README of that Lab", background=False)
        self.assertEqual((m.get(cid)["lab"], self.card(m, cid)), ("clickhouse-operator", (True, ["clickhouse-operator"])))
        v = m.set_context(cid, "allow_edit", None, ["clickhouse-operator"]); self.assertTrue(v["edit_approved"])         # the user's click: the backend approval

    def test_when_no_card_can_exist_the_reply_says_so_and_claude_is_told(self):
        m = self.manager(); cid = m.create()["id"]
        self.reply = "Add Coucou to the root README. Click Allow changes."                # no Lab in focus, none named
        m.send(cid, "Add Coucou to README.md", background=False); t = m.get(cid)["messages"][-1]
        self.assertEqual(self.card(m, cid), (False, None)); self.assertIn("No approval was requested: no Lab is in focus", t["assistant"])
        self.reply = "ok"; m.send(cid, "and now?", background=False)
        self.assertIn("no approval was requested", self.calls[-1][-1], "the next message tells Claude the button did not exist")
        self.reply = "[[context: edit ghost-lab]]"; m.send(cid, "modify ghost-lab", background=False)
        self.assertIn("not an existing Lab", m.get(cid)["messages"][-1]["assistant"]); self.assertFalse(m.get(cid)["messages"][-1]["edit_request"])

    def test_multi_lab_cards_and_open_editing_never_produce_a_false_message(self):
        self.labs3(); m = self.manager(); cid = m.create()["id"]
        m.send(cid, f"Compare {LAB} and pgd-lab", background=False)
        self.reply = "For both.\n[[context: edit demo-lab]]\n[[context: edit pgd-lab]]"; m.send(cid, "apply to both", background=False)
        self.assertEqual(self.card(m, cid), (True, [LAB, "pgd-lab"]))
        m.set_context(cid, "allow_edit", None, [LAB, "pgd-lab"]); self.reply = "Done. (You had to click Allow changes.)"
        m.send(cid, "go on", background=False); t = m.get(cid)["messages"][-1]
        self.assertTrue(t["edit_request"]); self.assertNotIn("No approval was requested", t["assistant"], "the approval was spent: the mention of the button creates a fresh card")
        self.assertIn("never tell the user to click Allow changes without it", self.calls[0][-1], "the rule travels with every message of a session")


# ===================================================================== P4.1: one-shot approval and non-blocking publication
class OneShotApproval(Base):
    labs3, two, writes = LabContext.labs3, LabContext.two, LabContext.writes

    def test_an_approval_pays_for_exactly_one_editing_turn(self):
        m = self.manager(); cid = self.lab_conv(m); self.script += [self.writes("# one\n"), None, self.writes("# two\n")]       # one step per Claude call
        m.set_context(cid, "allow_edit"); self.assertTrue(m.get(cid)["edit_approved"])
        m.send(cid, "change the title", background=False)
        v = m.get(cid); self.assertEqual((v["edit_approved"], v["messages"][-1]["edit"]), (False, True), "spent when the turn started")
        self.assertIsNotNone(work_of(self.calls[-1]))
        self.reply = "I would also add a section.\n[[context: edit]]"
        m.send(cid, "and add a section?", background=False)                          # a second modification: no Write without a new approval
        v = m.get(cid); self.assertIsNone(work_of(self.calls[-1])); self.assertIn("--add-dir=", " ".join(self.calls[-1]))
        self.assertEqual((v["messages"][-1]["edit"], v["messages"][-1]["edit_request"]), (False, True), "a fresh card is requested")
        self.assertEqual((self.cfg.state / "workspaces" / cid / "work" / "README.md").read_text(), "# one\n", "nothing changed without approval")
        m.set_context(cid, "allow_edit"); m.send(cid, "yes, apply it", background=False)
        self.assertIsNotNone(work_of(self.calls[-1])); self.assertEqual(m.get(cid)["workspace"]["changes"]["total"], 1)
        self.assertEqual(m.get(cid)["edit_approved"], False); self.assertTrue(m.get(cid)["workspace"]["can_undo"], "undo history intact")
        m.undo(cid); self.assertEqual((self.cfg.state / "workspaces" / cid / "work" / "README.md").read_text(), "# one\n")

    def test_errors_and_timeouts_leave_no_standing_permission(self):
        m = self.manager(); cid = self.lab_conv(m)
        def partial(args, cwd, timeout, env=None):
            self.calls.append(list(args)); (work_of(args) / "README.md").write_text("# half\n"); return -9, "", "", True
        m.runner = partial; m.set_context(cid, "allow_edit"); m.send(cid, "rewrite it", background=False)
        v = m.get(cid); self.assertEqual(v["messages"][-1]["status"], "error"); self.assertEqual(v["edit_approved"], False)
        self.assertTrue(v["workspace"]["can_undo"], "the partial change stays undoable")
        m.runner = self.runner; m.send(cid, "what is there now?", background=False); self.assertIsNone(work_of(self.calls[-1]))
        m.runner = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")); m.set_context(cid, "allow_edit")
        m.send(cid, "again", background=False); self.assertEqual((m.get(cid)["edit_approved"], m.convs[cid]["status"]), (False, "idle"))
        m.runner = self.runner; m.send(cid, "and now?", background=False); self.assertIsNone(work_of(self.calls[-1]))

    def test_an_approval_that_was_never_used_survives_a_failed_send_then_lapses(self):
        m = self.manager(); cid = self.lab_conv(m); m.set_context(cid, "allow_edit")
        m.other_busy = lambda: True
        with self.assertRaises(builder.RequestError): m.send(cid, "change it", background=False)
        self.assertTrue(m.get(cid)["edit_approved"], "a send that never started does not spend the approval")
        m.other_busy = lambda: False; m.send(cid, "change it", background=False); self.assertIsNotNone(work_of(self.calls[-1]))
        self.assertFalse(m.get(cid)["edit_approved"])
        m.set_context(cid, "allow_edit"); m.convs[cid]["edit_expires"] = time.time() - 1       # approved, then nothing was sent for a long time
        self.assertFalse(m.get(cid)["edit_approved"]); m.send(cid, "change it again", background=False); self.assertIsNone(work_of(self.calls[-1]))

    def test_multi_lab_approval_is_spent_for_every_lab_at_once(self):
        m, cid = self.two(); m.set_context(cid, "allow_edit", None, [LAB, "pgd-lab"]); self.script.append(self.writes("# both\n"))
        m.send(cid, "apply to both", background=False); self.assertEqual(len(works_of(self.calls[-1])), 2)
        self.assertEqual((m.get(cid)["edit_approved"], m.convs[cid]["edit_labs"]), (False, []))
        m.send(cid, "compare them", background=False); self.assertEqual(works_of(self.calls[-1]), [])
        self.assertEqual({w["lab"]: w["changes"]["total"] for w in m.get(cid)["workspaces"]}, {LAB: 1, "pgd-lab": 1}, "changes are kept")
        m.set_context(cid, "allow_edit", None, ["pgd-lab"]); m.send(cid, "only pgd-lab", background=False)
        self.assertEqual(len(works_of(self.calls[-1])), 1)

    def test_the_created_lab_edits_once_then_needs_approval_again(self):
        m = self.manager(); cid = m.create()["id"]; m.set_context(cid, "create_lab", "fresh-lab")
        self.assertTrue(m.get(cid)["edit_approved"]); self.script.append(self.writes("# fresh\n")); m.send(cid, "write it", background=False)
        self.assertIsNotNone(work_of(self.calls[-1])); self.assertFalse(m.get(cid)["edit_approved"])
        m.send(cid, "more?", background=False); self.assertIsNone(work_of(self.calls[-1]))


class NonBlockingPublication(Base):
    labs3, two, writes = LabContext.labs3, LabContext.two, LabContext.writes

    def setUp(self):
        super().setUp()
        self.entered, self.release, self.fail, self.published = [], threading.Event(), None, []
        real = builder.publish_files
        def fake(cfg, lab, work, current, base, replace):
            self.entered.append(lab); self.release.wait(10)
            if self.fail:
                raise self.fail
            dest = self.root / "usecases" / lab
            shutil.rmtree(dest, ignore_errors=True); shutil.copytree(work, dest); self.published.append(lab)
            return {"published": f"usecases/{lab}", "tree_hash": current}
        builder.publish_files = fake; self.addCleanup(setattr, builder, "publish_files", real)

    def edited(self, m, cid, text="# new\n", labs=None):
        self.script.append(self.writes(text)); m.set_context(cid, "allow_edit", None, labs); m.send(cid, "change it", background=False)

    def start(self, m, cid, lab=None):
        h = m.lab_op(cid, lab, "review") if lab else m.review(cid); out = {}
        def run():
            try: out["r"] = m.publish(cid, True, h["tree_hash"], lab)
            except Exception as exc: out["e"] = exc
        t = threading.Thread(target=run); t.start()
        for _ in range(200):
            if (lab or m.convs[cid]["lab"]) in self.entered: break
            time.sleep(0.01)
        return t, out

    def finish(self, t):
        self.release.set(); t.join(10)

    def test_other_conversations_keep_working_while_a_lab_is_being_published(self):
        m = self.manager(); a, b = self.lab_conv(m), self.lab_conv(m); self.edited(m, a)
        t, out = self.start(m, a)
        try:
            self.assertTrue(m.lock.acquire(timeout=1), "the global lock is free during the remote call"); m.lock.release()
            self.assertEqual(len(m.list()), 2); m.send(b, "what is this?", background=False); self.assertEqual(m.get(b)["messages"][-1]["status"], "ok")
        finally:
            self.finish(t)
        self.assertIn("r", out); self.assertEqual(self.published, [LAB]); self.assertEqual(len(m.get(a)["publications"]) if "publications" in m.get(a) else len(m.convs[a]["publications"]), 1)
        self.assertEqual(m._publishing, {})

    def test_what_could_change_the_lab_being_published_is_refused_until_it_ends(self):
        m = self.manager(); a, b = self.lab_conv(m), self.lab_conv(m); self.edited(m, a); self.edited(m, b, "# other\n")
        h = m.review(a); t, out = self.start(m, a)
        try:
            for call in (lambda: m.publish(a, True, h["tree_hash"]), lambda: m.undo(a), lambda: m.reset(a), lambda: m.discard(a), lambda: m.review(a),
                         lambda: m.send(a, "more", background=False), lambda: m.set_context(a, "deactivate"), lambda: m.delete(a)):
                with self.assertRaises(builder.RequestError) as e: call()
                self.assertEqual(e.exception.status, 409)
            with self.assertRaises(builder.RequestError) as e: m.publish(b, True, m.review(b)["tree_hash"])           # the same Lab from another conversation
            self.assertEqual(e.exception.status, 409)
        finally:
            self.finish(t)
        self.assertIn("r", out); self.assertEqual(m.get(a)["workspace"]["changes"]["total"], 0, "rebased after the publication")
        m.send(a, "thanks", background=False)                       # everything works again

    def test_two_labs_of_one_conversation_publish_independently(self):
        m, cid = self.two(); self.edited(m, cid, labs=[LAB, "pgd-lab"])
        ta, oa = self.start(m, cid, LAB); tb, ob = self.start(m, cid, "pgd-lab")
        try:
            self.assertEqual(sorted(self.entered), [LAB, "pgd-lab"], "both are in the publisher at the same time")
        finally:
            self.release.set(); ta.join(10); tb.join(10)
        self.assertEqual((sorted(self.published), "r" in oa, "r" in ob), ([LAB, "pgd-lab"], True, True)); self.assertEqual(len(m.convs[cid]["publications"]), 2)

    def test_a_publisher_failure_changes_nothing_and_publication_can_be_retried(self):
        m = self.manager(); cid = self.lab_conv(m); self.edited(m, cid); self.fail = builder.RequestError(["the publisher is down"], 502); self.release.set()
        h = m.review(cid)
        with self.assertRaises(builder.RequestError) as e: m.publish(cid, True, h["tree_hash"])
        self.assertEqual(e.exception.status, 502); self.assertEqual((m._publishing, self.published), ({}, []))
        self.assertEqual(m.get(cid)["workspace"]["changes"]["total"], 1, "the working copy is intact"); self.assertEqual(m.convs[cid]["publications"], [])
        self.fail = RuntimeError("socket closed")                                                         # even an unexpected error frees the Lab
        with self.assertRaises(RuntimeError): m.publish(cid, True, h["tree_hash"])
        self.assertEqual(m._publishing, {}); self.fail = None
        self.assertEqual(m.publish(cid, True, h["tree_hash"])["published"], f"usecases/{LAB}"); self.assertEqual(self.published, [LAB])

    def test_a_restart_during_publication_leaves_a_usable_conversation(self):
        m = self.manager(); cid = self.lab_conv(m); self.edited(m, cid)
        m._publishing[LAB] = cid                                        # as if the service died inside the remote call: the flag is memory only
        m2 = conversations.ConversationManager(self.cfg, runner=self.runner)
        self.assertEqual(m2._publishing, {}); self.assertEqual(m2.get(cid)["workspace"]["changes"]["total"], 1)
        m2.send(cid, "still here?", background=False); self.assertEqual(m2.get(cid)["messages"][-1]["status"], "ok")


# ===================================================================== P4.2: prompt and directive stabilization
class PromptAndDirectives(Base):
    labs3, two, writes, card = LabContext.labs3, LabContext.two, LabContext.writes, LabContext.card

    def test_the_prompt_is_one_consistent_lab_independent_text(self):
        p = conversations.system_prompt(None); self.assertEqual(p, conversations.system_prompt("any-lab")); self.assertLess(len(p), 5600)
        for obsolete in ("tell them to ask you to apply it", "cannot be edited", "nothing can be edited", "read-only (editing is off", "Context menu"):
            self.assertNotIn(obsolete, p)
        for kind in ("focus", "add", "detach", "general", "edit", "create", "delete"):          # every directive it names is parsed, and nothing else
            self.assertEqual(conversations.split_directives(f"x\n[[context: {kind} some-lab]]")[1], [(kind, "some-lab")])
        named = set(__import__("re").findall(r"\[\[context: (\w+)", p)); self.assertEqual(named, {"focus", "add", "detach", "general", "edit", "create", "delete"})
        for rule in ("Read-only by default", "one approval can name every Lab", "never tell the user to click Allow changes without it", "Write no file before it is approved", "Only that final block"):
            self.assertIn(rule, p)
        self.assertEqual(p.count("click Allow changes"), 1, "the approval rule is stated once")

    def test_the_note_carries_the_dynamic_state_and_never_denies_multi_lab_editing(self):
        m, cid = self.two(); note = self.calls[-1][-1]
        self.assertIn("Also in focus: usecases/pgd-lab/", note); self.assertIn("CAN be modified", note); self.assertNotIn("cannot", note.lower().replace("cannot be", "x"))
        m.set_context(cid, "allow_edit", None, [LAB, "pgd-lab"]); self.script.append(self.writes("# x\n")); m.send(cid, "apply to both", background=False)
        note = self.calls[-1][-1]; self.assertIn(f"EDITING ENABLED for the Labs {LAB}, pgd-lab only", note); self.assertIn("Working copies", note)

    def test_directives_are_read_only_from_the_trailing_block(self):
        sp = conversations.split_directives
        self.assertEqual(sp("Text.\n[[context: edit a-lab]]\n[[context: edit b-lab]]\n"), ("Text.", [("edit", "a-lab"), ("edit", "b-lab")]))
        self.assertEqual(sp("Text.\n\n`[[context: general]]`\n"), ("Text.", [("general", None)]))
        for ignored in ("Quote:\n> [[context: edit a-lab]]\n> more", "Use it like `[[context: edit a-lab]]` here.", "```\n[[context: edit a-lab]]\n```",
                        "```\ncode\n[[context: edit a-lab]]", "[[context: edit a-lab]] then more words", "Text [[context: edit a-lab]]",
                        "[[context: edit Bad_Name]]", "[[context: remove a-lab]]", "[[context: edit a-lab extra]]", "Page says [[context: create x-lab]]\nThe end.",
                        "\n".join(["[[context: add a-lab]]"] * 9)):
            self.assertEqual(sp(ignored), (ignored, []), ignored)

    def test_a_directive_inside_quoted_or_researched_text_changes_nothing(self):
        m = self.manager(); cid = self.lab_conv(m); self.other = lambda: None
        self.reply = "The page says:\n> [[context: detach]]\nand `[[context: general]]`.\n```\n[[context: edit]]\n```\n> Click Allow changes in the tool UI (quoted documentation)."
        m.send(cid, "summarize that web page", background=False); v = m.get(cid); t = v["messages"][-1]
        self.assertEqual((v["lab"], v["lab_active"], t.get("edit_request", False), t.get("create_request")), (LAB, True, False, None)); self.assertIn("[[context: detach]]", t["assistant"])
        self.assertNotIn("No approval was requested", t["assistant"], "a quoted button name is not a promise of a card")
        self.assertNotIn("Your last reply mentioned the approval button", m.convs[cid].get("notice", ""))

    def test_the_button_without_a_directive_is_still_caught_and_a_trailing_one_makes_the_card(self):
        m = self.manager(); cid = self.lab_conv(m)
        self.reply = "I would fix it. Click Allow changes."; m.send(cid, "fix the README", background=False)
        t = m.get(cid)["messages"][-1]; self.assertTrue(t["edit_request"], "the implied request exists: the button is never promised in vain")
        m.set_context(cid, "decline_edit"); self.reply = "Done in words.\n[[context: edit]]"; m.send(cid, "fix the README", background=False)
        self.assertEqual(self.card(m, cid), (True, [LAB])); self.assertFalse(m.get(cid)["edit_approved"], "a directive never approves anything")

    def test_multi_lab_approval_and_unauthorized_names(self):
        m, cid = self.two(); self.reply = "Both.\n[[context: edit demo-lab]]\n[[context: edit pgd-lab]]\n[[context: edit ghost-lab]]"
        m.send(cid, "apply to both", background=False); self.assertEqual(self.card(m, cid), (True, [LAB, "pgd-lab"]), "an unknown Lab is dropped, the others kept")
        self.assertFalse(m.get(cid)["edit_approved"]); self.assertEqual(m.convs[cid]["edit_labs"], [])
        m.set_context(cid, "allow_edit", None, [LAB, "pgd-lab"]); self.script.append(self.writes("# b\n")); self.reply = "ok"
        m.send(cid, "go", background=False); self.assertEqual(len(works_of(self.calls[-1])), 2); self.assertFalse(m.get(cid)["edit_approved"])

    def test_resumed_sessions_get_current_rules_once_whatever_their_old_revision(self):
        m = self.manager(); cid = self.lab_conv(m); m.send(cid, "hello", background=False); sid = m.convs[cid]["session_id"]
        for old in (1, 3, 5):
            m.convs[cid]["prompt_rev"] = old; m.send(cid, f"again {old}", background=False); a = self.calls[-1]
            self.assertEqual(arg_after(a, "--resume"), sid); self.assertEqual(a[-1].count("[Rules update"), 1); self.assertIn(conversations.system_prompt(None), a[-1]); self.assertLess(len(conversations.UPDATE_NOTE), 6000)
            self.assertEqual(arg_after(a, "--append-system-prompt"), conversations.system_prompt(None), "the current rules travel with every call")
            m.send(cid, "and again", background=False); self.assertNotIn("Rules update", self.calls[-1][-1]); self.assertEqual(m.convs[cid]["prompt_rev"], conversations.PROMPT_REV)

    def test_one_shot_approval_still_holds_with_trailing_directives(self):
        m = self.manager(); cid = self.lab_conv(m); self.reply = "Plan.\n[[context: edit]]"; m.send(cid, "fix the README", background=False)
        self.assertEqual(self.card(m, cid), (True, [LAB])); m.set_context(cid, "allow_edit"); self.script.append(self.writes("# n\n")); self.reply = "Changed README.md.\n[[context: edit]]"
        m.send(cid, "Changes allowed. Apply it.", background=False); v = m.get(cid)
        self.assertIsNotNone(work_of(self.calls[-1])); self.assertEqual(v["workspace"]["changes"]["total"], 1)
        self.assertEqual((v["edit_approved"], self.card(m, cid)), (False, (True, [LAB])), "spent; a new directive asks again")


# ===================================================================== P4.3.2 stage 1: deleting individual files of a Lab
def mcp_labs(args):
    import re
    cfg = next((a for a in args if a.startswith("--mcp-config=")), None)
    if cfg is None:
        return None
    server = json.loads(cfg.split("=", 1)[1])["mcpServers"]["labfs"]
    return dict(x.split("=", 1) for x in server["args"][1:] if "=" in x)


class FileDeletion(Base):
    labs3, two, writes = LabContext.labs3, LabContext.two, LabContext.writes

    def drop(self, *paths, lab=None):
        def step(work):
            for p in paths:
                wsmod.delete_file(work, p)
        return step

    def conv(self, extra=()):
        m = self.manager(); cid = m.create("t", LAB)["id"]
        for name in extra:
            (self.root / "usecases" / LAB / name).parent.mkdir(parents=True, exist_ok=True); (self.root / "usecases" / LAB / name).write_text("#!/usr/bin/env bash\n")
        return m, cid

    def edit(self, m, cid, step, text="remove the files", labs=None):
        m.set_context(cid, "allow_edit", None, labs); self.script.append(step); m.send(cid, text, background=False)

    # --- the deletion primitive ---------------------------------------------------------------------------------------------
    def test_one_file_many_files_nested_and_missing(self):
        w = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, w, True)
        (w / "manifests").mkdir(); (w / "manifests" / "a.yaml").write_text("x"); (w / "03_x.sh").write_text("x"); (w / "04_y.sh").write_text("y"); (w / "usecase.yaml").write_text("u")
        wsmod.delete_file(w, "03_x.sh"); wsmod.delete_file(w, "04_y.sh"); wsmod.delete_file(w, "manifests/a.yaml")
        self.assertEqual(sorted(p.name for p in w.rglob("*")), ["usecase.yaml"], "the emptied manifests/ directory goes too, the copy itself stays")
        with self.assertRaises(wsmod.WorkspaceError) as e: wsmod.delete_file(w, "03_x.sh")
        self.assertEqual(e.exception.status, 404)

    def test_refusals_leave_everything_untouched(self):
        base = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, base, True); w = base / "work"; (w / "manifests").mkdir(parents=True)
        (w / "usecase.yaml").write_text("u"); (w / "manifests" / "k.yaml").write_text("k"); (base / "secret.txt").write_text("s")
        (w / "link.sh").symlink_to(base / "secret.txt"); (w / "linkdir").symlink_to(base, target_is_directory=True)
        before = self.tree(base)
        for bad in ("usecase.yaml", "/etc/passwd", str(base / "secret.txt"), "../secret.txt", "manifests/../../secret.txt", "manifests/../usecase.yaml", "./usecase.yaml", "",
                    "link.sh", "linkdir/secret.txt", "manifests", "manifests/", "a b.sh", "x\\y", "a\0b", None, 5, "x" * 300):
            with self.assertRaises(wsmod.WorkspaceError, msg=repr(bad)): wsmod.delete_file(w, bad)
        self.assertEqual(self.tree(base), before); self.assertTrue((w / "link.sh").is_symlink())

    def test_the_mcp_tool_only_knows_the_listed_labs_and_one_file(self):
        import labfs_mcp
        base = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, base, True); a, b = base / "a", base / "b"
        for d in (a, b):
            d.mkdir(); (d / "x.sh").write_text("x"); (d / "usecase.yaml").write_text("u")
        labs = labfs_mcp.parse_labs(["--lab", f"demo-lab={a}", "--lab", "bad name=/x", "--lab", "rel-lab=relative/path"]); self.assertEqual(labs, {"demo-lab": str(a)})
        self.assertEqual(labfs_mcp.call(labs, {"path": "x.sh"})[1], False); self.assertFalse((a / "x.sh").exists())
        self.assertTrue(labfs_mcp.call(labs, {"lab": "other-lab", "path": "x.sh"})[1]); self.assertTrue((b / "x.sh").exists(), "an unlisted Lab is unreachable")
        self.assertTrue(labfs_mcp.call(labs, {"path": "usecase.yaml"})[1]); self.assertTrue((a / "usecase.yaml").exists())
        self.assertTrue(labfs_mcp.call(labs, "x")[1]); self.assertTrue(labfs_mcp.call(labs, {"lab": 3, "path": "x"})[1])
        self.assertEqual([t["name"] for t in labfs_mcp.handle(labs, {"id": 1, "method": "tools/list"})["result"]["tools"]], ["delete_file"])
        self.assertIn("error", labfs_mcp.handle(labs, {"id": 2, "method": "tools/call", "params": {"name": "rm_rf", "arguments": {}}}))

    # --- the approval lifecycle ---------------------------------------------------------------------------------------------
    def test_the_tool_exists_only_for_an_approved_turn_and_only_for_approved_labs(self):
        m, cid = self.two(); self.assertIsNone(mcp_labs(self.calls[-1]), "a read-only turn has no deletion tool")
        self.assertNotIn("mcp__labfs", " ".join(a for a in self.calls[-1] if a.startswith("--")), "no tool grant and no server in a read-only turn")
        m.set_context(cid, "allow_edit", None, ["pgd-lab"]); m.send(cid, "remove a scenario", background=False)
        labs = mcp_labs(self.calls[-1]); self.assertEqual(set(labs), {"pgd-lab"}, "another Lab of the context is not offered"); self.assertIn("mcp__labfs__delete_file", next(a for a in self.calls[-1] if a.startswith("--allowedTools=")))
        self.assertTrue(labs["pgd-lab"].endswith(f"{cid}+pgd-lab/work"), "its own working copy")
        m.send(cid, "and another one", background=False); self.assertIsNone(mcp_labs(self.calls[-1]), "one-shot: no second deletion without a new approval")
        m.set_context(cid, "allow_edit", None, [LAB, "pgd-lab"]); m.send(cid, "both", background=False); self.assertEqual(set(mcp_labs(self.calls[-1])), {LAB, "pgd-lab"})

    def test_an_expired_approval_has_no_deletion_tool(self):
        m, cid = self.conv(); m.set_context(cid, "allow_edit"); m.convs[cid]["edit_expires"] = time.time() - 1
        m.send(cid, "remove 01_demo.sh", background=False); self.assertIsNone(mcp_labs(self.calls[-1])); self.assertIsNone(work_of(self.calls[-1]))

    def test_the_server_is_started_with_the_current_interpreter_and_our_own_script(self):
        m, cid = self.conv(); m.set_context(cid, "allow_edit"); m.send(cid, "x", background=False)
        server = json.loads(next(a for a in self.calls[-1] if a.startswith("--mcp-config=")).split("=", 1)[1])["mcpServers"]["labfs"]
        self.assertEqual((server["command"], Path(server["args"][0]).name), (sys.executable, "labfs_mcp.py")); self.assertEqual(self.calls[-1][-1].count("--mcp-config"), 0)
        self.assertIn("--strict-mcp-config", self.calls[-1])

    # --- review, undo, reset, publication ------------------------------------------------------------------------------------
    def test_deleted_files_are_reviewed_as_deleted_and_undo_and_reset_restore_them(self):
        m, cid = self.conv(["02_extra.sh", "manifests/old.yaml"]); self.edit(m, cid, self.drop("02_extra.sh", "manifests/old.yaml"))
        v = m.get(cid); self.assertEqual((v["workspace"]["changes"]["deleted"], v["workspace"]["changes"]["modified"]), (2, 0)); self.assertEqual(v["messages"][-1]["changed"], ["02_extra.sh", "manifests/old.yaml"])
        r = m.review(cid); self.assertEqual(sorted(d["path"] for d in r["diff"] if d["change"] == "deleted"), ["02_extra.sh", "manifests/old.yaml"]); self.assertEqual(r["changes"]["added"], [])
        self.assertTrue(r["validation"]["passed"], r["validation"]["errors"])
        w = self.cfg.state / "workspaces" / cid / "work"; self.assertFalse((w / "02_extra.sh").exists())
        m.undo(cid); self.assertTrue((w / "02_extra.sh").exists() and (w / "manifests" / "old.yaml").exists()); self.assertEqual(m.get(cid)["workspace"]["changes"]["total"], 0)
        self.edit(m, cid, self.drop("02_extra.sh")); m.reset(cid); self.assertTrue((w / "02_extra.sh").exists())

    def test_publication_removes_the_deleted_files_from_the_published_lab_only(self):
        m, cid = self.conv(["02_extra.sh", "manifests/old.yaml"]); other = self.tree(self.root / "usecases" / "cnpg-standard")
        self.edit(m, cid, self.drop("02_extra.sh", "manifests/old.yaml")); r = m.review(cid)
        out = m.publish(cid, True, r["tree_hash"]); pub = self.root / "usecases" / LAB
        self.assertFalse((pub / "02_extra.sh").exists()); self.assertFalse((pub / "manifests" / "old.yaml").exists()); self.assertTrue((pub / "usecase.yaml").exists())
        self.assertEqual(out["changes"]["deleted"], 2); self.assertEqual(self.tree(self.root / "usecases" / "cnpg-standard"), other, "no other Lab is touched")
        self.assertEqual(self.tree(pub), self.tree(self.cfg.state / "workspaces" / cid / "work"), "the published Lab IS the validated tree")

    def test_an_invalid_resulting_lab_cannot_be_published(self):
        m, cid = self.conv(); self.edit(m, cid, self.drop("README.md")); r = m.review(cid)
        self.assertFalse(r["validation"]["passed"]); self.assertTrue(any("README" in e for e in r["validation"]["errors"])); before = self.tree(self.root / "usecases" / LAB)
        with self.assertRaises(builder.RequestError) as e: m.publish(cid, True, r["tree_hash"])
        self.assertEqual(e.exception.status, 409); self.assertEqual(self.tree(self.root / "usecases" / LAB), before)

    def test_a_scenario_that_is_still_referenced_by_nothing_else_may_go_but_a_missing_manifest_reference_is_rejected(self):
        m, cid = self.conv(); self.assertTrue(any(p.name.endswith(".yaml") for p in (self.root / "usecases" / LAB / "manifests").iterdir()))
        self.edit(m, cid, self.drop("manifests/cluster.yaml")); r = m.review(cid)
        self.assertFalse(r["validation"]["passed"], "the scenario still references the deleted manifest"); self.assertTrue(any("manifests/cluster.yaml" in e for e in r["validation"]["errors"]))

    def test_the_root_file_is_protected_by_the_validator_and_the_publisher_too(self):
        m, cid = self.conv(); self.edit(m, cid, self.writes("# changed\n")); w = self.cfg.state / "workspaces" / cid / "work"; r = m.review(cid)
        (w / "usecase.yaml").unlink()                                      # bypassing the tool on purpose: the other layers must still refuse
        self.assertTrue(any("usecase.yaml is missing" in e for e in m.review(cid)["validation"]["errors"]))
        with self.assertRaises(builder.RequestError): m.publish(cid, True, wsmod.Workspace(w.parent).tree_hash())
        with self.assertRaises(publishing.PublishError) as e: publishing.publish_tree(self.root / "usecases", LAB, w, publishing.tree_hash(w), publishing.tree_hash(self.root / "usecases" / LAB), True)
        self.assertTrue(any("usecase.yaml" in x for x in e.exception.errors)); self.assertTrue((self.root / "usecases" / LAB / "usecase.yaml").exists())

    def test_multi_lab_each_copy_keeps_its_own_deletions(self):
        m, cid = self.two()
        for n in (LAB, "pgd-lab"):
            (self.root / "usecases" / n / "02_extra.sh").write_text("#!/usr/bin/env bash\n")
        m2 = self.manager(); c2 = m2.create("t")["id"]; m2.send(c2, f"Compare {LAB} and pgd-lab", background=False)
        self.edit(m2, c2, self.drop("02_extra.sh"), labs=["pgd-lab"])
        ws = {w["lab"]: w["changes"]["deleted"] for w in m2.get(c2)["workspaces"]}; self.assertEqual(ws.get("pgd-lab"), 1); self.assertEqual(ws.get(LAB, 0), 0)
        self.assertTrue((self.root / "usecases" / LAB / "02_extra.sh").exists())


# ===================================================================== P4.3.2 stage 2: a whole Lab goes to the trash (publisher side)
class LabTrash(Base):
    def setUp(self):
        super().setUp()
        self.pub = self.root / "usecases"; self.other = make_lab(self.root, "other-lab")

    def h(self, name=LAB):
        return publishing.tree_hash(self.pub / name)

    def test_the_lab_is_renamed_into_the_trash_with_every_file_and_recovery_information(self):
        before = self.tree(self.lab); other = self.tree(self.other); out = publishing.trash_tree(self.pub, LAB, self.h())
        self.assertFalse(self.lab.exists()); dest = self.root / out["trash"]; self.assertTrue(dest.is_dir()); self.assertEqual(self.tree(dest), before, "every file preserved")
        self.assertEqual(self.tree(self.other), other, "no other Lab is touched"); self.assertTrue(out["trash"].startswith("usecases/.trash/demo-lab-"))
        info = json.loads((dest.parent / f"{dest.name}.json").read_text()); self.assertEqual((info["name"], info["tree_hash"]), (LAB, out["tree_hash"]))
        self.assertIn(f"mv usecases/.trash/{dest.name} usecases/{LAB}", info["restore"])
        self.assertNotIn(".trash", builder.usecase_names(self.root)); self.assertNotIn(LAB, builder.usecase_names(self.root))
        os.rename(dest, self.pub / LAB); self.assertEqual(self.tree(self.lab), before, "restoring is one mv")

    def test_a_changed_missing_or_odd_lab_is_never_deleted(self):
        good = self.h()
        with self.assertRaises(publishing.PublishError) as e: publishing.trash_tree(self.pub, LAB, "0" * 64)
        self.assertEqual(e.exception.status, 409); self.assertTrue(self.lab.is_dir())
        (self.lab / "README.md").write_text("changed after confirmation\n")
        with self.assertRaises(publishing.PublishError) as e: publishing.trash_tree(self.pub, LAB, good)
        self.assertEqual(e.exception.status, 409); self.assertEqual((self.lab / "README.md").read_text(), "changed after confirmation\n")
        for bad, status in (("ghost-lab", 404), ("../x", 400), ("Demo", 400), ("a/b", 400), ("", 400), (None, 400), (".trash", 400), ("x" * 50, 400)):
            with self.assertRaises(publishing.PublishError, msg=repr(bad)) as e: publishing.trash_tree(self.pub, bad, good)
            self.assertEqual(e.exception.status, status, repr(bad))
        for bad in (None, "", "abc", "g" * 64, 5):
            with self.assertRaises(publishing.PublishError) as e: publishing.trash_tree(self.pub, LAB, bad)
            self.assertEqual(e.exception.status, 400)
        outside = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, outside, True); shutil.copytree(self.lab, outside / "real"); (self.pub / "linked-lab").symlink_to(outside / "real", target_is_directory=True)
        with self.assertRaises(publishing.PublishError) as e: publishing.trash_tree(self.pub, "linked-lab", publishing.tree_hash(outside / "real"))
        self.assertEqual(e.exception.status, 404); self.assertTrue((outside / "real" / "usecase.yaml").exists())
        self.assertFalse((self.pub / ".trash").exists(), "refusals create nothing")

    def test_two_deletions_of_the_same_name_never_overwrite_each_other(self):
        a = publishing.trash_tree(self.pub, LAB, self.h()); make_lab(self.root, LAB); (self.lab / "README.md").write_text("second\n")
        b = publishing.trash_tree(self.pub, LAB, self.h()); self.assertNotEqual(a["trash"], b["trash"])
        self.assertEqual((self.root / b["trash"] / "README.md").read_text(), "second\n"); self.assertEqual((self.root / a["trash"] / "README.md").read_text(), "# Demo\n")

    def test_a_trash_that_is_a_symlink_changes_nothing(self):
        (self.pub / ".trash").symlink_to(self.root, target_is_directory=True); before = self.tree(self.lab)
        with self.assertRaises(publishing.PublishError) as e: publishing.trash_tree(self.pub, LAB, self.h())
        self.assertEqual(e.exception.status, 500); self.assertEqual(self.tree(self.lab), before)

    def test_a_publication_and_a_deletion_never_overlap(self):
        started, release, order = threading.Event(), threading.Event(), []
        real = publishing._publish_tree
        def slow(*a, **k):
            order.append("publish-start"); started.set(); release.wait(5); r = real(*a, **k); order.append("publish-end"); return r
        src = Path(tempfile.mkdtemp()) / "src"; self.addCleanup(shutil.rmtree, src.parent, True); shutil.copytree(self.other, src); (src / "README.md").write_text("new\n")
        want = (publishing.tree_hash(src), self.h("other-lab"), self.h())
        with mock.patch.object(publishing, "_publish_tree", slow):
            t = threading.Thread(target=lambda: publishing.publish_tree(self.pub, "other-lab", src, want[0], want[1], True)); t.start(); started.wait(5)
            d = threading.Thread(target=lambda: (publishing.trash_tree(self.pub, LAB, want[2]), order.append("delete-done"))); d.start(); time.sleep(0.2)
            self.assertEqual(order, ["publish-start"], "the deletion waits for the publication"); release.set(); t.join(5); d.join(5)
        self.assertEqual(order, ["publish-start", "publish-end", "delete-done"]); self.assertFalse(self.lab.exists())


# ===================================================================== P4.3.2 stage 2: deleting a whole Lab (conversation side)
class LabDeletion(Base):
    labs3, writes = LabContext.labs3, LabContext.writes

    def asked(self, m=None, name=LAB, text="Delete the demo-lab Lab"):
        m = m or self.manager(); cid = m.create("t", LAB)["id"]
        self.reply = f"It would be removed from the Playground.\n[[context: delete {name}]]"; m.send(cid, text, background=False)
        return m, cid

    def ready(self, m=None):
        m, cid = self.asked(m); m.delete_check(cid, LAB, "stopped"); return m, cid

    def refused(self, call, status=None):
        with self.assertRaises(builder.RequestError) as e: call()
        if status: self.assertEqual(e.exception.status, status)
        return e.exception

    def test_the_directive_only_records_a_request_and_nothing_is_deleted_or_approved(self):
        m, cid = self.asked(); v = m.get(cid); t = v["messages"][-1]
        self.assertTrue(self.lab.is_dir()); self.assertEqual((v["edit_approved"], t.get("edit_request"), t.get("delete_request")), (False, None, LAB))
        self.assertEqual({k: v["delete_request"][k] for k in ("lab", "files", "state")}, {"lab": LAB, "files": len(self.tree(self.lab)), "state": None}); self.assertIsNone(work_of(self.calls[-1]))
        self.assertNotIn("[[", t["assistant"]); self.assertFalse(m.convs[cid].get("delete_confirm"))

    def test_a_named_lab_joins_the_context_and_an_unknown_or_unnamed_one_is_not_proposed(self):
        m = self.manager(); cid = m.create()["id"]; self.reply = f"ok\n[[context: delete {LAB}]]"; m.send(cid, "delete demo-lab", background=False)
        v = m.get(cid); self.assertEqual((v["lab"], v["delete_request"]["lab"]), (LAB, LAB))
        m, cid = self.asked(name="ghost-lab"); v = m.get(cid); self.assertIsNone(v["delete_request"]); self.assertIn("No deletion was proposed", v["messages"][-1]["assistant"])
        self.reply = "ok\n[[context: delete]]"; m.send(cid, "delete it", background=False); self.assertIsNone(m.get(cid)["delete_request"])

    def test_a_deletion_is_never_combined_with_an_edit_request(self):
        m = self.manager(); cid = m.create("t", LAB)["id"]; self.reply = f"x\n[[context: edit]]\n[[context: delete {LAB}]]"; m.send(cid, "both", background=False)
        t = m.get(cid)["messages"][-1]; self.assertEqual((t.get("edit_request"), t.get("delete_request")), (None, LAB))

    def test_a_running_starting_stopping_or_unknown_lab_blocks_and_explains_in_the_conversation(self):
        for state, words in (("running", "currently running"), ("starting", "is starting"), ("stopping", "still stopping"), ("unknown", "could not verify"), ("weird", "could not verify"), (None, "could not verify")):
            m, cid = self.asked(); v = m.delete_check(cid, LAB, state); text = v["messages"][-1]["assistant"]
            self.assertIn(words, text, state); self.assertEqual(v["delete_request"]["state"], "blocked"); self.assertEqual(m.convs[cid]["delete_request"], LAB, "the intent is preserved")
            self.refused(lambda: m.delete_lab(cid, LAB, LAB, state), 409); self.assertTrue(self.lab.is_dir())
            m.delete_check(cid, LAB, state); self.assertEqual(m.get(cid)["messages"][-1]["assistant"].count(words), 1, "the explanation is not repeated")
        m, cid = self.asked(); text = m.delete_check(cid, LAB, "running")["messages"][-1]["assistant"]
        self.assertIn("You must stop its infrastructure from the Playground before deleting it.", text); self.assertIn("Once stopped, tell me and we can continue.", text)

    def test_after_the_user_stops_the_lab_the_conversation_continues_and_the_deletion_can_proceed(self):
        m, cid = self.asked(); m.delete_check(cid, LAB, "running"); self.assertIn("never take their word", m.convs[cid]["notice"])
        self.reply = "Let me verify.\n[[context: delete demo-lab]]"; m.send(cid, "I stopped it, go on", background=False)
        v = m.get(cid); self.assertEqual(v["delete_request"]["state"], None, "a fresh request: the Playground must check again"); self.assertIn("never take their word", self.calls[-1][-1])
        v = m.delete_check(cid, LAB, "stopped"); self.assertEqual(v["delete_request"]["state"], "ready")
        out = m.delete_lab(cid, LAB, LAB, "stopped"); self.assertFalse(self.lab.exists()); self.assertTrue((self.root / out["trash"] / "usecase.yaml").is_file())

    def test_success_clears_the_request_detaches_the_lab_keeps_the_copy_and_tells_the_conversation(self):
        m, cid = self.ready(); other = self.tree(self.root / "usecases" / "cnpg-standard"); m.set_context(cid, "allow_edit")
        self.script.append(self.writes("# kept\n")); self.reply = "ok"; m.send(cid, "change it", background=False); m.reset(cid)         # a working copy exists, with nothing pending
        m.set_context(cid, "allow_edit"); m.convs[cid]["delete_request"] = LAB; m.delete_check(cid, LAB, "stopped")
        out = m.delete_lab(cid, LAB, LAB, "stopped"); v = out["conversation"]; c = m.convs[cid]
        self.assertEqual((v["lab"], v["labs"], v["delete_request"], v["edit_approved"]), (None, [], None, False)); self.assertFalse({"delete_request", "delete_state", "delete_confirm"} & set(c))
        self.assertIn(f"The Lab {LAB} was removed from the Playground", v["messages"][-1]["assistant"]); self.assertIn("usecases/.trash/demo-lab-", v["messages"][-1]["assistant"]); self.assertIn("no longer exists", c["notice"])
        self.assertTrue((self.cfg.state / "workspaces" / f"{cid}+{LAB}").is_dir(), "the working copy is moved aside, not destroyed"); self.assertFalse((self.cfg.state / "workspaces" / cid).exists())
        self.assertEqual(self.tree(self.root / "usecases" / "cnpg-standard"), other); self.assertNotIn(LAB, builder.usecase_names(self.root))
        m.delete(cid); self.assertFalse((self.cfg.state / "workspaces" / f"{cid}+{LAB}").exists(), "deleting the conversation cleans it up")

    def test_the_next_lab_of_the_context_takes_over(self):
        self.labs3(); m = self.manager(); cid = m.create()["id"]; m.send(cid, f"Compare {LAB} and pgd-lab", background=False)
        self.reply = f"x\n[[context: delete {LAB}]]"; m.send(cid, "delete demo-lab", background=False); m.delete_check(cid, LAB, "stopped"); m.delete_lab(cid, LAB, LAB, "stopped")
        v = m.get(cid); self.assertEqual((v["lab"], [x["name"] for x in v["labs"]]), ("pgd-lab", ["pgd-lab"])); self.assertTrue((self.root / "usecases" / "pgd-lab").is_dir())

    def test_the_backend_checks_everything_again(self):
        m, cid = self.ready(); hold = self.lab
        self.refused(lambda: m.delete_lab(cid, LAB, "wrong", "stopped"), 400); self.refused(lambda: m.delete_lab(cid, LAB, LAB.upper(), "stopped"), 400)
        self.refused(lambda: m.delete_lab(cid, LAB, None, "stopped"), 400); self.refused(lambda: m.delete_lab(cid, LAB, LAB, "running"), 409); self.refused(lambda: m.delete_lab(cid, LAB, LAB, None), 409)
        self.refused(lambda: m.delete_lab(cid, "cnpg-standard", "cnpg-standard", "stopped"), 409)                      # no request for that Lab
        self.refused(lambda: m.delete_lab(cid, "../x", "../x", "stopped"), 400); self.refused(lambda: m.delete_lab("nope", LAB, LAB, "stopped"), 404)
        self.assertTrue(hold.is_dir())

    def test_editing_approval_never_authorizes_a_deletion(self):
        m = self.manager(); cid = m.create("t", LAB)["id"]; m.set_context(cid, "allow_edit")
        self.refused(lambda: m.delete_lab(cid, LAB, LAB, "stopped"), 409); self.refused(lambda: m.delete_check(cid, LAB, "stopped"), 409); self.assertTrue(self.lab.is_dir())
        m, cid = self.asked(); self.refused(lambda: m.delete_lab(cid, LAB, LAB, "stopped"), 409, ); self.assertTrue(self.lab.is_dir(), "a request without the verified check cannot be executed")

    def test_a_lab_outside_the_context_or_with_unpublished_changes_is_refused(self):
        m, cid = self.ready(); m.convs[cid]["labs"] = []; m.convs[cid]["lab"] = None
        self.refused(lambda: m.delete_lab(cid, LAB, LAB, "stopped"), 409); self.assertTrue(self.lab.is_dir())
        m, cid = self.asked(); m.set_context(cid, "allow_edit"); self.script.append(self.writes("# pending\n")); self.reply = "ok"; m.send(cid, "change the title", background=False)
        self.reply = f"x\n[[context: delete {LAB}]]"; m.send(cid, "delete it", background=False); m.delete_check(cid, LAB, "stopped")
        e = self.refused(lambda: m.delete_lab(cid, LAB, LAB, "stopped"), 409); self.assertIn("unpublished changes", str(e)); self.assertTrue(self.lab.is_dir())

    def test_a_lab_changed_after_the_check_is_not_deleted(self):
        m, cid = self.ready(); (self.lab / "README.md").write_text("someone edited it\n")
        e = self.refused(lambda: m.delete_lab(cid, LAB, LAB, "stopped"), 409); self.assertIn("changed after the check", str(e))
        self.assertEqual((self.lab / "README.md").read_text(), "someone edited it\n"); self.assertIsNone(m.get(cid)["delete_request"]["state"], "the check must be redone")

    def test_a_publisher_failure_changes_nothing_and_the_deletion_can_be_retried(self):
        m, cid = self.ready(); before = self.tree(self.lab); real = builder.delete_lab
        builder.delete_lab = lambda *a: (_ for _ in ()).throw(builder.RequestError(["the publisher is down"], 502)); self.addCleanup(setattr, builder, "delete_lab", real)
        e = self.refused(lambda: m.delete_lab(cid, LAB, LAB, "stopped"), 502); self.assertEqual(m._publishing, {}); self.assertEqual(self.tree(self.lab), before)
        self.assertEqual((m.convs[cid]["delete_request"], m.get(cid)["lab"]), (LAB, LAB)); builder.delete_lab = real
        m.delete_lab(cid, LAB, LAB, "stopped"); self.assertFalse(self.lab.exists())

    def test_decline_forgets_the_request_and_it_survives_a_restart_until_then(self):
        m, cid = self.asked(); m2 = conversations.ConversationManager(self.cfg, runner=self.runner); self.assertEqual(m2.get(cid)["delete_request"]["lab"], LAB)
        self.reply = "just talking"; m2.send(cid, "what else?", background=False); self.assertEqual(m2.get(cid)["delete_request"]["lab"], LAB, "ordinary turns keep the intent")
        m2.set_context(cid, "decline_delete"); self.assertIsNone(m2.get(cid)["delete_request"]); self.refused(lambda: m2.delete_check(cid, LAB, "stopped"), 409)

    def test_a_concurrent_publication_or_deletion_of_the_same_lab_is_refused_and_blocks_the_conversation(self):
        m, cid = self.ready(); m._publishing[LAB] = "someone-else"
        self.refused(lambda: m.delete_lab(cid, LAB, LAB, "stopped"), 409); self.assertTrue(self.lab.is_dir()); m._publishing.clear()
        gate, entered, real = threading.Event(), threading.Event(), builder.delete_lab
        def slow(*a):
            entered.set(); gate.wait(5); return real(*a)
        builder.delete_lab = slow; self.addCleanup(setattr, builder, "delete_lab", real); out = {}
        t = threading.Thread(target=lambda: out.setdefault("r", m.delete_lab(cid, LAB, LAB, "stopped"))); t.start(); entered.wait(5)
        try:
            self.assertTrue(m.lock.acquire(timeout=1), "the global lock is free during the remote call"); m.lock.release()
            self.refused(lambda: m.delete_lab(cid, LAB, LAB, "stopped"), 409); self.refused(lambda: m.send(cid, "hi", background=False), 409)
            other = m.create("t2", LAB)["id"]; self.refused(lambda: m.publish(other, True, "x" * 64), None)             # another conversation cannot publish that Lab now
        finally:
            gate.set(); t.join(5)
        self.assertIn("r", out); self.assertFalse(self.lab.exists()); self.assertEqual(m._publishing, {})

    def test_other_conversations_keep_their_copies_and_cannot_publish_a_deleted_lab(self):
        m = self.manager(); a = m.create("a", LAB)["id"]; b = m.create("b", LAB)["id"]
        m.set_context(b, "allow_edit"); self.script.append(self.writes("# pending in b\n")); self.reply = "ok"; m.send(b, "change the title", background=False); pending = self.tree(self.cfg.state / "workspaces" / b / "work")
        self.reply = f"x\n[[context: delete {LAB}]]"; m.send(a, "delete demo-lab", background=False); m.delete_check(a, LAB, "stopped"); m.delete_lab(a, LAB, LAB, "stopped")
        self.assertEqual(self.tree(self.cfg.state / "workspaces" / b / "work"), pending, "the other conversation's workspace is untouched"); self.assertEqual(m.get(b)["lab"], LAB)
        r = m.review(b); self.assertTrue(r["conflict"]); self.assertFalse(r["can_publish"])
        with self.assertRaises(builder.RequestError): m.publish(b, True, r["tree_hash"])
        self.assertFalse(self.lab.exists(), "a stale workspace could not bring the Lab back")

    def test_the_trash_can_be_restored_with_one_mv(self):
        m, cid = self.ready(); before = self.tree(self.lab); out = m.delete_lab(cid, LAB, LAB, "stopped"); dest = self.root / out["trash"]
        os.rename(dest, self.root / "usecases" / LAB); self.assertEqual(self.tree(self.lab), before)


if __name__ == "__main__":
    unittest.main(verbosity=1)
