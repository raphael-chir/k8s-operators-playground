"""Builds the page used by tests/ui-browser.sh: the REAL web/static/index.html, style.css, ai-builder.css, ai-markdown.js and
ai-builder.js, with
  * a stand-in terminal (an iframe that counts its own window resize events, as ttyd's xterm refit does) in #panes,
  * a stubbed fetch for /api/ai-builder/* (no backend, no Docker, no Claude),
  * a driver that exercises the panel in a real layout engine and writes its measurements to <pre id="out">.
Usage: ui_browser_page.py <out.html> <mode: wide|narrow|saved> [dark]. Nothing here starts a container or calls Claude."""
import json
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "web" / "static"
out, mode = sys.argv[1], sys.argv[2]
dark = len(sys.argv) > 3 and sys.argv[3] == "dark"

html = (SRC / "index.html").read_text()
for name in ("style.css", "ai-builder.css"):
    html = html.replace(f'href="{name}"', f'href="file://{SRC}/{name}"')
for name in ("app.js", "ai-markdown.js", "ai-builder.js"):
    html = html.replace(f'<script src="{name}"></script>', "")
if dark:
    html = html.replace('<html lang="en">', '<html lang="en" data-theme="dark">')

CID = "c-20261117-120000-abc123"
USAGE = {"input_tokens": 4, "output_tokens": 310, "cache_read_input_tokens": 3200, "cache_creation_input_tokens": 900}
REPLY = ("Here is the **plan**:\n\n1. Install the cluster\n2. Check the replicas\n\n```bash\nkubectl get pods --all-namespaces # list everything with a very long comment that must scroll inside the block and never widen the panel at all\n```\n\n"
         "| name | role |\n|---|:-:|\n| cnpg-1 | primary |\n\n<img src=x onerror=\"window.__xss=true\"> <script>window.__xss=true</script>")
msgs = []
for i in range(1, 13):
    msgs.append({"n": i, "user": f"Question {i}: what does scenario {i:02d} do?", "assistant": REPLY, "status": "ok", "model": "sonnet", "seconds": 3.1, "cost_usd": 0.04, "usage": USAGE, "edit": False, "changed": []})
ws = {"lab": "cnpg-standard", "exists": True, "editing": True, "changes": {"added": 1, "modified": 1, "deleted": 0, "total": 2}, "can_undo": True, "conflict": False, "publications": 0}
conv = {"id": CID, "title": "What does scenario 01 do?", "lab": "cnpg-standard", "status": "idle", "model": "sonnet", "messages": msgs, "pending": None, "read_only": False, "can_edit": True,
        "budget": {"limit_usd": 10, "spent_usd": 0.5, "remaining_usd": 9.5, "percent": 5, "state": "ok", "warn_at_percent": 80}, "context": {"last_tokens": 4100, "warning": False},
        "limits": {"max_turns": 100}, "workspace": ws, "turns": 12, "cost_usd": 0.5, "budget_state": "ok"}
review = {"lab": "cnpg-standard", "changes": {"modified": ["README.md"], "added": ["02_failover.sh"], "deleted": []}, "total": 2, "tree_hash": "a" * 64, "conflict": False, "can_undo": True,
          "can_publish": True, "validation": {"passed": True, "errors": []},
          "diff": [{"path": "02_failover.sh", "change": "added", "truncated": False, "diff": "--- a/02_failover.sh\n+++ b/02_failover.sh\n+#!/usr/bin/env bash\n+kubectl delete pod -l cnpg.io/instanceRole=primary # a very long line that must scroll inside the diff viewer and never widen the panel\n"}]}

