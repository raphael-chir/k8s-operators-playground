"""Tests of the AI Lab Assistant conversations. A scripted runner stands in for the Claude Code CLI: no real
Claude call, no Docker, Kubernetes or Helm. Run: tests/ai-builder.sh"""
import json
import shutil
import sys
import tempfile
import threading
import time
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "ai-builder"))
sys.path.insert(0, str(REPO / "tests"))
import builder, conversations, server  # noqa: E402
from ai_builder_test import fake_repo  # noqa: E402


def result(text="an answer", total=0.40, uuid=None, **extra):
    """What `claude -p --output-format json` prints. total_cost_usd is the CUMULATIVE cost of the session."""
    r = {"type": "result", "subtype": "success", "is_error": False, "result": text, "num_turns": 1, "duration_ms": 2000,
         "duration_api_ms": 1900, "total_cost_usd": total, "stop_reason": "end_turn",
         "usage": {"input_tokens": 4, "output_tokens": 100, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 500},
         "modelUsage": {"claude-sonnet-5-5": {"inputTokens": 4, "outputTokens": 100, "cacheReadInputTokens": 1000,
                                               "cacheCreationInputTokens": 500, "costUSD": total, "contextWindow": 1000000}}}
    if uuid:
        r["session_id"] = uuid
    r.update(extra)
    return r


def arg_after(args, flag):
    return args[args.index(flag) + 1]


class Base(unittest.TestCase):
    def setUp(self):
        self.root = fake_repo()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.env = {}
        self.calls = []                  # (args, cwd, timeout, env)
        self.script = []                 # per call: a dict (the CLI result), or a callable(args) -> (rc, out, err, timed_out)
        self.gate = None                 # optional Event that blocks the runner

    def runner(self, args, cwd, timeout, env=None):
        self.calls.append((list(args), cwd, timeout, env))
        if self.gate:
            self.gate.wait(10)
        step = self.script.pop(0) if self.script else None
        if callable(step):
            return step(args)
        if step is None:
            step = result(uuid=arg_after(args, "--resume" if "--resume" in args else "--session-id"))
        step = dict(step)
        step.setdefault("session_id", arg_after(args, "--resume" if "--resume" in args else "--session-id"))
        return 0, json.dumps(step), "", False

    def manager(self, env=None, other_busy=lambda: False):
        self.cfg = builder.Config(env={**self.env, **(env or {})}, root=self.root)
        self.cfg.claude_missing = lambda: False
        return conversations.ConversationManager(self.cfg, runner=self.runner, other_busy=other_busy)

    def say(self, m, cid, text="hello"):
        m.send(cid, text, background=False)
        return m.get(cid)


class Lifecycle(Base):
    def test_create_with_and_without_a_lab_and_persist(self):
        m = self.manager()
        free = m.create()
        self.assertEqual((free["lab"], free["status"], free["read_only"], free["messages"]), (None, "idle", True, []))
        lab = m.create("About the standard lab", "cnpg-standard")
        self.assertEqual(lab["lab"], "cnpg-standard")
        self.assertTrue((self.root / ".ai-builder" / "conversations" / f"{lab['id']}.json").is_file())
        self.assertEqual({c["id"] for c in m.list()}, {free["id"], lab["id"]})

    def test_create_validation(self):
        m = self.manager()
        for lab, status in (("nope-lab", 404), ("../x", 400), ("A_B", 400), (5, 400)):
            with self.assertRaises(builder.RequestError) as cm:
                m.create(None, lab)
            self.assertEqual(cm.exception.status, status, lab)
        with self.assertRaises(builder.RequestError):
            m.create("x" * 81)
        with self.assertRaises(builder.RequestError):
            m.create(["list"])

    def test_message_validation_and_unknown_conversation(self):
        m = self.manager(); cid = m.create()["id"]
        for bad in ("", "   ", None, 12, "x" * 4001):
            with self.assertRaises(builder.RequestError) as cm:
                m.send(cid, bad, background=False)
            self.assertEqual(cm.exception.status, 400)
        for cid2 in ("c-20200101-000000-aaaaaa", "../x", "", None):
            with self.assertRaises(builder.RequestError) as cm:
                m.send(cid2, "hi", background=False)
            self.assertEqual(cm.exception.status, 404)
        self.assertIsNone(m.get("nope"))
        self.assertEqual(self.calls, [])

    def test_title_comes_from_the_first_message(self):
        m = self.manager(); cid = m.create()["id"]
        self.assertEqual(self.say(m, cid, "What does scenario 01 do?\nMore detail")["title"], "What does scenario 01 do?")


