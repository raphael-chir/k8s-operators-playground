"""Unit tests of the AI Builder. The real Claude Code CLI is never started (a mock runner or a fake script stands in),
and nothing runs Docker, Kind, kubectl, Helm or a generated scenario. Run: tests/ai-builder.sh"""
import io
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "ai-builder"))
import builder, server, validator  # noqa: E402

GOOD_SCENARIO = """#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"
show_instruct() { ui_note "# 01 / Demo"; ui_pause; }
play() { ui_info "Apply"; ui_command "kubectl apply -f manifests/cluster.yaml"; ui_pause; }
main() { clear; show_instruct; play; }
main "$@"
"""
GOOD_YAML = "title: Demo\ndescription: A demo\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 3\nservices:\n  minio: true\n"
GOOD_MANIFEST = "apiVersion: postgresql.cnpg.io/v1\nkind: Cluster\nmetadata:\n  name: demo\n"


def write_good(draft):
    draft = Path(draft); (draft / "manifests").mkdir(parents=True, exist_ok=True)
    (draft / "usecase.yaml").write_text(GOOD_YAML); (draft / "README.md").write_text("# Demo\n")
    (draft / "01_demo.sh").write_text(GOOD_SCENARIO); (draft / "manifests" / "cluster.yaml").write_text(GOOD_MANIFEST)


def fake_repo():
    root = Path(tempfile.mkdtemp())
    (root / "usecases" / "cnpg-standard").mkdir(parents=True)
    (root / "usecases" / "cnpg-standard" / "usecase.yaml").write_text(GOOD_YAML)
    (root / "VERSION").write_text("0.0.0\n")
    return root


def draft_from_args(args):
    return Path(re.search(r"Write\(/(/[^)]*?)/\*\*\)", " ".join(args)).group(1))


class Base(unittest.TestCase):
    def setUp(self):
        self.root = fake_repo(); self.cfg = builder.Config(env={}, root=self.root)
        self.addCleanup(shutil.rmtree, self.root, True)


class RequestValidation(Base):
    def ok(self, **kw):
        return builder.validate_request({"name": "my-demo", "description": "Demonstrate something useful", **kw}, self.cfg)

    def bad(self, payload, status=400):
        with self.assertRaises(builder.RequestError) as cm:
            builder.validate_request(payload, self.cfg)
        self.assertEqual(cm.exception.status, status)

    def test_valid_and_default_reference(self):
        self.assertEqual(self.ok()["reference_usecase"], "cnpg-standard")

    def test_rejected_names_and_traversal(self):
        for n in ["", "ab", "../etc", "a/b", "A-upper", "-lead", "trail-", "dou--ble", "x" * 41, "has space", "a;rm", 5, None, "..", ".hidden"]:
            self.bad({"name": n, "description": "Demonstrate something useful"})

    def test_description_and_fields(self):
        self.bad({"name": "my-demo", "description": "short"})
        self.bad({"name": "my-demo", "description": "x" * 2001})
        self.bad({"name": "my-demo", "description": "bad \x00 control chars here"})
        self.bad({"name": "my-demo", "description": "Demonstrate something useful", "extra": "--dangerously-skip-permissions"})
        self.bad(["not", "an", "object"])

    def test_reference(self):
        self.bad({"name": "my-demo", "description": "Demonstrate something useful", "reference_usecase": "nope"})
        self.bad({"name": "my-demo", "description": "Demonstrate something useful", "reference_usecase": "../.."})

    def test_duplicate_usecase(self):
        self.bad({"name": "cnpg-standard", "description": "Demonstrate something useful"}, 409)