stub = f"""<script>
window.__posts = []; window.__xss = false;
const R = (s, b) => Promise.resolve({{ ok: s < 300, status: s, json: async () => b }});
window.items = [{{ name: "cnpg-standard", title: "CNPG Standard" }}];
window.refreshUseCases = () => {{}}; window.refreshTerminals = () => {{}};
try {{ localStorage.clear(); localStorage.setItem("aibConv", {json.dumps(CID)}); {'localStorage.setItem("aibPanelWidth", "600");' if mode == "saved" else ""} }} catch (_) {{}}
const CONV = {json.dumps(conv).replace("</", "<\\/")}, REVIEW = {json.dumps(review).replace("</", "<\\/")};
window.fetch = (u, o = {{}}) => {{
  if (o.method === "POST") window.__posts.push({{ url: u, body: o.body ? JSON.parse(o.body) : null }});
  if (u.endsWith("/health")) return R(200, {{ available: true, state: "ready", claude_credentials_present: true, busy: false }});
  if (u.endsWith("/auth/status")) return R(200, {{ logged_in: true, session: null }});
  if (u.endsWith("/conversations")) return R(200, {{ conversations: [{{ id: CONV.id, title: CONV.title, lab: CONV.lab, status: "idle", turns: 12, cost_usd: 0.5, budget_state: "ok" }}] }});
  if (u.endsWith("/review")) return R(200, REVIEW);
  if (u.endsWith("/messages")) return R(202, {{ ...CONV, status: "running", pending: {{ n: 13, user: "x", started: new Date().toISOString(), edit: false }} }});
  if (u.endsWith(CONV.id)) return R(200, CONV);
  return R(404, {{ error: "?" }});
}};
</script>"""