class Sessions(Base):
    def test_first_turn_creates_the_session_then_resumes_it(self):
        m = self.manager(); cid = m.create()["id"]
        self.say(m, cid, "first question"); self.say(m, cid, "second question")
        a1, a2 = self.calls[0][0], self.calls[1][0]
        sid = arg_after(a1, "--session-id")
        self.assertNotIn("--resume", a1); self.assertNotIn("--session-id", a2)
        self.assertEqual(arg_after(a2, "--resume"), sid)
        self.assertRegex(sid, r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        self.assertEqual((a1[-1], a2[-1]), ("first question", "second question"))
        self.assertNotIn("first question", " ".join(a2), "the history is never re-sent: Claude's session carries it")
        self.assertEqual([t["resumed"] for t in m.get(cid)["messages"]], [False, True])

    def test_claude_runs_from_the_repository_with_auto_memory_off_and_json_output(self):
        m = self.manager(); cid = m.create()["id"]; self.say(m, cid)
        args, cwd, timeout, env = self.calls[0]
        self.assertEqual((cwd, timeout, env), (str(self.root), 900, {"CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"}))
        self.assertEqual((arg_after(args, "--output-format"), arg_after(args, "--model")), ("stream-json", "sonnet"))
        self.assertNotIn("--no-session-persistence", args)

    def test_sessions_survive_a_service_restart(self):
        m = self.manager(); cid = m.create("kept", "cnpg-standard")["id"]
        self.say(m, cid, "before the restart")
        sid = arg_after(self.calls[0][0], "--session-id")
        again = self.manager()                                               # a new process reading the same state directory
        view = again.get(cid)
        self.assertEqual((view["title"], view["lab"], len(view["messages"]), view["messages"][0]["user"]), ("kept", "cnpg-standard", 1, "before the restart"))
        self.say(again, cid, "after the restart")
        self.assertEqual(arg_after(self.calls[1][0], "--resume"), sid)
        self.assertEqual(len(again.get(cid)["messages"]), 2)

    def test_a_first_turn_without_a_result_gets_a_fresh_session_id(self):
        m = self.manager(); cid = m.create()["id"]
        self.script = [lambda a: (-9, "", "", True)]                         # timed out: no JSON, no session
        view = self.say(m, cid, "slow")
        self.assertEqual((view["messages"][0]["status"], view["messages"][0]["error"]), ("error", "Claude Code timed out after 900s"))
        self.say(m, cid, "again")
        first, second = self.calls[0][0], self.calls[1][0]
        self.assertIn("--session-id", second); self.assertNotEqual(arg_after(first, "--session-id"), arg_after(second, "--session-id"))

    def test_an_existing_claude_session_file_means_resume(self):
        conf = self.root / "claudeconf"; (conf / "projects" / "-workspace").mkdir(parents=True)
        m = self.manager({"CLAUDE_CONFIG_DIR": str(conf)}); cid = m.create()["id"]
        sid = json.loads((self.root / ".ai-builder" / "conversations" / f"{cid}.json").read_text())["session_id"]
        (conf / "projects" / "-workspace" / f"{sid}.jsonl").write_text("{}\n")      # Claude's file exists; only its existence is checked
        self.say(m, cid)
        self.assertEqual(arg_after(self.calls[0][0], "--resume"), sid)

    def test_the_public_view_exposes_neither_the_session_id_nor_a_transcript(self):
        m = self.manager(); cid = m.create()["id"]; self.say(m, cid)
        sid = arg_after(self.calls[0][0], "--session-id")
        text = json.dumps(m.get(cid)) + json.dumps(m.list())
        self.assertNotIn(sid, text); self.assertNotIn("session_id", text)

    def test_one_conversation_is_interrupted_mid_turn_by_a_restart(self):
        m = self.manager(); cid = m.create()["id"]; self.say(m, cid, "one")
        f = self.root / ".ai-builder" / "conversations" / f"{cid}.json"
        data = json.loads(f.read_text()); data["status"] = "running"
        data["pending"] = {"n": 2, "user": "lost question", "started": "2026-01-01T00:00:00+00:00"}
        f.write_text(json.dumps(data))
        again = self.manager(); view = again.get(cid)
        self.assertEqual((view["status"], view["pending"], view["messages"][1]["status"], view["messages"][1]["user"]), ("idle", None, "error", "lost question"))
        self.assertIn("interrupted", view["messages"][1]["error"])
        self.say(again, cid, "still usable"); self.assertEqual(len(again.get(cid)["messages"]), 3)


class ReadOnly(Base):
    def test_only_read_tools_and_everything_else_denied(self):
        m = self.manager(); cid = m.create("t", "cnpg-standard")["id"]; self.say(m, cid)
        args = self.calls[0][0]
        self.assertEqual(next(a for a in args if a.startswith("--tools=")), "--tools=Read,Glob,Grep,WebSearch,WebFetch")
        self.assertEqual(next(a for a in args if a.startswith("--allowedTools=")), "--allowedTools=WebSearch,WebFetch")
        self.assertIn("--permission-mode=dontAsk", args); self.assertIn("--strict-mcp-config", args)
        deny = next(a for a in args if a.startswith("--disallowedTools=")).split("=", 1)[1].split(",")
        for tool in ("Bash", "Write", "Edit", "NotebookEdit"):
            self.assertIn(tool, deny)
        self.assertNotIn("WebFetch", deny); self.assertNotIn("WebSearch", deny)
        prompt = args[args.index("--append-system-prompt") + 1]
        self.assertIn("ai-builder/.claude/skills/playground-usecase-builder/SKILL.md", prompt); self.assertIn("official", prompt.lower())
        self.assertNotIn("name: playground-usecase-builder", prompt, "the skill itself is read on demand, never injected")
        for rule in (f"Read(/{self.root}/.env)", f"Read(/{self.root}/.git/**)", "Read(//run/secrets/**)"):
            self.assertIn(rule, deny)
        self.assertTrue(any(r.startswith("Read(/") and "conversations/**" in r for r in deny), "other conversations are not readable")
        granted = ",".join(a.split("=", 1)[1] for a in args if a.startswith(("--tools=", "--allowedTools="))).split(",")
        self.assertEqual(sorted(set(granted)), ["Glob", "Grep", "Read", "WebFetch", "WebSearch"], "only read and research tools are ever granted")

    def test_the_policy_is_the_same_on_every_resumed_turn(self):
        m = self.manager(); cid = m.create()["id"]; self.say(m, cid); self.say(m, cid, "again")
        keep = lambda args: [a for a in args if a.startswith(("--tools=", "--allowedTools=", "--disallowedTools=", "--permission-mode"))]
        self.assertEqual(keep(self.calls[0][0]), keep(self.calls[1][0]))

    def test_the_system_prompt_states_the_limits_and_is_the_same_for_every_conversation(self):
        m = self.manager(); cid = m.create("t", "cnpg-standard")["id"]; self.say(m, cid)
        prompt = arg_after(self.calls[0][0], "--append-system-prompt")
        for needle in ("Read-only by default", "cannot write, edit or run commands", conversations.builder.SKILL_PATH):
            self.assertIn(needle, prompt)
        self.assertNotIn("usecases/cnpg-standard", prompt); self.assertEqual(prompt, conversations.system_prompt(None))
        self.assertEqual(conversations.system_prompt("x"), conversations.system_prompt(None)); self.assertIn("usecases/cnpg-standard/", self.calls[0][0][-1])

    def test_a_message_can_never_be_read_as_an_option(self):
        m = self.manager(); cid = m.create()["id"]; self.say(m, cid, "--dangerously-skip-permissions")
        self.assertFalse(self.calls[0][0][-1].startswith("-"))
        self.assertEqual(self.calls[0][0][-1].strip(), "--dangerously-skip-permissions")
        self.assertNotIn("--dangerously-skip-permissions", self.calls[0][0][:-1])

    def test_no_published_lab_or_draft_is_written(self):
        m = self.manager(); cid = m.create("t", "cnpg-standard")["id"]
        before = sorted(str(p.relative_to(self.root)) for p in (self.root / "usecases").rglob("*"))
        self.say(m, cid, "change the lab please")
        self.assertEqual(sorted(str(p.relative_to(self.root)) for p in (self.root / "usecases").rglob("*")), before)
        self.assertFalse((self.root / ".ai-builder" / "drafts").exists() and any((self.root / ".ai-builder" / "drafts").iterdir()))


class Usage(Base):
    def test_turn_cost_is_the_difference_of_the_cumulative_totals(self):
        m = self.manager(); cid = m.create()["id"]
        self.script = [result(total=0.40), result(total=0.42), result(total=0.50)]
        for q in ("a", "b", "c"):
            self.say(m, cid, q)
        v = m.get(cid)
        self.assertEqual([t["cost_usd"] for t in v["messages"]], [0.4, 0.02, 0.08])
        self.assertEqual([t["cli_total_cost_usd"] for t in v["messages"]], [0.4, 0.42, 0.5])
        self.assertEqual((v["usage"]["cost_usd"], v["usage"]["cost_basis"], v["cost_basis"]), (0.5, "api_equivalent_estimate", "api_equivalent_estimate"))

    def test_tokens_are_per_call_and_summed(self):
        m = self.manager(); cid = m.create()["id"]; self.say(m, cid); self.say(m, cid)
        u = m.get(cid)["usage"]
        self.assertEqual((u["input_tokens"], u["output_tokens"], u["cache_read_input_tokens"], u["cache_creation_input_tokens"], u["turns"]), (8, 200, 2000, 1000, 2))

    def test_a_new_session_restarts_the_cumulative_total(self):
        m = self.manager(); cid = m.create()["id"]
        self.script = [lambda a: (-9, "", "", True), result(total=0.30), result(total=0.35)]
        for q in ("a", "b", "c"):
            self.say(m, cid, q)
        costs = [t["cost_usd"] for t in m.get(cid)["messages"]]
        self.assertEqual(costs, [None, 0.3, 0.05])
        self.assertEqual(m.get(cid)["usage"]["unmetered_turns"], 1)

    def test_a_total_that_goes_down_is_taken_as_reported(self):
        m = self.manager(); cid = m.create()["id"]; self.script = [result(total=0.50), result(total=0.10)]
        self.say(m, cid); self.say(m, cid)
        self.assertEqual([t["cost_usd"] for t in m.get(cid)["messages"]], [0.5, 0.1])

    def test_missing_usage_does_not_break_the_turn(self):
        m = self.manager(); cid = m.create()["id"]
        self.script = [lambda a: (0, json.dumps({"result": "bare answer", "session_id": arg_after(a, "--session-id")}), "", False)]
        t = self.say(m, cid)["messages"][0]
        self.assertEqual((t["status"], t["assistant"], t["cost_usd"], t["context_tokens"]), ("ok", "bare answer", None, None))
        self.assertEqual(m.get(cid)["usage"]["input_tokens"], 0)

    def test_context_growth_is_tracked(self):
        m = self.manager({"AI_BUILDER_CONTEXT_WARN": "2000"}); cid = m.create()["id"]
        small = result(total=0.1)
        big = result(total=0.2, usage={"input_tokens": 10, "output_tokens": 50, "cache_read_input_tokens": 3000, "cache_creation_input_tokens": 600})
        self.script = [small, big]; self.say(m, cid); c1 = m.get(cid)["context"]
        self.assertEqual((c1["last_tokens"], c1["warning"], c1["window"], c1["sessions"]), (1504, False, 1000000, 1))
        self.say(m, cid); c2 = m.get(cid)["context"]
        self.assertEqual((c2["last_tokens"], c2["peak_tokens"], c2["warning"]), (3610, 3610, True))

    def test_every_view_labels_costs_as_estimates_and_states_the_limits(self):
        m = self.manager({"AI_BUILDER_MODEL": "opus", "AI_BUILDER_MAX_BUDGET_USD": "2", "AI_BUILDER_TIMEOUT": "300"}); v = m.create()
        self.assertEqual((v["model"], v["limits"]["max_budget_usd_per_call"], v["limits"]["timeout_seconds"], v["cost_basis"]), ("opus", 2.0, 300, "api_equivalent_estimate"))


class Budget(Base):
    def test_warning_at_80_percent_and_stop_at_100(self):
        m = self.manager({"AI_BUILDER_CONVERSATION_BUDGET_USD": "1"}); cid = m.create()["id"]
        self.script = [result(total=0.50), result(total=0.85), result(total=1.05)]
        self.say(m, cid); self.assertEqual(m.get(cid)["budget"]["state"], "ok")
        self.say(m, cid); b = m.get(cid)["budget"]
        self.assertEqual((b["state"], b["percent"], b["warn_at_percent"]), ("warning", 85.0, 80))
        self.say(m, cid); b = m.get(cid)["budget"]
        self.assertEqual((b["state"], b["remaining_usd"]), ("exhausted", 0.0))
        n = len(self.calls)
        with self.assertRaises(builder.RequestError) as cm:
            m.send(cid, "one more", background=False)
        self.assertEqual(cm.exception.status, 409); self.assertIn("budget", str(cm.exception)); self.assertEqual(len(self.calls), n, "no Claude call at 100%")

    def test_the_call_cap_never_exceeds_what_is_left_of_the_budget(self):
        m = self.manager({"AI_BUILDER_CONVERSATION_BUDGET_USD": "1", "AI_BUILDER_MAX_BUDGET_USD": "3"}); cid = m.create()["id"]
        self.script = [result(total=0.90)]
        self.say(m, cid); self.say(m, cid)
        self.assertEqual(arg_after(self.calls[0][0], "--max-budget-usd"), "1")
        self.assertEqual(arg_after(self.calls[1][0], "--max-budget-usd"), "0.1")

    def test_the_per_call_limit_applies_when_it_is_smaller(self):
        m = self.manager({"AI_BUILDER_CONVERSATION_BUDGET_USD": "10", "AI_BUILDER_MAX_BUDGET_USD": "0.5"}); cid = m.create()["id"]; self.say(m, cid)
        self.assertEqual(arg_after(self.calls[0][0], "--max-budget-usd"), "0.5")

    def test_a_per_call_budget_stop_is_a_failed_turn_that_keeps_its_cost(self):
        m = self.manager(); cid = m.create()["id"]
        stop = {"type": "result", "subtype": "error_max_budget_usd", "is_error": True, "errors": ["Reached maximum budget ($3)"], "total_cost_usd": 0.7,
                "usage": {"input_tokens": 0, "output_tokens": 0}}
        self.script = [lambda a: (1, json.dumps({**stop, "session_id": arg_after(a, "--session-id")}), "", False)]
        t = self.say(m, cid)["messages"][0]
        self.assertEqual((t["status"], t["cost_usd"]), ("error", 0.7)); self.assertIn("per-call budget", t["error"])
        self.say(m, cid, "next"); self.assertIn("--resume", self.calls[1][0], "the session exists even after a budget stop")

    def test_budget_is_kept_per_conversation_when_the_setting_changes(self):
        m = self.manager({"AI_BUILDER_CONVERSATION_BUDGET_USD": "4"}); cid = m.create()["id"]
        self.assertEqual(self.manager({"AI_BUILDER_CONVERSATION_BUDGET_USD": "9"}).get(cid)["budget"]["limit_usd"], 4.0)

    def test_blank_or_bad_budget_falls_back_to_the_default(self):
        for bad in ("", "0", "-1", "abc"):
            self.assertEqual(self.manager({"AI_BUILDER_CONVERSATION_BUDGET_USD": bad}).cfg.conversation_budget_usd, 10.0)


class Concurrency(Base):
    def test_one_invocation_at_a_time_per_conversation(self):
        m = self.manager(); a, b = m.create()["id"], m.create()["id"]
        self.gate = threading.Event()
        m.send(a, "slow one")
        self.assertTrue(m.busy()); self.assertEqual(m.get(a)["status"], "running"); self.assertEqual(m.get(a)["pending"]["user"], "slow one")
        with self.assertRaises(builder.RequestError) as cm:
            m.send(a, "second at the same time")
        self.assertEqual(cm.exception.status, 409)
        m.send(b, "another conversation is allowed")
        with self.assertRaises(builder.RequestError) as cm:
            m.send(m.create()["id"], "a third run is over the global limit")
        self.assertEqual(cm.exception.status, 409)
        self.gate.set()
        for _ in range(100):
            if not m.busy():
                break
            time.sleep(0.05)
        self.assertFalse(m.busy()); self.assertEqual((len(m.get(a)["messages"]), len(m.get(b)["messages"])), (1, 1))
        self.assertEqual(len(self.calls), 2, "the refused messages never reached Claude")

    def test_no_turn_while_a_sign_in_is_active(self):
        m = self.manager(other_busy=lambda: True); cid = m.create()["id"]
        with self.assertRaises(builder.RequestError) as cm:
            m.send(cid, "hi", background=False)
        self.assertEqual(cm.exception.status, 409); self.assertIn("sign-in", str(cm.exception)); self.assertEqual(self.calls, [])

    def test_missing_cli_is_refused_before_anything_starts(self):
        m = self.manager(); m.cfg.claude_missing = lambda: True; cid = m.create()["id"]
        with self.assertRaises(builder.RequestError) as cm:
            m.send(cid, "hi", background=False)
        self.assertEqual(cm.exception.status, 503); self.assertEqual(m.get(cid)["status"], "idle")

    def test_an_unexpected_error_never_leaves_the_conversation_running(self):
        m = self.manager(); cid = m.create()["id"]
        self.runner = lambda *a, **k: (_ for _ in ()).throw(ValueError("boom"))
        m.runner = self.runner
        v = self.say(m, cid)
        self.assertEqual((v["status"], v["messages"][0]["status"], v["messages"][0]["error"]), ("idle", "error", "internal error: ValueError"))

    def test_a_conversation_has_a_message_limit(self):
        m = self.manager(); cid = m.create()["id"]
        m.convs[cid]["turns"] = [{"n": i, "user": "q", "assistant": "a", "status": "ok", "cost_usd": 0.0, "usage": None} for i in range(conversations.MAX_TURNS)]
        with self.assertRaises(builder.RequestError) as cm:
            m.send(cid, "one too many", background=False)
        self.assertEqual(cm.exception.status, 409)

    def test_a_long_reply_is_shortened_for_storage(self):
        m = self.manager(); cid = m.create()["id"]; self.script = [result(text="x" * (conversations.MAX_REPLY + 500))]
        t = self.say(m, cid)["messages"][0]
        self.assertLess(len(t["assistant"]), conversations.MAX_REPLY + 40); self.assertTrue(t["assistant"].endswith("[reply shortened]"))


class Http(Base):
    def setUp(self):
        super().setUp()
        self.cfg = builder.Config(env={"AI_BUILDER_CLAUDE": sys.executable, "AI_BUILDER_QUIET": "1"}, root=self.root)   # existing binary, never run
        self.jobs = builder.JobManager(self.cfg, runner=lambda a, c, t: (0, "", "", False))
        self.convs = conversations.ConversationManager(self.cfg, runner=self.runner)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.jobs, self.cfg, "t", convs=self.convs))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close); self.addCleanup(self.httpd.shutdown)

    def call(self, method, path, body=None, ctype="application/json"):
        c = HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
            c.request(method, path, body=data, headers={"Content-Type": ctype} if data is not None else {})
            r = c.getresponse(); raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
        finally:
            c.close()

    def test_conversation_routes_end_to_end(self):
        st, conv = self.call("POST", "/conversations", {"lab": "cnpg-standard"})
        self.assertEqual((st, conv["lab"], conv["read_only"], conv["can_edit"]), (201, "cnpg-standard", False, True))
        self.assertEqual(self.call("POST", "/conversations", {})[1]["read_only"], True, "without a Lab nothing can be edited")
        cid = conv["id"]
        self.assertEqual(self.call("POST", "/conversations", None)[0], 201)            # an empty body is a conversation without a Lab
        st, out = self.call("POST", f"/conversations/{cid}/messages", {"message": "Explain scenario 01"})
        self.assertEqual(st, 202)
        for _ in range(100):
            st, view = self.call("GET", f"/conversations/{cid}")
            if view["status"] == "idle" and view["messages"]:
                break
            time.sleep(0.05)
        self.assertEqual((view["messages"][0]["assistant"], view["messages"][0]["user"]), ("an answer", "Explain scenario 01"))
        st, listing = self.call("GET", "/conversations")
        self.assertEqual((st, cid in {c["id"] for c in listing["conversations"]}), (200, True))

    def test_bad_requests(self):
        cid = self.call("POST", "/conversations", {})[1]["id"]
        self.assertEqual(self.call("GET", "/conversations/c-20200101-000000-aaaaaa")[0], 404)
        self.assertEqual(self.call("GET", "/conversations/..%2f..%2fetc")[0], 404)
        self.assertEqual(self.call("POST", f"/conversations/{cid}/messages", {"message": ""})[0], 400)
        self.assertEqual(self.call("POST", f"/conversations/{cid}/messages", {"nothing": 1})[0], 400)
        self.assertEqual(self.call("POST", f"/conversations/{cid}/messages", b"not json")[0], 400)
        self.assertEqual(self.call("POST", f"/conversations/{cid}/messages", b'{"message":"x"}', ctype="text/plain")[0], 415)
        self.assertEqual(self.call("POST", "/conversations", {"lab": "nope-lab"})[0], 404)
        self.assertEqual(self.call("POST", "/conversations/c-20200101-000000-aaaaaa/messages", {"message": "x"})[0], 404)
        self.assertEqual(self.call("POST", "/conversations/x/y/z", {})[0], 404)

    def test_a_4000_character_message_with_wide_characters_is_accepted(self):
        cid = self.call("POST", "/conversations", {})[1]["id"]
        self.assertEqual(self.call("POST", f"/conversations/{cid}/messages", {"message": "é" * 4000})[0], 202)

    def test_the_generation_routes_still_work_next_to_the_conversations(self):
        self.assertEqual(self.call("GET", "/health")[0], 200)
        self.assertEqual(self.call("POST", "/generate", {"name": "x"})[0], 400)
        self.assertEqual(self.call("GET", "/status/20200101-000000-aaaaaa")[0], 404)


class SignInGuard(Base):
    def test_a_running_conversation_blocks_a_sign_in_and_the_reverse(self):
        import auth
        m = self.manager()
        am = auth.AuthManager(self.cfg, generation_busy=lambda: m.busy())
        cid = m.create()["id"]; self.gate = threading.Event()
        m.send(cid, "slow")
        with self.assertRaises(auth.AuthError):
            am.start("claudeai", None)
        self.gate.set()
        for _ in range(100):
            if not m.busy():
                break
            time.sleep(0.05)


if __name__ == "__main__":
    unittest.main(verbosity=1)