class DraftValidation(Base):
    def draft(self):
        d = self.root / "d"; write_good(d); return d

    def test_good_draft(self):
        self.assertEqual(validator.validate_draft(self.draft(), "demo"), [])

    def test_missing_yaml_and_bad_yaml(self):
        d = self.draft(); (d / "usecase.yaml").unlink()
        self.assertTrue(any("usecase.yaml is missing" in e for e in validator.validate_draft(d, "demo")))
        for text in ["title: T\n", "title: T\ndescription: D\ninfrastructure:\n  clusters: 0\n  workers_per_cluster: 1\n",
                     GOOD_YAML + "  prometeus: true\n", GOOD_YAML.replace("minio: true", "minio: yes"), "title: T\n\tbad: 1\n", "just text\n"]:
            (d / "usecase.yaml").write_text(text)
            self.assertTrue(validator.validate_draft(d, "demo"), text)

    def test_bash_syntax_error_without_executing(self):
        d = self.draft(); marker = self.root / "EXECUTED"
        (d / "01_demo.sh").write_text(GOOD_SCENARIO + f"\ntouch {marker}\nif then fi\n")
        errs = validator.validate_draft(d, "demo")
        self.assertTrue(any("bash -n" in e for e in errs)); self.assertFalse(marker.exists())

    def test_scenario_naming_and_numbering(self):
        d = self.draft()
        shutil.copy(d / "01_demo.sh", d / "Bad Name.sh"); self.assertTrue(any("NN_short_name" in e for e in validator.validate_draft(d, "demo")))
        (d / "Bad Name.sh").unlink(); shutil.copy(d / "01_demo.sh", d / "03_gap.sh")
        self.assertTrue(any("without gaps" in e for e in validator.validate_draft(d, "demo")))
        (d / "03_gap.sh").unlink(); shutil.copy(d / "01_demo.sh", d / "01_dup.sh")
        self.assertTrue(any("number 01" in e for e in validator.validate_draft(d, "demo")))

    def test_scenario_structure(self):
        d = self.draft(); (d / "01_demo.sh").write_text("#!/bin/sh\necho hi\n")
        errs = " ".join(validator.validate_draft(d, "demo"))
        for needle in ("#!/usr/bin/env bash", "set -Eeuo pipefail", "engine/lib/ui.sh", "main"):
            self.assertIn(needle, errs)

    def test_manifest_reference_and_syntax(self):
        d = self.draft(); (d / "manifests" / "cluster.yaml").unlink()
        self.assertTrue(any("manifests/cluster.yaml" in e and "does not exist" in e for e in validator.validate_draft(d, "demo")))
        (d / "manifests" / "cluster.yaml").write_text("kind: Cluster\n")
        self.assertTrue(any("apiVersion" in e for e in validator.validate_draft(d, "demo")))

    def test_symlink_and_unexpected_files(self):
        d = self.draft(); os.symlink("/etc/passwd", d / "link.txt"); (d / "notes.txt").write_text("x"); (d / "manifests" / "sub").mkdir()
        (d / "manifests" / "sub" / "a.yaml").write_text(GOOD_MANIFEST)
        errs = " ".join(validator.validate_draft(d, "demo"))
        self.assertIn("symbolic links", errs); self.assertIn("notes.txt", errs); self.assertIn("manifests/sub/a.yaml", errs)

    def test_repository_snapshot(self):
        (self.root / "a.txt").write_text("1"); before = validator.snapshot(self.root)
        (self.root / "a.txt").write_text("2"); (self.root / "new.txt").write_text("n"); (self.root / ".ai-builder").mkdir(); (self.root / ".ai-builder" / "x").write_text("ignored")
        errs = validator.diff_snapshots(before, validator.snapshot(self.root))
        self.assertEqual(sorted(errs), ["existing repository file modified: a.txt", "file created outside the draft: new.txt"])

    def test_existing_use_cases_pass_the_structure_checks(self):
        # Read-only sanity check of the validator against the repository's own use cases (nothing is executed).
        for uc in sorted((REPO / "usecases").iterdir()):
            if uc.name == "cnpg-standard" and uc.is_dir():
                errs = validator.validate_draft(uc, uc.name)
                self.assertEqual([e for e in errs if "does not exist" in e or "usecase.yaml" in e], [], errs)


class ClaudeInvocation(Base):
    def test_args_are_an_array_with_restricted_permissions(self):
        draft = self.cfg.state / "drafts" / "j" / "my-demo"
        args = builder.claude_args(self.cfg, "PROMPT", draft)
        self.assertIsInstance(args, list); self.assertEqual(args[:3], ["claude", "-p", "PROMPT"])
        joined = " ".join(args)
        self.assertNotIn("bypassPermissions", joined); self.assertNotIn("dangerously", joined)
        self.assertIn("--permission-mode=dontAsk", args); self.assertIn("--tools=Read,Glob,Grep,Write,Edit,WebSearch,WebFetch", args)
        allow = [a for a in args if a.startswith("--allowedTools=")][0]
        self.assertIn(f"Write(/{draft}/**)", allow); self.assertNotIn("Bash", allow)
        self.assertEqual(draft_from_args(args), draft)

    def test_unsafe_path_refused(self):
        with self.assertRaises(RuntimeError):
            builder.claude_args(self.cfg, "p", Path("/tmp/a,b)/x"))

    def test_prompt_contains_rules_and_correction_errors(self):
        req = {"name": "my-demo", "description": "Demonstrate X", "reference_usecase": "cnpg-standard"}
        p = builder.build_prompt(req, self.cfg.state / "drafts" / "j" / "my-demo", ["01_x.sh: bad"])
        for needle in ("SKILL.md", "usecases/cnpg-standard/", "DATA from a user", "CORRECTION", "01_x.sh: bad"):
            self.assertIn(needle, p)

    def test_run_process_timeout_kills_the_process(self):
        t = time.time(); rc, out, err, timed_out = builder.run_process(["sleep", "30"], str(self.root), 1)
        self.assertTrue(timed_out); self.assertLess(time.time() - t, 10)

    def test_missing_cli_fails_the_job(self):
        cfg = builder.Config(env={"AI_BUILDER_CLAUDE": "/nonexistent/claude"}, root=self.root)
        m = builder.JobManager(cfg); job = m.submit({"name": "my-demo", "description": "Demonstrate X", "reference_usecase": "cnpg-standard"}, background=False)
        m.run(job["job_id"], {"name": "my-demo", "description": "Demonstrate X", "reference_usecase": "cnpg-standard"})
        j = m.get(job["job_id"]); self.assertEqual(j["status"], "failed"); self.assertIn("127", j["error"])