driver = """<script>
const out = [], $ = id => document.getElementById(id), sleep = ms => new Promise(r => setTimeout(r, ms));
const check = (name, ok, detail) => out.push({ name, ok: !!ok, detail: String(detail === undefined ? "" : detail) });
const rect = el => el.getBoundingClientRect(), near = (a, b, t = 2) => Math.abs(a - b) <= t;
const MODE = %(mode)s, DARK = %(dark)s;
const ev = (el, type, props) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 1, button: 0, ...props }));
(async () => {
  // a stand-in for a ttyd terminal: an iframe whose own viewport size is what xterm.js refits to
  const pane = document.createElement("div"); pane.className = "pane active"; pane.dataset.count = "1";
  pane.innerHTML = '<div class="cell"><div class="cell-label"><span>Terminal 1</span></div><iframe id="tframe" srcdoc="<body style=margin:0;background:#000>terminal</body>"></iframe></div>';
  $("panes").appendChild(pane); await sleep(100);
  const frame = $("tframe"), main = $("app-main"), term = $("terminal"), panel = $("aib"), resizer = $("aib-resizer");
  const base = { term: rect(term).width, frame: rect(frame).width, main: rect(main).width };
  check("the panel is closed at first and takes no room", getComputedStyle(panel).display === "none" && getComputedStyle(resizer).display === "none", getComputedStyle(panel).display);
  check("the header button reports the closed state", $("aib-open").getAttribute("aria-expanded") === "false", $("aib-open").getAttribute("aria-expanded"));
  $("aib-open").click(); await sleep(400);
  const open = rect(panel), pr = getComputedStyle(panel);
  check("the panel is open and docked on the right of the workspace", pr.display === "flex" && near(open.right, rect(main).right, 1) && $("aib-open").getAttribute("aria-expanded") === "true", `${pr.display} ${open.right} ${rect(main).right}`);
  if (MODE === "narrow") {
    check("narrow window: the panel covers the whole screen", near(open.left, 0, 1) && near(open.top, 0, 1) && near(open.width, innerWidth, 1) && near(open.height, innerHeight, 1), JSON.stringify(open));
    check("narrow window: the divider is not offered", getComputedStyle(resizer).display === "none", getComputedStyle(resizer).display);
    check("narrow window: the workspace is NOT resized (the panel overlays it)", near(rect(term).width, base.term, 1) && near(rect(frame).width, base.frame, 1), `${rect(term).width} vs ${base.term}`);
    check("narrow window: nothing overflows horizontally", panel.scrollWidth <= panel.clientWidth + 1 && document.documentElement.scrollWidth <= innerWidth + 1, `${panel.scrollWidth}/${panel.clientWidth}`);
    main.classList.add("collapsed"); await sleep(100);
    check("narrow window: collapsing the sidebar does not hide or shrink the panel (style.css styles every aside)", near(rect(panel).height, innerHeight, 1) && getComputedStyle(panel).display === "flex", JSON.stringify(rect(panel)));
    main.classList.remove("collapsed"); await sleep(50);
    check("narrow window: the composer is inside the screen", rect($("aib-conv-send-form")).bottom <= innerHeight + 1 && rect($("aib-conv-send-form")).top > 0, JSON.stringify(rect($("aib-conv-send-form"))));
    $("aib-close").click(); await sleep(100);
    check("narrow window: closing restores the workspace", getComputedStyle(panel).display === "none" && near(rect(term).width, base.term, 1), "");
  } else {
    const w0 = open.width, expect = MODE === "saved" ? 600 : 440;
    check(`the panel opens at its ${MODE === "saved" ? "remembered" : "default"} width (${expect}px)`, near(w0, expect, 1), w0);
    check("the workspace is RESIZED, not covered: the terminal column gave up exactly the panel's width", near(rect(term).width, base.term - w0, 2), `${rect(term).width} vs ${base.term - w0}`);
    check("the terminal iframe follows its column", near(rect(frame).width, rect(term).width, 2), `${rect(frame).width} vs ${rect(term).width}`);
    check("the terminal's own viewport shrank with its column (the size xterm.js refits to; the browser then sends the resize event)", near(frame.contentWindow.innerWidth, rect(frame).width, 2) && frame.contentWindow.innerWidth < base.frame - w0 + 5, `${base.frame} -> ${frame.contentWindow.innerWidth}`);
    check("the panel and the terminal do not overlap", rect(panel).left >= rect(term).right - 5, `${rect(panel).left} vs ${rect(term).right}`);
    if (MODE === "wide") {
      const viewBefore = frame.contentWindow.innerWidth, mr = rect(main).right;
      ev(resizer, "pointerdown", { clientX: mr - w0 });
      check("during a drag the terminal iframe ignores the pointer", getComputedStyle(frame).pointerEvents === "none", getComputedStyle(frame).pointerEvents);
      ev(resizer, "pointermove", { clientX: mr - 520 }); await sleep(100);
      check("dragging the divider resizes the panel (520px)", near(rect(panel).width, 520, 1), rect(panel).width);
      check("... and the terminal column and its iframe follow", near(rect(term).width, base.term - 520, 2) && near(rect(frame).width, rect(term).width, 2), `${rect(term).width}/${rect(frame).width}`);
      ev(resizer, "pointerup", { clientX: mr - 520 }); await sleep(100);
      check("the width is persisted in localStorage", localStorage.getItem("aibPanelWidth") === "520", localStorage.getItem("aibPanelWidth"));
      check("the pointer is given back to the terminal after the drag", getComputedStyle(frame).pointerEvents !== "none", getComputedStyle(frame).pointerEvents);
      check("the terminal's own viewport follows the drag (what xterm.js refits to)", near(frame.contentWindow.innerWidth, rect(frame).width, 2) && frame.contentWindow.innerWidth !== viewBefore, `${viewBefore} -> ${frame.contentWindow.innerWidth}`);
      ev(resizer, "pointerdown", { clientX: mr - 520 }); ev(resizer, "pointermove", { clientX: 0 }); ev(resizer, "pointerup", { clientX: 0 });
      const mainW = document.getElementById("app-main").clientWidth, maxW = Math.min(Math.floor(mainW * 0.9), mainW - document.getElementById("sidebar").offsetWidth - 48);
      check("the panel never grows past its maximum (nine tenths of the window, 48px left to the terminals)", near(rect(panel).width, maxW, 1), `${rect(panel).width} vs ${maxW}`);
      ev(resizer, "pointerdown", { clientX: 0 }); ev(resizer, "pointermove", { clientX: mr }); ev(resizer, "pointerup", { clientX: mr });
      check("the panel never shrinks below its minimum (320px)", near(rect(panel).width, 320, 1), rect(panel).width);
      resizer.focus(); check("the divider is reachable with the keyboard", document.activeElement === resizer && resizer.getAttribute("role") === "separator", document.activeElement && document.activeElement.id);
      resizer.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", shiftKey: true, bubbles: true, cancelable: true })); await sleep(50);
      check("the arrow keys move the divider (+64px)", near(rect(panel).width, 384, 1) && resizer.getAttribute("aria-valuenow") === "384", rect(panel).width);
      resizer.ondblclick(); await sleep(50); check("a double click resets the width (440px)", near(rect(panel).width, 440, 1), rect(panel).width);
    }
    // layout of the conversation (12 long replies): the list scrolls inside the panel, never the page; the composer stays in view
    await sleep(300);
    const box = $("aib-conv-messages"), composer = $("aib-conv-send-form"), pr2 = rect(panel);
    check("a long conversation scrolls inside the message list", box.scrollHeight > box.clientHeight + 50 && getComputedStyle(box).overflowY === "auto", `${box.scrollHeight}/${box.clientHeight}`);
    check("the page itself never scrolls", document.documentElement.scrollHeight <= innerHeight + 1, `${document.documentElement.scrollHeight}/${innerHeight}`);
    check("the composer is sticky at the bottom of the panel, in view", rect(composer).bottom <= pr2.bottom + 1 && rect(composer).bottom <= innerHeight + 1 && rect(composer).top > pr2.top + 100, JSON.stringify(rect(composer)));
    check("the list opens scrolled to the newest message", box.scrollTop + box.clientHeight >= box.scrollHeight - 5, `${box.scrollTop}+${box.clientHeight}/${box.scrollHeight}`);
    check("nothing overflows the panel horizontally (code and diff scroll inside their block)", panel.scrollWidth <= panel.clientWidth + 1 && [...box.querySelectorAll(".aib-codeblock, .aib-table, .aib-msg")].every(e => rect(e).right <= pr2.right + 1), `${panel.scrollWidth}/${panel.clientWidth}`);
    const code = box.querySelector(".aib-codeblock pre"); check("a long code line scrolls inside its block", code && code.scrollWidth > code.clientWidth && getComputedStyle(code).overflowX === "auto", code && `${code.scrollWidth}/${code.clientWidth}`);
    // Markdown, safely
    check("Markdown: lists, strong, table, code block and a Copy button are rendered", !!(box.querySelector("ol li") && box.querySelector("strong") && box.querySelector(".aib-table table") && box.querySelector(".aib-codeblock .aib-copy")), "");
    check("Markdown: syntax highlighting produced tokens", box.querySelectorAll(".aib-codeblock .tk-flag, .aib-codeblock .tk-com").length >= 2, box.querySelectorAll(".aib-codeblock [class^=tk-]").length);
    check("Markdown: HTML in a reply stays text (no <img>, no <script>, nothing ran)", box.querySelectorAll("img, script, iframe").length === 0 && window.__xss === false && /<img src=x/.test(box.textContent), window.__xss);
    const tk = getComputedStyle(box.querySelector(".aib-codeblock .tk-com")).color, plain = getComputedStyle(box.querySelector(".aib-codeblock code")).color;
    check("code blocks use their own colors (a comment differs from the plain text)", tk !== plain, `${tk} vs ${plain}`);
    // changes: bar, review, diff, publish rules
    check("the pending-changes bar is compact and shows the counts", /2 files changed/.test($("aib-changes-text").textContent) && rect($("aib-changes")).height < 100, rect($("aib-changes")).height);
    $("aib-changes-review").click(); await sleep(300);
    check("the review opens without hiding the conversation", !$("aib-cr").hidden && rect(box).height >= 100, rect(box).height);
    check("the review is bounded in height and scrolls", rect($("aib-cr")).height <= innerHeight * 0.5, rect($("aib-cr")).height);
    check("the diff viewer colors added lines and highlights their content", $("aib-cr-diff").querySelectorAll(".aib-dl.add").length === 2 && $("aib-cr-diff").querySelectorAll(".tk-flag, .tk-kw, .tk-com").length >= 1, $("aib-cr-diff").querySelectorAll("[class^=tk-]").length);
    const addBg = getComputedStyle($("aib-cr-diff").querySelector(".aib-dl.add")).backgroundColor, ctxBg = getComputedStyle($("aib-cr-diff")).backgroundColor;
    check("added lines have a distinct background", addBg !== ctxBg && addBg !== "rgba(0, 0, 0, 0)", `${addBg} vs ${ctxBg}`);
    check("Publish needs the explicit approval", $("aib-cr-publish").disabled === true && !$("aib-cr-confirm").checked, "");
    $("aib-cr-confirm").click(); await sleep(50); check("... and is enabled once approved with a passing validation", $("aib-cr-publish").disabled === false, "");
    $("aib-changes-review").click(); await sleep(50);
    // composer: auto-grow, Enter/Shift+Enter
    const ta = $("aib-conv-input"), h0 = rect(ta).height;
    ta.focus(); ta.value = "line1\\nline2\\nline3\\nline4\\nline5\\nline6"; ta.dispatchEvent(new Event("input", { bubbles: true })); await sleep(50);
    check("the composer grows with its text, within limits", rect(ta).height > h0 + 20 && rect(ta).height <= 182, `${h0} -> ${rect(ta).height}`);
    const shift = new KeyboardEvent("keydown", { key: "Enter", shiftKey: true, bubbles: true, cancelable: true }); ta.dispatchEvent(shift);
    check("Shift+Enter is left to the browser (a new line)", shift.defaultPrevented === false && window.__posts.length === 0, window.__posts.length);
    const enter = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }); ta.dispatchEvent(enter); await sleep(200);
    check("Enter sends the message (once, with the CSRF-protected proxy call)", enter.defaultPrevented === true && window.__posts.filter(p => p.url.endsWith("/messages")).length === 1, JSON.stringify(window.__posts.map(p => p.url)));
    check("while Claude works the panel says so, shows a spinner and holds Send, but the composer stays editable", /Claude is thinking/.test($("aib-activity-text").textContent) && $("aib-activity").classList.contains("busy") && !ta.disabled && $("aib-conv-send").disabled && !$("aib-send-spinner").hidden, $("aib-activity-text").textContent);
    const dot = getComputedStyle(document.querySelector("#aib-activity .aib-pulse")); check("the busy indicator is animated (and respects reduced motion in CSS)", dot.animationName !== "none", dot.animationName);
    // generation workflow
    check("the conversation is the whole panel: no tabs, no generation form", !$("aib-tabs") && !$("aib-gen-pane") && !$("aib-chat-pane").hidden && rect($("aib-chat-pane")).height > 200, `${rect($("aib-chat-pane")).height}`);
    // keyboard and focus
    check("every icon button has an accessible name", [...panel.querySelectorAll("button")].every(b => (b.textContent.trim() || b.getAttribute("aria-label"))), "");
    $("aib-close").click(); await sleep(150);
    check("closing returns the focus to the header button and gives the room back", document.activeElement === $("aib-open") && near(rect(term).width, base.term, 2) && near(rect(frame).width, base.frame, 2), `${document.activeElement && document.activeElement.id} ${rect(term).width} vs ${base.term}`);
    if (MODE === "wide") {
      $("aib-open").click(); await sleep(300);
      check("reopening uses the width of the last drag/reset (440px after the reset)", near(rect(panel).width, 440, 1), rect(panel).width);
    }
  }
  if (DARK) {
    const cs = getComputedStyle(panel); check("dark theme: the panel uses dark surfaces and its own code colors", cs.getPropertyValue("--code-bg").trim() === "#0a171d" && cs.backgroundColor !== "rgb(255, 255, 255)", `${cs.getPropertyValue("--code-bg")} ${cs.backgroundColor}`);
  } else if (MODE !== "narrow") {
    const cs = getComputedStyle(panel); check("light theme: light surfaces and code colors", cs.getPropertyValue("--code-bg").trim() === "#f3f7f9" && cs.backgroundColor === "rgb(255, 255, 255)", `${cs.getPropertyValue("--code-bg")} ${cs.backgroundColor}`);
  }
  document.getElementById("out").textContent = JSON.stringify(out);
})().catch(e => { out.push({ name: "the driver ran to the end", ok: false, detail: String(e && e.stack || e) }); document.getElementById("out").textContent = JSON.stringify(out); });
</script>""" % {"mode": json.dumps(mode), "dark": "true" if dark else "false"}

libs = "".join(f'<script src="file://{SRC}/{n}"></script>' for n in ("ai-markdown.js", "ai-builder.js"))
html = html.replace("</body>", f'<pre id="out" hidden></pre>{stub}{libs}{driver}</body>')
Path(out).write_text(html)