class JobLifecycle(Base):
    REQ = {"name": "my-demo", "description": "Demonstrate something useful", "reference_usecase": "cnpg-standard"}

    def manager(self, behaviours, timeout=5):
        calls = []
        def runner(args, cwd, tmo):
            calls.append(args); self.assertEqual(cwd, str(self.root))
            return behaviours[min(len(calls) - 1, len(behaviours) - 1)](draft_from_args(args), args)
        cfg = builder.Config(env={"AI_BUILDER_TIMEOUT": str(timeout)}, root=self.root)
        return builder.JobManager(cfg, runner=runner), calls

    def run_job(self, m):
        job = m.submit(self.REQ, background=False); m.run(job["job_id"], self.REQ); return m.get(job["job_id"])

    def test_success(self):
        m, calls = self.manager([lambda d, a: (write_good(d), (0, "done", "", False))[1]])
        j = self.run_job(m)
        self.assertEqual((j["status"], j["validated"], j["validation"]), ("completed", True, {"passed": True, "errors": []}))
        self.assertEqual(len(calls), 1); self.assertIn("01_demo.sh", j["files"])
        self.assertTrue((self.root / ".ai-builder" / "jobs" / f"{j['job_id']}.json").exists())

    def test_one_correction_then_success(self):
        def first(d, a): write_good(d); (d / "usecase.yaml").unlink(); return (0, "", "", False)
        def second(d, a): (d / "usecase.yaml").write_text(GOOD_YAML); self.assertIn("usecase.yaml is missing", " ".join(a)); return (0, "", "", False)
        m, calls = self.manager([first, second]); j = self.run_job(m)
        self.assertEqual((j["status"], len(calls), [a["kind"] for a in j["attempts"]]), ("completed", 2, ["generation", "correction"]))

    def test_correction_is_limited_to_one_attempt(self):
        def bad(d, a): write_good(d); (d / "usecase.yaml").unlink(); return (0, "", "", False)
        m, calls = self.manager([bad]); j = self.run_job(m)
        self.assertEqual(len(calls), 2); self.assertEqual(j["status"], "failed"); self.assertFalse(j["validated"])
        self.assertFalse(j["validation"]["passed"]); self.assertTrue((self.root / ".ai-builder" / "drafts" / j["job_id"] / "my-demo" / "README.md").exists())

    def test_claude_failure_and_timeout(self):
        m, calls = self.manager([lambda d, a: (1, "", "boom", False)]); j = self.run_job(m)
        self.assertEqual((j["status"], len(calls)), ("failed", 1)); self.assertIn("code 1", j["error"])
        self.tearDown(); self.setUp()
        m, calls = self.manager([lambda d, a: (-9, "", "", True)], timeout=7); j = self.run_job(m)
        self.assertEqual(j["status"], "failed"); self.assertIn("timed out after 7s", j["error"])

    def test_agent_touching_the_repository_fails_validation_without_correction(self):
        def evil(d, a): write_good(d); (self.root / "VERSION").write_text("hacked"); (self.root / "stray.txt").write_text("x"); return (0, "", "", False)
        m, calls = self.manager([evil]); j = self.run_job(m)
        self.assertEqual((j["status"], len(calls)), ("failed", 1))
        errs = " ".join(j["validation"]["errors"]); self.assertIn("VERSION", errs); self.assertIn("stray.txt", errs)

    def test_one_job_at_a_time_and_duplicate_drafts(self):
        m, _ = self.manager([lambda d, a: (0, "", "", False)])
        m.submit(self.REQ, background=False)
        with self.assertRaises(builder.RequestError) as cm: m.submit({**self.REQ, "name": "other-demo"}, background=False)
        self.assertEqual(cm.exception.status, 409)

    def test_failed_job_does_not_block_the_same_name_and_restart_marks_interrupted(self):
        m, _ = self.manager([lambda d, a: (1, "", "", False)]); self.run_job(m)
        j2 = m.submit(self.REQ, background=False)                                # same name allowed after a failure
        m2 = builder.JobManager(builder.Config(env={}, root=self.root))             # "restart": pending jobs become failed
        self.assertEqual(m2.get(j2["job_id"])["status"], "failed"); self.assertIn("interrupted", m2.get(j2["job_id"])["error"])

    def test_completed_job_and_draft_survive_a_restart(self):
        m, _ = self.manager([lambda d, a: (write_good(d), (0, "", "", False))[1]]); j = self.run_job(m)
        m2 = builder.JobManager(builder.Config(env={}, root=self.root))
        j2 = m2.get(j["job_id"])
        self.assertEqual((j2["status"], j2["validated"]), ("completed", True))
        self.assertTrue((self.root / ".ai-builder" / "drafts" / j["job_id"] / "my-demo" / "usecase.yaml").is_file())

    def test_state_directory_override_never_touches_the_default(self):
        other = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, other, True)
        cfg = builder.Config(env={"AI_BUILDER_STATE_DIR": str(other / "s")}, root=self.root)
        builder.JobManager(cfg)
        self.assertTrue((other / "s" / "jobs").is_dir()); self.assertFalse((self.root / ".ai-builder").exists())

    def test_job_id_validation(self):
        m, _ = self.manager([lambda d, a: (0, "", "", False)])
        for bad in ["../../etc/passwd", "x", "", "20250101-000000-ZZZZZZ"]:
            self.assertIsNone(m.get(bad))


class ContainerMode(Base):
    """Container settings: bind address, bearer token, allowed hosts, separate state/publish directories (all mocked)."""
    TOKEN = "t" * 64

    def setUp(self):
        super().setUp()
        self.tokenfile = self.root / "token"; self.tokenfile.write_text(self.TOKEN + "\n")
        self.state = Path(tempfile.mkdtemp()); self.publish = Path(tempfile.mkdtemp()); self.confdir = Path(tempfile.mkdtemp())
        for d in (self.state, self.publish, self.confdir):
            self.addCleanup(shutil.rmtree, d, True)
        shutil.copytree(self.root / "usecases", self.publish, dirs_exist_ok=True)
        self.env = {"AI_BUILDER_BIND": "0.0.0.0", "AI_BUILDER_TOKEN_FILE": str(self.tokenfile), "AI_BUILDER_STATE_DIR": str(self.state),
                    "AI_BUILDER_PUBLISH_DIR": str(self.publish), "AI_BUILDER_ALLOWED_HOSTS": "ai-builder", "CLAUDE_CONFIG_DIR": str(self.confdir),
                    "AI_BUILDER_QUIET": "1", "AI_BUILDER_CLAUDE": sys.executable}
        self.cfg = builder.Config(env=self.env, root=self.root)

    # --- configuration ---------------------------------------------------------------------------------------------
    def test_config_values(self):
        self.assertEqual((self.cfg.host, self.cfg.state, self.cfg.publish_dir, self.cfg.token), ("0.0.0.0", self.state, self.publish, self.TOKEN))
        self.assertIn("ai-builder", self.cfg.allowed_hosts)
        self.assertIn("127.0.0.1", self.cfg.allowed_hosts)

    def test_unusual_bind_falls_back_to_loopback(self):
        self.assertEqual(builder.Config(env={"AI_BUILDER_BIND": "192.168.1.5"}, root=self.root).host, "127.0.0.1")

    def test_short_or_unreadable_token_is_refused(self):
        self.tokenfile.write_text("short")
        with self.assertRaises(RuntimeError):
            builder.Config(env=self.env, root=self.root)
        with self.assertRaises(RuntimeError):
            builder.Config(env={**self.env, "AI_BUILDER_TOKEN_FILE": str(self.root / "missing")}, root=self.root)

    def test_server_refuses_to_listen_publicly_without_a_token(self):
        env = {k: v for k, v in self.env.items() if k != "AI_BUILDER_TOKEN_FILE"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(server, "ThreadingHTTPServer") as httpd:
            with self.assertRaises(SystemExit):
                server.main()
            httpd.assert_not_called()

    def test_credentials_presence_never_reads_the_file(self):
        self.assertFalse(self.cfg.credentials_present())
        (self.confdir / ".credentials.json").write_text('{"secret": "do-not-leak"}')
        self.assertTrue(self.cfg.credentials_present())
        self.assertIsNone(builder.Config(env={}, root=self.root).credentials_present())   # host mode: unknown

    def test_claude_args_for_a_draft_outside_the_repository(self):
        draft = self.state / "drafts" / "j" / "my-demo"
        args = builder.claude_args(self.cfg, "P", draft)
        self.assertIn(f"--add-dir={draft}", args)
        self.assertIn(f"Write(/{draft}/**)", " ".join(args))
        deny = [a for a in args if a.startswith("--disallowedTools=")][0]
        for needle in (f"Read(/{self.tokenfile})", f"Read(/{self.confdir}/**)", "Read(//run/secrets/**)", f"Read(/{self.state}/jobs/**)"):
            self.assertIn(needle, deny)

    # --- publishing into a separate directory ------------------------------------------------------------------------------
    def job(self):
        def runner(args, cwd, tmo):
            write_good(draft_from_args(args))
            return (0, "", "", False)
        m = builder.JobManager(self.cfg, runner=runner)
        req = {"name": "my-demo", "description": "Demonstrate something useful", "reference_usecase": "cnpg-standard"}
        j = m.submit(req, background=False)
        m.run(j["job_id"], req)
        return m, j["job_id"]

    def test_publish_goes_to_the_publish_directory_only_and_leaves_no_staging(self):
        m, jid = self.job()
        m.approve(jid)
        before = validator.snapshot(self.root)
        out = m.publish(jid)
        self.assertTrue((self.publish / "my-demo" / "usecase.yaml").is_file())
        self.assertTrue(os.access(self.publish / "my-demo" / "01_demo.sh", os.X_OK))
        self.assertEqual(before, validator.snapshot(self.root), "the (read-only) repository view must not change")
        self.assertEqual([p.name for p in self.publish.iterdir() if p.name.startswith(".")], [])
        self.assertEqual(out["published"], "usecases/my-demo")

    def test_failed_rename_cleans_the_staging_and_creates_nothing(self):
        m, jid = self.job()
        m.approve(jid)
        with mock.patch.object(builder.os, "rename", side_effect=OSError("boom")):
            with self.assertRaises(builder.RequestError) as cm:
                m.publish(jid)
        self.assertEqual(cm.exception.status, 409)
        self.assertFalse((self.publish / "my-demo").exists())
        self.assertEqual([p.name for p in self.publish.iterdir() if p.name.startswith(".")], [])
        self.assertFalse(m.get(jid)["published"])

    def test_unwritable_publish_directory_is_reported(self):
        m, jid = self.job()
        m.approve(jid)
        with mock.patch.object(builder.shutil, "copytree", side_effect=PermissionError("ro")):
            with self.assertRaises(builder.RequestError) as cm:
                m.publish(jid)
        self.assertEqual(cm.exception.status, 500)
        self.assertFalse((self.publish / "my-demo").exists())

    def test_duplicate_is_detected_in_the_publish_directory(self):
        (self.publish / "taken").mkdir()
        with self.assertRaises(builder.RequestError) as cm:
            builder.validate_request({"name": "taken", "description": "Demonstrate something useful"}, self.cfg)
        self.assertEqual(cm.exception.status, 409)

    def test_publish_is_refused_while_a_job_runs(self):
        m, jid = self.job()
        m.approve(jid)
        m.jobs["20260101-000000-abcdef"] = {"job_id": "20260101-000000-abcdef", "name": "other", "status": "running"}
        with self.assertRaises(builder.RequestError) as cm:
            m.publish(jid)
        self.assertEqual(cm.exception.status, 409)
        self.assertFalse((self.publish / "my-demo").exists())

    def test_state_and_drafts_stay_in_the_state_directory(self):
        m, jid = self.job()
        self.assertTrue((self.state / "drafts" / jid / "my-demo" / "usecase.yaml").is_file())
        self.assertFalse((self.root / ".ai-builder").exists())


class HttpAuth(ContainerMode):
    def setUp(self):
        super().setUp()
        self.manager = builder.JobManager(self.cfg, runner=lambda a, c, t: (write_good(draft_from_args(a)), (0, "", "", False))[1])
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.manager, self.cfg, "t"))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def call(self, method, path, body=None, token="good", host=None):
        c = HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Content-Type": "application/json", "Host": host or f"127.0.0.1:{self.port}"}
        if token == "good":
            h["Authorization"] = f"Bearer {self.TOKEN}"
        elif token:
            h["Authorization"] = token
        c.request(method, path, None if body is None else json.dumps(body), h)
        r = c.getresponse()
        data = json.loads(r.read() or b"{}")
        c.close()
        return r.status, data

    def test_every_route_but_health_needs_the_token(self):
        req = {"name": "my-demo", "description": "Demonstrate something useful"}
        jid = "20260101-000000-abcdef"
        for bad in ("", "Bearer wrong", "Bearer ", f"X{self.TOKEN}", "Basic " + self.TOKEN, "AAAAAAA" + self.TOKEN, self.TOKEN):
            self.assertEqual(self.call("POST", "/generate", req, token=bad)[0], 401, bad)
            for method, path in (("GET", f"/status/{jid}"), ("GET", f"/review/{jid}"), ("POST", f"/approve/{jid}"), ("POST", f"/publish/{jid}")):
                self.assertEqual(self.call(method, path, token=bad)[0], 401, (method, path, bad))
        self.assertEqual(self.call("POST", "/generate", req)[0], 202)

    def test_health_is_open_but_minimal_without_the_token(self):
        self.assertEqual(self.call("GET", "/health", token=""), (200, {"status": "ok"}))
        self.assertEqual(self.call("GET", "/health", token="AAAAAAA" + self.TOKEN)[1], {"status": "ok"})
        st, body = self.call("GET", "/health")
        self.assertEqual((st, body["claude_credentials_present"], body["busy"]), (200, False, False))
        (self.confdir / ".credentials.json").write_text('{"accessToken": "sk-do-not-leak"}')
        st, body = self.call("GET", "/health")
        self.assertTrue(body["claude_credentials_present"])
        self.assertNotIn("sk-do-not-leak", json.dumps(body))
        self.assertNotIn(self.TOKEN, json.dumps(body))

    def test_allowed_host_names(self):
        self.assertEqual(self.call("GET", "/health", host="ai-builder:8099")[0], 200)
        self.assertEqual(self.call("GET", "/health", host="evil.example")[0], 403)
        self.assertEqual(self.call("GET", "/health", host="host.docker.internal:8099")[0], 403)


class ReviewPublish(Base):
    REQ = JobLifecycle.REQ

    def done_job(self, validated=True):
        def runner(args, cwd, tmo):
            d = draft_from_args(args); write_good(d)
            if not validated: (d / "usecase.yaml").unlink()
            return (0, "", "", False)
        m = builder.JobManager(builder.Config(env={}, root=self.root), runner=runner)
        j = m.submit(self.REQ, background=False); m.run(j["job_id"], self.REQ); return m, j["job_id"]

    def err(self, fn, *a):
        with self.assertRaises(builder.RequestError) as cm: fn(*a)
        return cm.exception

    def test_full_flow_publishes_without_running_anything(self):
        m, jid = self.done_job()
        self.assertIn("usecase.yaml", m.review(jid)["content"]); self.assertEqual(m.review(jid)["review"]["state"], "pending")
        self.assertEqual(self.err(m.publish, jid).status, 409)                       # not approved yet
        m.approve(jid); out = m.publish(jid)
        t = self.root / "usecases" / "my-demo"
        self.assertTrue((t / "usecase.yaml").is_file()); self.assertTrue(os.access(t / "01_demo.sh", os.X_OK))
        self.assertEqual(out["run"], "./playground usecase start my-demo"); self.assertTrue(m.get(jid)["published"])
        self.assertEqual(self.err(m.publish, jid).status, 409)                       # not twice
        self.assertEqual([p.name for p in (self.root / "usecases").iterdir() if p.name.startswith(".")], [])   # no staging left

    def test_unvalidated_cannot_be_approved(self):
        m, jid = self.done_job(validated=False)
        self.assertEqual(self.err(m.approve, jid).status, 409)

    def test_change_after_approval_blocks_publication(self):
        m, jid = self.done_job(); m.approve(jid)
        (self.root / ".ai-builder" / "drafts" / jid / "my-demo" / "README.md").write_text("changed")
        self.assertIn("changed after approval", str(self.err(m.publish, jid))); self.assertFalse((self.root / "usecases" / "my-demo").exists())

    def test_never_overwrites(self):
        m, jid = self.done_job(); m.approve(jid)
        (self.root / "usecases" / "my-demo").mkdir(); (self.root / "usecases" / "my-demo" / "keep").write_text("mine")
        self.assertIn("nothing was overwritten", str(self.err(m.publish, jid)))
        self.assertEqual((self.root / "usecases" / "my-demo" / "keep").read_text(), "mine")

    def test_unknown_and_malformed_ids(self):
        m, _ = self.done_job()
        for bad in ["../x", "nope", ""]: self.assertEqual(self.err(m.approve, bad).status, 404); self.assertEqual(self.err(m.publish, bad).status, 404)


class Http(Base):
    def setUp(self):
        super().setUp()
        def runner(args, cwd, tmo):
            write_good(draft_from_args(args)); return (0, "ok", "", False)
        self.cfg = builder.Config(env={"AI_BUILDER_CLAUDE": sys.executable, "AI_BUILDER_QUIET": "1"}, root=self.root)   # an existing binary: only checked, never run
        self.manager = builder.JobManager(self.cfg, runner=runner)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.manager, self.cfg, "t"))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close); self.addCleanup(self.httpd.shutdown)

    def call(self, method, path, body=None, headers=None):
        c = HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Content-Type": "application/json", **(headers or {})}
        c.request(method, path, body if isinstance(body, (str, bytes)) or body is None else json.dumps(body), h)
        r = c.getresponse(); data = json.loads(r.read() or b"{}"); c.close(); return r.status, data

    def test_health_and_binding(self):
        self.assertEqual(self.call("GET", "/health")[1]["status"], "ok")
        self.assertEqual(self.httpd.server_address[0], "127.0.0.1")
        self.assertEqual(builder.Config(env={"AI_BUILDER_HOST": "0.0.0.0"}).host, "127.0.0.1")

    def test_generate_then_status(self):
        st, data = self.call("POST", "/generate", {"name": "my-demo", "description": "Demonstrate something useful"})
        self.assertEqual((st, data["status"]), (202, "running"))
        for _ in range(100):
            st, s = self.call("GET", f"/status/{data['job_id']}")
            if s["status"] in ("completed", "failed"): break
            time.sleep(0.1)
        self.assertEqual((s["status"], s["validation"]["passed"]), ("completed", True)); self.assertIn("usecase.yaml", s["files"])

    def test_invalid_requests(self):
        self.assertEqual(self.call("POST", "/generate", {"name": "../x", "description": "Demonstrate something useful"})[0], 400)
        self.assertEqual(self.call("POST", "/generate", {"name": "cnpg-standard", "description": "Demonstrate something useful"})[0], 409)
        self.assertEqual(self.call("POST", "/generate", "{not json")[0], 400)
        self.assertEqual(self.call("POST", "/generate", {"name": "my-demo"}, {"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.call("POST", "/generate", "x" * 20000)[0], 413)
        self.assertEqual(self.call("POST", "/other", {})[0], 404)
        self.assertEqual(self.call("GET", "/status/..%2f..%2fetc")[0], 404)
        self.assertEqual(self.call("GET", "/nothing")[0], 404)

    def test_review_approve_publish_over_http(self):
        _, d = self.call("POST", "/generate", {"name": "my-demo", "description": "Demonstrate something useful"})
        for _ in range(100):
            if self.call("GET", f"/status/{d['job_id']}")[1]["status"] in ("completed", "failed"): break
            time.sleep(0.1)
        self.assertIn("README.md", self.call("GET", f"/review/{d['job_id']}")[1]["content"])
        self.assertEqual(self.call("POST", f"/publish/{d['job_id']}")[0], 409)
        self.assertEqual(self.call("POST", f"/approve/{d['job_id']}")[0], 200)
        st, out = self.call("POST", f"/publish/{d['job_id']}")
        self.assertEqual((st, out["published"]), (200, "usecases/my-demo")); self.assertEqual(self.call("POST", "/publish/zzz")[0], 404)

    def test_foreign_host_header_refused(self):
        self.assertEqual(self.call("GET", "/health", headers={"Host": "evil.example"})[0], 403)

    def test_missing_cli_is_reported(self):
        self.cfg.claude = "definitely-not-installed-claude"
        self.assertEqual(self.call("POST", "/generate", {"name": "my-demo", "description": "Demonstrate something useful"})[0], 503)


class ExecutionManager(Base):
    """P1.1: explicit model, per-call limits, JSON result parsing, usage persistence. No real Claude call."""
    REQ = {"name": "my-demo", "description": "Demonstrate something useful", "reference_usecase": "cnpg-standard"}
    RESULT = {"type": "result", "subtype": "success", "is_error": False, "result": "created the files", "num_turns": 3,
              "duration_ms": 4200, "duration_api_ms": 4000, "total_cost_usd": 0.0421, "stop_reason": "end_turn",
              "usage": {"input_tokens": 10, "output_tokens": 500, "cache_read_input_tokens": 3000, "cache_creation_input_tokens": 700},
              "modelUsage": {"claude-sonnet-5-5": {"inputTokens": 10, "outputTokens": 500, "cacheReadInputTokens": 3000,
                                                    "cacheCreationInputTokens": 700, "costUSD": 0.0421}}}

    def run_with(self, out, rc=0, timed_out=False, env=None, good=True):
        def runner(args, cwd, tmo):
            if good: write_good(draft_from_args(args))
            return rc, out, "", timed_out
        cfg = builder.Config(env=env or {}, root=self.root)
        m = builder.JobManager(cfg, runner=runner)
        job = m.submit(self.REQ, background=False); m.run(job["job_id"], self.REQ)
        return m, m.get(job["job_id"])

    # --- configuration ---
    def test_model_defaults_to_sonnet_and_is_always_explicit(self):
        cfg = builder.Config(env={}, root=self.root)
        self.assertEqual((cfg.model, cfg.timeout, cfg.max_budget_usd), ("sonnet", 900, 3.0))
        a = builder.claude_args(cfg, "p", cfg.state / "drafts" / "j" / "x")
        self.assertEqual(a[a.index("--model") + 1], "sonnet")
        self.assertEqual(a[a.index("--output-format") + 1], "json")
        self.assertEqual(a[a.index("--max-budget-usd") + 1], "3")

    def test_model_budget_timeout_are_configurable(self):
        cfg = builder.Config(env={"AI_BUILDER_MODEL": "opus", "AI_BUILDER_MAX_BUDGET_USD": "1.5", "AI_BUILDER_TIMEOUT": "120"}, root=self.root)
        a = builder.claude_args(cfg, "p", cfg.state / "drafts" / "j" / "x")
        self.assertEqual((a[a.index("--model") + 1], a[a.index("--max-budget-usd") + 1], cfg.timeout), ("opus", "1.5", 120))

    def test_blank_or_bad_limits_fall_back_to_defaults_never_to_unlimited(self):
        for bad in ("", "0", "-2", "abc", "nan"):
            cfg = builder.Config(env={"AI_BUILDER_MAX_BUDGET_USD": bad, "AI_BUILDER_TIMEOUT": bad, "AI_BUILDER_MODEL": ""}, root=self.root)
            self.assertEqual((cfg.max_budget_usd, cfg.timeout, cfg.model), (3.0, 900, "sonnet"), bad)

    def test_unsafe_model_name_is_refused(self):
        with self.assertRaises(RuntimeError):
            builder.Config(env={"AI_BUILDER_MODEL": "x; rm -rf /"}, root=self.root)

    def test_permissions_unchanged(self):
        cfg = builder.Config(env={}, root=self.root)
        a = builder.claude_args(cfg, "p", cfg.state / "drafts" / "j" / "x")
        self.assertIn("--tools=Read,Glob,Grep,Write,Edit,WebSearch,WebFetch", a); self.assertIn("--permission-mode=dontAsk", a)
        self.assertIn("--no-session-persistence", a)
        deny = next(x for x in a if x.startswith("--disallowedTools="))
        self.assertIn("Bash", deny.split(",")); self.assertNotIn("WebSearch", deny.split(","))
        self.assertFalse(any("Bash" in x for x in a if x.startswith(("--tools=", "--allowedTools="))))
        allowed = next(x for x in a if x.startswith("--allowedTools=")).split("=", 1)[1].split(",")
        self.assertIn("WebSearch", allowed); self.assertIn("WebFetch", allowed)
        prompt = builder.build_prompt({"name": "x", "description": "d", "reference_usecase": "cnpg-standard"}, cfg.state / "drafts" / "j" / "x")
        self.assertIn("ai-builder/.claude/skills/playground-usecase-builder/SKILL.md", prompt); self.assertIn("WebSearch", prompt)

    # --- JSON parsing ---
    def test_parse_full_result(self):
        u = builder.extract_usage(builder.parse_claude_json(json.dumps(self.RESULT)))
        self.assertEqual((u["input_tokens"], u["output_tokens"], u["cache_read_input_tokens"], u["cache_creation_input_tokens"]), (10, 500, 3000, 700))
        self.assertEqual((u["total_cost_usd"], u["duration_ms"], u["num_turns"], u["subtype"]), (0.0421, 4200, 3, "success"))
        self.assertEqual(u["models"]["claude-sonnet-5-5"]["cost_usd"], 0.0421)

    def test_parse_tolerates_stray_line_and_array(self):
        self.assertEqual(builder.parse_claude_json("warning\n" + json.dumps(self.RESULT))["subtype"], "success")
        self.assertEqual(builder.parse_claude_json(json.dumps([{"type": "system"}, self.RESULT]))["subtype"], "success")

    def test_missing_and_malformed_usage_become_none_without_raising(self):
        for out in ("", "not json", "[]", "null", "{}", json.dumps({"usage": "x", "total_cost_usd": "free", "modelUsage": [1],
                                                                     "duration_ms": -5, "num_turns": True})):
            u = builder.extract_usage(builder.parse_claude_json(out))
            if u is not None:
                self.assertTrue(all(u[k] is None for k in ("input_tokens", "total_cost_usd", "duration_ms", "num_turns")), out)
                self.assertEqual(u["models"], {})
        self.assertIsNone(builder.extract_usage(None))

    def test_partial_usage_keeps_what_is_present(self):
        u = builder.extract_usage({"usage": {"output_tokens": 7}, "total_cost_usd": 1})
        self.assertEqual((u["output_tokens"], u["input_tokens"], u["total_cost_usd"]), (7, None, 1.0))

    def test_sum_usage(self):
        a = {"usage": builder.extract_usage(self.RESULT)}
        t = builder.sum_usage([a, {"usage": None}, a])
        self.assertEqual((t["output_tokens"], t["calls"], t["calls_with_usage"], t["total_cost_usd"]), (1000, 3, 2, 0.0842))
        self.assertIsNone(builder.sum_usage([{"usage": None}])); self.assertIsNone(builder.sum_usage([]))

    # --- through the job lifecycle ---
    def test_success_persists_usage_and_reply_not_raw_json(self):
        m, j = self.run_with(json.dumps(self.RESULT))
        self.assertEqual((j["status"], j["validated"]), ("completed", True))
        att = j["attempts"][0]
        self.assertEqual((att["model"], att["timeout"], att["max_budget_usd"]), ("sonnet", 900, 3.0))
        self.assertEqual(att["usage"]["output_tokens"], 500); self.assertEqual(att["output_tail"], "created the files")
        self.assertEqual(j["usage"]["total_cost_usd"], 0.0421)
        saved = json.loads((self.root / ".ai-builder" / "jobs" / f"{j['job_id']}.json").read_text())
        self.assertEqual(saved["usage"]["cache_read_input_tokens"], 3000)
        view = builder.public_view(m.get(j["job_id"]), detail=True)
        self.assertEqual(view["usage"]["calls"], 1); self.assertEqual(view["claude"][0]["usage"]["models"]["claude-sonnet-5-5"]["input_tokens"], 10)

    def test_missing_usage_does_not_fail_a_good_job(self):
        _, j = self.run_with("plain text from an old CLI")
        self.assertEqual(j["status"], "completed"); self.assertIsNone(j["attempts"][0]["usage"]); self.assertIsNone(j["usage"])
        self.assertEqual(j["attempts"][0]["output_tail"], "plain text from an old CLI")

    def test_correction_attempt_usage_is_added_up(self):
        calls = []
        def runner(args, cwd, tmo):
            calls.append(1); d = draft_from_args(args); write_good(d)
            if len(calls) == 1: (d / "usecase.yaml").unlink()
            return 0, json.dumps(self.RESULT), "", False
        m = builder.JobManager(builder.Config(env={}, root=self.root), runner=runner)
        job = m.submit(self.REQ, background=False); m.run(job["job_id"], self.REQ); j = m.get(job["job_id"])
        self.assertEqual((j["status"], j["usage"]["calls"], j["usage"]["output_tokens"]), ("completed", 2, 1000))

    def test_budget_exhaustion_is_reported_and_keeps_usage(self):
        out = json.dumps({"type": "result", "subtype": "error_max_budget_usd", "is_error": True, "total_cost_usd": 3.01,
                          "errors": ["Reached maximum budget ($3)"], "usage": {"input_tokens": 0, "output_tokens": 0}})
        _, j = self.run_with(out, rc=1, good=False)
        self.assertEqual(j["status"], "failed"); self.assertIn("per-call budget of $3", j["error"]); self.assertNotIn("exited with code", j["error"])
        self.assertEqual(j["attempts"][0]["usage"]["subtype"], "error_max_budget_usd")
        self.assertIn("Reached maximum budget", j["attempts"][0]["output_tail"]); self.assertEqual(j["usage"]["total_cost_usd"], 3.01)

    def test_budget_message_uses_the_configured_value(self):
        out = json.dumps({"subtype": "error_max_budget_usd", "is_error": True, "errors": ["x"]})
        _, j = self.run_with(out, rc=1, good=False, env={"AI_BUILDER_MAX_BUDGET_USD": "0.5"})
        self.assertIn("$0.5", j["error"])

    def test_is_error_with_exit_zero_fails_the_job(self):
        out = json.dumps({"subtype": "error_during_execution", "is_error": True, "errors": ["boom"]})
        _, j = self.run_with(out, rc=0, good=False)
        self.assertEqual(j["status"], "failed"); self.assertIn("error_during_execution", j["error"])

    def test_timeout_is_reported_with_the_configured_value(self):
        _, j = self.run_with("", rc=-9, timed_out=True, good=False, env={"AI_BUILDER_TIMEOUT": "120"})
        self.assertEqual((j["status"], j["error"]), ("failed", "Claude Code timed out after 120s"))

    def test_timeout_kills_the_whole_process_tree(self):
        pidfile = self.root / "grandchild.pid"
        script = f"sleep 300 & echo $! > {pidfile}; wait"
        t = time.time(); rc, out, err, timed_out = builder.run_process(["sh", "-c", script], str(self.root), 1)
        self.assertTrue(timed_out); self.assertLess(time.time() - t, 15)
        pid = int(pidfile.read_text()); gone = False
        for _ in range(50):
            try: os.kill(pid, 0)
            except ProcessLookupError: gone = True; break
            except PermissionError: break
            time.sleep(0.1)
        if not gone:
            try: os.kill(pid, 9)
            except OSError: pass
        self.assertTrue(gone, "the grandchild survived the timeout")

    def test_job_files_from_before_usage_tracking_still_load(self):
        old = {"job_id": "20260101-000000-abcdef", "name": "legacy", "status": "completed", "phase": "done", "created": "x", "updated": "x",
               "draft": ".ai-builder/drafts/20260101-000000-abcdef/legacy", "files": [], "review": {"state": "pending"}, "published": False,
               "validation": {"passed": True, "errors": []}, "validated": True,
               "attempts": [{"kind": "generation", "exit_code": 0, "timed_out": False, "seconds": 1.0, "output_tail": "t", "error_tail": ""}], "error": None}
        (self.root / ".ai-builder" / "jobs").mkdir(parents=True, exist_ok=True)
        (self.root / ".ai-builder" / "jobs" / "20260101-000000-abcdef.json").write_text(json.dumps(old))
        m = builder.JobManager(builder.Config(env={}, root=self.root))
        view = builder.public_view(m.get("20260101-000000-abcdef"), detail=True)
        self.assertEqual((view["status"], view["attempts"], view["usage"]), ("completed", 1, None)); self.assertEqual(view["claude"][0]["output_tail"], "t")


if __name__ == "__main__":
    unittest.main(verbosity=1)
