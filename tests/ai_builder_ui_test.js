// UI tests for the AI Builder panel (web/static/ai-builder.js). No browser, no network, no Docker, no Claude:
//  1. the pure logic is called directly;
//  2. the real script is run in a vm sandbox against a FAKE DOM (every element id must exist in index.html) and a
//     scripted fetch, to check the calls it makes (URLs, headers, order), the double-click guards and the error states;
//  3. static rules (no innerHTML, no direct port, no credentials).
// Not covered (manual checklist in docs/ai-builder.md): real rendering, layout, themes, focus behavior.
// Run: tests/ui.sh
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const ROOT = path.resolve(__dirname, "..");
const SRC = fs.readFileSync(path.join(ROOT, "web/static/ai-builder.js"), "utf8");
const HTML = fs.readFileSync(path.join(ROOT, "web/static/index.html"), "utf8");
const CSS = fs.readFileSync(path.join(ROOT, "web/static/ai-builder.css"), "utf8");
const STYLE = fs.readFileSync(path.join(ROOT, "web/static/style.css"), "utf8");
const MD_SRC = fs.readFileSync(path.join(ROOT, "web/static/ai-markdown.js"), "utf8");
const HTML_IDS = new Set([...HTML.matchAll(/\sid="([^"]+)"/g)].map(m => m[1]));
const core = require(path.join(ROOT, "web/static/ai-builder.js"));

let failures = 0;
const queue = [];
const test = (name, fn) => queue.push({ name, fn });
const tick = async (n = 6) => { for (let i = 0; i < n; i++) await new Promise(r => setImmediate(r)); };

// ---------------------------------------------------------------------------------------------------------------------
// 1. Pure logic
// ---------------------------------------------------------------------------------------------------------------------
test("error messages keep the upstream message and details", () => {
  assert.strictEqual(core.formatError({ status: 409, data: { error: "a generation job is already running (one at a time)" } }), "a generation job is already running (one at a time)");
  assert.match(core.formatError({ status: 400, data: { error: "invalid request", details: ["name: bad", "description: short"] } }), /invalid request name: bad · description: short/);
  assert.match(core.formatError({ status: 502, data: {} }), /HTTP 502/);
});
test("availability states: ready, not signed in, stopped, not configured, timeout, unreachable", () => {
  const ok = core.describeHealth({ available: true, state: "ready", claude_credentials_present: true });
  assert.deepStrictEqual([ok.level, ok.canGenerate, ok.banner], ["ok", true, ""]); assert.match(ok.badge, /signed in/);
  const host = core.describeHealth({ available: true, state: "ready", claude_credentials_present: null }); assert.ok(host.canGenerate);
  const login = core.describeHealth({ available: true, state: "not_signed_in", claude_credentials_present: false });
  assert.strictEqual(login.canGenerate, false); assert.strictEqual(login.needsConnect, true); assert.match(login.banner, /Connect to Claude/);
  const expired = core.describeHealth({ available: true, state: "ready", claude_credentials_present: true }, false, { logged_in: false });
  assert.deepStrictEqual([expired.canGenerate, expired.needsConnect, expired.badge], [false, true, "Claude session expired"]);
  assert.strictEqual(core.describeHealth({ available: true, state: "ready" }, false, { logged_in: null }).canGenerate, true, "an unknown status never blocks");
  assert.strictEqual(core.describeHealth({ available: true, state: "ready" }, false, { logged_in: true }).canGenerate, true);
  const stopped = core.describeHealth({ available: false, state: "stopped", error: "x", hint: "./playground ai-builder start" });
  assert.strictEqual(stopped.canGenerate, false); assert.match(stopped.banner, /\.\/playground ai-builder start/);
  assert.match(core.describeHealth({ available: false, state: "not_configured", hint: "./playground ai-builder start" }).banner, /not set up/);
  assert.match(core.describeHealth({ available: false, state: "timeout" }).banner, /did not answer in time/);
  assert.strictEqual(core.describeHealth({ available: true, state: "claude_missing" }).canGenerate, false);
  assert.strictEqual(core.describeHealth(null, true).canGenerate, false);
});
test("login addresses: only https on an official Claude/Anthropic host become links", () => {
  for (const ok of ["https://claude.ai/oauth/authorize?x=1", "https://platform.claude.com/oauth/authorize?x=1", "https://claude.com/cai/oauth/authorize?a=b"]) assert.strictEqual(core.isAllowedLoginUrl(ok), true, ok);
  for (const bad of ["http://claude.ai/x", "https://evil.example/claude.ai", "https://claude.ai.evil.example/x", "https://user:pw@claude.ai/x", "javascript:alert(1)", "https://notclaude.ai/x", "", "claude.ai", "https://localhost:4444/cb"]) assert.strictEqual(core.isAllowedLoginUrl(bad), false, bad);
});
test("authorization code checks: a web address, spaces or junk are refused before anything is sent", () => {
  assert.strictEqual(core.validateCode("Zx9aQ-test_CODE.value~1234#state567890"), "");
  assert.match(core.validateCode(""), /Paste/); assert.match(core.validateCode("https://platform.claude.com/oauth/code/callback?code=abc"), /web address/);
  assert.match(core.validateCode("two words here ok"), /no spaces/); assert.match(core.validateCode("short"), /does not look/); assert.match(core.validateCode("a;b;c;d;e;f;g;h"), /does not look/);
});
test("sign-in session descriptions drive what the panel offers", () => {
  const d = core.describeSession;
  assert.deepStrictEqual([d(null).active, d(null).showLink, d(null).showCode], [false, false, false]);
  const waiting = d({ state: "awaiting_browser", url: "https://claude.ai/oauth/authorize?x=1", awaiting_code: true });
  assert.deepStrictEqual([waiting.active, waiting.showLink, waiting.showCode], [true, true, true]);
  assert.strictEqual(d({ state: "awaiting_browser", url: "https://evil.example/x", awaiting_code: true }).showLink, false, "a foreign address is never linked");
  assert.strictEqual(d({ state: "starting" }).showLink, false); assert.strictEqual(d({ state: "verifying" }).showCode, false);
  assert.deepStrictEqual([d({ state: "failed", error: "Claude did not accept the code." }).text, d({ state: "failed", error: "x" }).error, d({ state: "failed", error: "x" }).active], ["Claude did not accept the code.", true, false]);
  assert.strictEqual(d({ state: "succeeded" }).text, "Connected to Claude."); assert.strictEqual(d({ state: "cancelled" }).done, true);
});
test("the panel markup exists: header button, docked aside, resizer, scripts after app.js", () => {
  for (const id of ["aib-open", "aib", "aib-resizer", "app-main", "aib-chat-pane", "aib-conv-new", "aib-hist-toggle"]) assert.ok(HTML_IDS.has(id), id);
  for (const id of ["aib-tabs", "aib-tab-chat", "aib-tab-gen", "aib-gen-pane", "aib-form", "aib-name", "aib-generate"]) assert.ok(!HTML_IDS.has(id), `${id} is gone: the conversation is the whole panel`);
  assert.match(HTML, /<header>[\s\S]*id="aib-open"[\s\S]*<\/header>/);
  assert.ok(HTML.indexOf('src="app.js"') < HTML.indexOf('src="ai-markdown.js"') && HTML.indexOf('src="ai-markdown.js"') < HTML.indexOf('src="ai-builder.js"'));
  assert.match(HTML, /<aside id="aib" class="aib" aria-label="AI Lab Assistant" hidden>/); assert.ok(!/<dialog id="aib"/.test(HTML), "no modal any more");
  assert.match(CSS, /main #aib \{/);
});
test("every id the script uses exists in index.html", () => {
  const used = new Set([...SRC.matchAll(/\$\("([a-z0-9-]+)"\)/g)].map(m => m[1]));
  assert.ok(used.size > 20);
  for (const id of used) assert.ok(HTML_IDS.has(id), `missing id ${id}`);
});
test("no HTML injection sinks, no dynamic code", () => {
  for (const sink of ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"]) assert.ok(!SRC.includes(sink), sink);
});
test("only the Playground proxy is used: no port, no token, no credential in the script", () => {
  for (const forbidden of ["8099", "ai-builder:", "Authorization", "Bearer ", "ai-builder-token", ".credentials", "ANTHROPIC", "CLAUDE_CODE_OAUTH"]) assert.ok(!SRC.includes(forbidden), forbidden);
  assert.strictEqual((SRC.match(/\bfetch\(/g) || []).length, 1, "a single fetch call site");
  assert.ok(SRC.includes('fetch(AIB_API + path'));
  assert.ok(/method !== "GET"\) headers\["X-Requested-With"\] = "playground"/.test(SRC), "the CSRF header is sent with every call that is not a GET (POST and DELETE)");
});
// --- layout rules of the docked panel (real rendering is checked in a browser: see docs/ai-builder.md) --------------------------
test("the panel styles live in their own stylesheet, linked after style.css, which does not mention the panel", () => {
  assert.ok(HTML.indexOf('href="style.css"') > 0 && HTML.indexOf('href="style.css"') < HTML.indexOf('href="ai-builder.css"'));
  assert.ok(!/aib/.test(STYLE), "style.css must stay free of AI Builder rules");
});
test("every selector of ai-builder.css is scoped to the panel (only its own layout hooks reach outside)", () => {
  const css = CSS.replace(/\/\*[\s\S]*?\*\//g, "");
  const selectors = []; let buf = "", depth = 0; const media = [];                // media[d] = the block at depth d is an @media wrapper
  for (const ch of css) {
    if (ch === "{") {
      const head = buf.trim(), insideKeyframes = media.includes("keyframes");
      if (head.startsWith("@media") || head.startsWith("@container")) media.push(true); else if (head.startsWith("@keyframes aib-")) media.push("keyframes");
      else { media.push(false); if (!insideKeyframes) selectors.push(head); }                // the steps of an aib- animation are not selectors
      depth++; buf = "";
    }
    else if (ch === "}") { depth--; media.pop(); buf = ""; }
    else buf += ch;
  }
  assert.strictEqual(depth, 0, "balanced braces"); assert.ok(selectors.length > 50, "rules found");
  const own = /^(?::root\[data-theme="dark"\] )?(?:#aib(?:-open)?(?![A-Za-z0-9_])|main #aib(?![A-Za-z0-9_-])|\.aib-resizer|main\.aib-dragging|\.aib-sr$)/;
  for (const sel of selectors) for (const one of sel.split(",")) assert.ok(own.test(one.trim()) || /^#aib-resizer\[hidden\]$/.test(one.trim()), `unscoped selector: ${one.trim()}`);
  const outside = selectors.flatMap(s => s.split(",")).map(s => s.trim()).filter(s => !/^(:root\[data-theme="dark"\] )?(#aib|main #aib|\.aib-sr)/.test(s));
  assert.ok(outside.every(s => /^(\.aib-resizer|main\.aib-dragging|#aib-resizer)/.test(s)), `only the resizer hooks reach outside the panel: ${outside.join(" | ")}`);
  assert.ok(!selectors.flatMap(s => s.split(",")).some(s => /^(body|html|header|aside|iframe|button|select|textarea|input|label|pre|code|h[1-6]|ul|ol|li|p|a|div|span)\b/.test(s.trim())), "no selector starts with a bare element");
});
test("hidden attributes are honored even by rules that set display", () => {
  assert.match(CSS, /#aib \[hidden\], #aib\[hidden\], #aib-resizer\[hidden\] \{ display: none !important; \}/);
});
test("docked layout: a flex column of <main> sized by --aib-w, a resizer, a full-screen panel on narrow windows, reduced motion", () => {
  assert.match(CSS, /main #aib \{[^}]*flex: 0 0 var\(--aib-w, 440px\)[^}]*width: var\(--aib-w, 440px\)/s);
  assert.match(CSS, /main #aib \{[^}]*transition: none/s, "no animation of the width: terminals would refit on every frame");
  assert.match(CSS, /\.aib-resizer \{[^}]*cursor: col-resize/); assert.match(CSS, /main\.aib-dragging #panes iframe \{ pointer-events: none; \}/);
  assert.match(CSS, /@media \(max-width: 800px\) \{\s*main #aib \{ position: fixed; inset: 0;/);
  assert.match(CSS, /@media \(prefers-reduced-motion: reduce\)/);
  assert.match(CSS, /#aib \.aib-composer textarea \{[^}]*max-height: 180px/); assert.match(CSS, /#aib \.aib-field textarea \{[^}]*min-height: 150px/);
  assert.match(CSS, /\.aib-field input\[type="text"\], #aib \.aib-field input\[type="email"\], #aib \.aib-field select, #aib \.aib-field textarea \{[^}]*width: 100%/);
});
test("the panel markup: title, status and close in the header; resizer is a labelled separator; fields are stacked", () => {
  const aside = HTML.slice(HTML.indexOf('<aside id="aib"'), HTML.indexOf("</aside>", HTML.indexOf('<aside id="aib"')));
  const head = aside.slice(aside.indexOf('class="aib-head"'), aside.indexOf('class="aib-top"'));
  for (const id of ["aib-title", "aib-status", "aib-close"]) assert.ok(head.includes(`id="${id}"`), id);
  assert.match(HTML, /<div id="aib-resizer"[^>]*role="separator"[^>]*aria-orientation="vertical"[^>]*aria-label="[^"]+"[^>]*tabindex="0"/);
  assert.ok(HTML.indexOf('class="aib-top"') < HTML.indexOf('id="aib-chat-pane"') && !/role="tab(list|panel)?"/.test(aside), "the conversation follows the header directly: no tabs");
  assert.match(HTML, /id="aib-conv-messages" class="aib-messages" role="log"/); assert.match(HTML, /id="aib-activity"[^>]*role="status" aria-live="polite"/);
  assert.match(HTML, /id="aib-open"[^>]*aria-controls="aib" aria-expanded="false"/);
  assert.ok(!aside.includes("aib-row"), "no two-column row");
  for (const m of aside.matchAll(/<label[^>]*\sfor="([^"]+)"/g)) assert.ok(HTML_IDS.has(m[1]), `label for=${m[1]}`);
  for (const id of ["aib-conv-input", "aib-hist-search", "aib-hist-toggle"]) assert.ok(new RegExp(`(<label[^>]*for="${id}"|id="${id}"[^>]*aria-label=)`).test(aside), `${id} has an accessible name`);
});
test("the existing page markup is untouched except the new button, stylesheet link, panel and scripts", () => {
  const without = HTML.replace(/\s*<link rel="stylesheet" href="ai-builder.css">/, "").replace(/\s*<button id="aib-open"[^>]*>[^<]*<\/button>/, "")
    .replace(/\s*<div id="aib-resizer"[\s\S]*?<\/div>/, "").replace(/\s*<aside id="aib"[\s\S]*?<\/aside>/, "")
    .replace(/\s*<script src="ai-markdown.js"><\/script>/, "").replace(/\s*<script src="ai-builder.js"><\/script>/, "");
  for (const id of ["sidebar-toggle", "theme-toggle", "conn", "usecases", "tabs", "panes", "split", "logs", "resources", "statusbar", "confirm", "confirm-ok"]) assert.ok(without.includes(`id="${id}"`), id);
  assert.ok(!/aib/.test(without), "nothing else of the page mentions the panel");
  assert.match(HTML, /<main id="app-main">\s*<aside id="sidebar">[\s\S]*<section id="terminal">[\s\S]*<div id="aib-resizer"[\s\S]*<aside id="aib"[\s\S]*<\/aside>\s*<\/main>/, "the panel is the last column of <main>");
});
test("the existing page scripts are untouched by the panel (no globals overwritten)", () => {
  const app = fs.readFileSync(path.join(ROOT, "web/static/app.js"), "utf8");
  assert.ok(!app.includes("aib"), "app.js must not know about the panel");
  const names = [...SRC.matchAll(/^(?:const|let|function)\s+([A-Za-z_]+)/gm)].map(m => m[1]);
  for (const n of names) assert.ok(n.startsWith("AIB"), `top-level name ${n} must be AIB-prefixed to avoid clashing with app.js`);
});

// ---------------------------------------------------------------------------------------------------------------------
// 2. Behavior against a fake DOM and a scripted fetch
// ---------------------------------------------------------------------------------------------------------------------
class El {
  constructor(id, tag = "div") {
    Object.assign(this, { id, tag, children: [], hidden: false, disabled: false, value: "", checked: false, textContent: "", className: "", open: false, dataset: {}, listeners: {}, attrs: {}, focused: 0 });
    const has = c => this.className.split(/\s+/).includes(c);
    this.classList = { toggle: (c, on) => { const want = on === undefined ? !has(c) : on; if (want && !has(c)) this.className = (this.className + " " + c).trim(); if (!want && has(c)) this.className = this.className.split(/\s+/).filter(x => x !== c).join(" "); },
      add: c => this.classList.toggle(c, true), remove: c => this.classList.toggle(c, false), contains: has };
    this.style = { props: {}, setProperty(k, v) { this.props[k] = v; }, removeProperty(k) { delete this.props[k]; } };
    this.width = 0;
  }
  get clientWidth() { return this.width; }
  getBoundingClientRect() { return { left: 0, right: this.width, width: this.width, top: 0, bottom: 0, height: 0 }; }
  focus() { this.focused++; }
  remove() {}
  get options() { return this.children; }
  replaceChildren(...n) { this.children = n; }
  append(...n) { this.children.push(...n); }
  appendChild(n) { this.children.push(n); return n; }
  setAttribute(k, v) { this.attrs[k] = v; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
}

function harness({ routes, saved = null, storage = {} }) {
  const docListeners = {};
  const els = new Map(), fetches = [], store = new Map([...(saved ? [["aibJob", JSON.stringify(saved)]] : []), ...Object.entries(storage)]);
  const counters = { refreshUseCases: 0, refreshTerminals: 0 }, windowListeners = [], copied = [];
  const doc = {
    getElementById(id) { assert.ok(HTML_IDS.has(id), `getElementById("${id}"): not in index.html`); if (!els.has(id)) els.set(id, new El(id)); return els.get(id); },
    createElement: tag => new El(null, tag),
    addEventListener(type, fn, capture) { (docListeners[type] = docListeners[type] || []).push(fn); },
  };
  const sandbox = {
    window: { addEventListener: (type, fn) => windowListeners.push([type, fn]) }, navigator: { clipboard: { writeText: async t => { copied.push(t); } } },
    document: doc, console, AbortSignal, URL, JSON, Date, Math, Number, Array, String, Object, Promise, Error,
    items: [{ name: "cnpg-standard", title: "CNPG Standard" }, { name: "pg4k-tde", title: "PG4K TDE" }],
    refreshUseCases: () => { counters.refreshUseCases++; }, refreshTerminals: () => { counters.refreshTerminals++; },
    Option: function (label, value) { const o = new El(null, "option"); o.textContent = label; o.value = value; return o; },
    localStorage: { getItem: k => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k) },
    setInterval: () => 1, clearInterval: () => {}, setTimeout: (fn, ms) => { if (!(ms >= 3000)) setImmediate(fn); return 1; },   // long timers (the 4 s disconnect confirmation) do not fire by themselves
    fetch: async (url, opts = {}) => {
      fetches.push({ url, method: opts.method, headers: opts.headers || {}, body: opts.body === undefined ? undefined : JSON.parse(opts.body) });
      const handler = routes[`${opts.method} ${url}`] || routes[`${opts.method} ${url.replace(/\/[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$/, "/<job>")}`];
      const fallback = opts.method === "GET" && url === "/api/ai-builder/conversations" ? { status: 200, body: { conversations: [] } } : null;   // the assistant tab lists conversations on open
      if (!handler && !fallback) throw new Error(`unexpected request ${opts.method} ${url}`);
      const out = handler === undefined ? fallback : await (typeof handler === "function" ? handler(opts) : handler);   // a route may answer later (a Promise)
      if (out instanceof Error) throw out;
      return { ok: out.status >= 200 && out.status < 300, status: out.status, json: async () => out.body };
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(MD_SRC, sandbox, { filename: "ai-markdown.js" });
  const $ = id => doc.getElementById(id);
  $("app-main").width = 1400;
  vm.runInContext(SRC, sandbox, { filename: "ai-builder.js" });
  return { $, els, fetches, counters, store, windowListeners, copied, docListeners,
    posts: () => fetches.filter(f => f.method === "POST"),
    async open() { await $("aib-open").onclick(); await tick(); },
    async click(id) { await $(id).onclick(); await tick(10); },
    text: id => $(id).textContent,
  };
}

const JOB = "20261117-120000-abc123";
const HEALTH_OK = { status: 200, body: { available: true, state: "ready", claude_credentials_present: true, busy: false } };
const HEALTH_NOLOGIN = { status: 200, body: { available: true, state: "not_signed_in", claude_credentials_present: false, busy: false } };
const AUTH_URL = "https://claude.com/cai/oauth/authorize?code=true&client_id=test&state=abc";
const CODE = "Zx9aQ-test_code-0123456789#abcdef";
const sess = (state, extra = {}) => ({ state, method: "claudeai", url: AUTH_URL, awaiting_code: state === "awaiting_browser", seconds_left: 540, ...extra });
const authBody = (loggedIn, session) => ({ status: 200, body: { logged_in: loggedIn, enabled: true, session } });
// A scripted browser sign-in: login answers script[0], the next status polls answer the rest; the code answers afterCode[0], then the polls the rest.
function signInRoutes({ script = [], afterCode = [], onCode, loginReply } = {}) {
  const st = { signed: false, session: null, queue: [] };
  return {
    "GET /api/ai-builder/health": () => (st.signed ? HEALTH_OK : HEALTH_NOLOGIN),
    "GET /api/ai-builder/auth/status": () => { if (st.queue.length) st.session = st.queue.shift(); if (st.session && st.session.state === "succeeded") st.signed = true; return authBody(st.signed, st.session); },
    "POST /api/ai-builder/auth/login": () => { if (loginReply) return loginReply; st.session = script[0] || sess("awaiting_browser"); st.queue = script.slice(1); return authBody(false, st.session); },
    "POST /api/ai-builder/auth/code": () => { if (onCode) onCode(); if (afterCode.length) { st.session = afterCode[0]; st.queue = afterCode.slice(1); } return authBody(st.signed, st.session); },
    "POST /api/ai-builder/auth/cancel": () => { st.session = sess("cancelled", { awaiting_code: false }); st.queue = []; return authBody(st.signed, st.session); },
    "GET /api/ai-builder/conversations": { status: 200, body: { conversations: [] } },
  };
}
// Everything a person (or a stored value) could see: element texts and values, attributes and the browser storage; never the request bodies.
const allText = h => { const walk = e => [e.textContent, e.value, JSON.stringify(e.attrs), ...e.children.map(walk)].join(" ");
  return [...h.els.values()].map(walk).join(" ") + " " + [...h.store.values()].join(" "); };
const FILES = { "usecase.yaml": "title: Demo\n", "README.md": "# Demo\n", "01_install.sh": "#!/usr/bin/env bash\necho hi\n", "manifests/cluster.yaml": "kind: Cluster\n" };
const STATUS_DONE = { status: 200, body: { job_id: JOB, name: "cnpg-readonly-demo", status: "completed", phase: "done", validated: true, validation: { passed: true, errors: [] }, files: Object.keys(FILES), created: new Date().toISOString(), attempts: 1 } };
const reviewOf = (state = "pending", published = false) => ({ status: 200, body: { job_id: JOB, content: FILES, review: { state }, published, validated: true } });

test("opening the panel checks health through the proxy and shows the badge", async () => {
  const h = harness({ routes: { "GET /api/ai-builder/health": HEALTH_OK } });
  await h.open();
  assert.ok($open(h)); assert.deepStrictEqual(h.fetches.map(f => f.url).sort(), ["/api/ai-builder/auth/status", "/api/ai-builder/conversations", "/api/ai-builder/health"], "the assistant tab lists conversations when the panel opens");
  assert.match(h.text("aib-status"), /Ready · Claude signed in/); assert.strictEqual(h.$("aib-conv-new").disabled, false); assert.strictEqual(h.$("aib-banner").hidden, true);
});
const $open = h => !h.$("aib").hidden;

test("AI Builder stopped: banner with the start command, generation disabled, nothing posted", async () => {
  const h = harness({ routes: { "GET /api/ai-builder/health": { status: 200, body: { available: false, state: "stopped", error: "not running", hint: "./playground ai-builder start" } } } });
  await h.open();
  assert.match(h.text("aib-banner"), /\.\/playground ai-builder start/); assert.strictEqual(h.posts().length, 0);
});
test("Claude not signed in: explained, generation disabled, the Connect action offered", async () => {
  const h = harness({ routes: { "GET /api/ai-builder/health": { status: 200, body: { available: true, state: "not_signed_in", claude_credentials_present: false } },
                                "GET /api/ai-builder/auth/status": { status: 200, body: { logged_in: false, session: null } } } });
  await h.open();
  assert.match(h.text("aib-banner"), /Connect to Claude/); assert.match(h.text("aib-status"), /not signed in/);
  assert.strictEqual(h.$("aib-connect").hidden, false); assert.strictEqual(h.$("aib-disconnect").hidden, true);
});
test("Playground API unreachable is reported, not thrown", async () => {
  const h = harness({ routes: { "GET /api/ai-builder/health": new Error("network") } });
  await h.open(); assert.match(h.text("aib-banner"), /Playground API did not answer/);
});
test("Connect to Claude opens the sign-in; starting it sends one login request with the CSRF header", async () => {
  const h = harness({ routes: signInRoutes({ script: [sess("awaiting_browser")] }) });
  await h.open();
  assert.strictEqual(h.$("aib-auth").hidden, true); assert.strictEqual(h.$("aib-connect").hidden, false);
  await h.click("aib-connect");
  assert.strictEqual(h.$("aib-auth").hidden, false); assert.strictEqual(h.$("aib-auth-start").hidden, false); assert.strictEqual(h.$("aib-connect").hidden, true);
  h.$("aib-auth-method").value = "sso"; h.$("aib-auth-email").value = "person@example.co";
  const a = h.$("aib-auth-begin").onclick(), b = h.$("aib-auth-begin").onclick();               // double click
  await Promise.all([a, b]); await tick(20); h.$("aib-close").onclick();
  const logins = h.posts().filter(p => p.url.endsWith("/auth/login"));
  assert.strictEqual(logins.length, 1, "one login request");
  assert.deepStrictEqual(logins[0].body, { method: "sso", email: "person@example.co" }); assert.strictEqual(logins[0].headers["X-Requested-With"], "playground");
});
test("the official sign-in address becomes a safe link and the code field appears; a foreign address is never linked", async () => {
  const h = harness({ routes: signInRoutes({ script: [sess("awaiting_browser")] }) });
  await h.open(); await h.click("aib-connect"); await h.click("aib-auth-begin"); await tick(20);
  assert.strictEqual(h.$("aib-auth-linkrow").hidden, false); assert.strictEqual(h.$("aib-auth-link").href, AUTH_URL);
  assert.strictEqual(h.$("aib-auth-coderow").hidden, false); assert.strictEqual(h.$("aib-auth-cancel").hidden, false); assert.match(h.text("aib-auth-timer"), /Time left 9:00/);
  assert.match(h.text("aib-auth-text"), /authorization code/); assert.strictEqual(h.$("aib-auth-start").hidden, true, "no second sign-in can be started meanwhile");
  h.$("aib-close").onclick();
  const bad = harness({ routes: signInRoutes({ script: [sess("awaiting_browser", { url: "https://evil.example/phish" })] }) });
  await bad.open(); await bad.click("aib-connect"); await bad.click("aib-auth-begin"); await tick(20); bad.$("aib-close").onclick();
  assert.strictEqual(bad.$("aib-auth-linkrow").hidden, true); assert.ok(!allText(bad).includes("evil.example"));
});
test("the code: refused locally when it is a web address; sent once, the field cleared before the request leaves; never kept anywhere", async () => {
  let fieldAtSend = null, h;
  const routes = signInRoutes({ script: [sess("awaiting_browser")], afterCode: [sess("verifying"), sess("succeeded")], onCode: () => { fieldAtSend = h.$("aib-auth-code").value; } });
  h = harness({ routes });
  await h.open(); await h.click("aib-connect"); await h.click("aib-auth-begin"); await tick(20);
  h.$("aib-auth-code").value = "https://platform.claude.com/oauth/code/callback?code=abc"; await h.click("aib-auth-submit");
  assert.strictEqual(h.posts().filter(p => p.url.endsWith("/auth/code")).length, 0, "nothing sent"); assert.match(h.text("aib-auth-error"), /web address/);
  await tick(30); assert.match(h.text("aib-auth-error"), /web address/, "the polling does not erase the message"); assert.strictEqual(h.$("aib-auth-error").hidden, false);
  h.$("aib-auth-code").value = CODE; await h.click("aib-auth-submit"); await tick(30);
  const sent = h.posts().filter(p => p.url.endsWith("/auth/code"));
  assert.strictEqual(sent.length, 1); assert.deepStrictEqual(sent[0].body, { code: CODE }); assert.strictEqual(sent[0].headers["X-Requested-With"], "playground");
  assert.strictEqual(fieldAtSend, "", "the input was already empty when the request was made");
  assert.strictEqual(h.$("aib-auth-code").value, "");
  assert.ok(!allText(h).includes(CODE) && !allText(h).includes("Zx9aQ"), "the code is nowhere in the page state or storage");
  h.$("aib-close").onclick();
});
test("success is detected by polling: the panel shows it, re-checks health and is signed in without a reload", async () => {
  const routes = signInRoutes({ script: [sess("awaiting_browser")], afterCode: [sess("verifying"), sess("succeeded")] });
  const h = harness({ routes });
  await h.open(); await h.click("aib-connect"); await h.click("aib-auth-begin"); await tick(10);
  h.$("aib-auth-code").value = CODE; await h.click("aib-auth-submit"); await tick(60);
  assert.match(h.text("aib-auth-text"), /Connected to Claude/); assert.match(h.$("aib-auth-text").className, /ok/);
  assert.ok(h.fetches.filter(f => f.url.endsWith("/health")).length >= 2, "health re-checked after the sign-in");
  assert.match(h.text("aib-status"), /Ready · Claude signed in/); assert.strictEqual(h.$("aib-conv-new").disabled, false);
  assert.strictEqual(h.$("aib-auth-start").hidden, true);
  await h.click("aib-auth-dismiss"); assert.strictEqual(h.$("aib-auth").hidden, true); assert.strictEqual(h.$("aib-disconnect").hidden, false); assert.strictEqual(h.$("aib-connect").hidden, true);
});
test("a failed sign-in shows the server's fixed message and offers Try again; timeouts and wrong codes are failures too", async () => {
  for (const message of ["Claude did not accept the code. Codes are single-use: start the sign-in again to get a new one.", "The sign-in was not completed in time. Start again."]) {
    const h = harness({ routes: signInRoutes({ script: [sess("awaiting_browser"), sess("failed", { error: message })] }) });
    await h.open(); await h.click("aib-connect"); await h.click("aib-auth-begin"); await tick(40); h.$("aib-close").onclick();
    assert.strictEqual(h.text("aib-auth-text"), message); assert.match(h.$("aib-auth-text").className, /bad/);
    assert.strictEqual(h.text("aib-auth-begin"), "Try again"); assert.strictEqual(h.$("aib-auth-start").hidden, false); assert.strictEqual(h.$("aib-auth-coderow").hidden, true);
  }
});
test("a refused start (another sign-in or a running job) is explained and nothing keeps running", async () => {
  const h = harness({ routes: signInRoutes({ loginReply: { status: 409, body: { error: "a sign-in is already in progress" } } }) });
  await h.open(); await h.click("aib-connect"); await h.click("aib-auth-begin");
  assert.match(h.text("aib-auth-starterror"), /already in progress/); assert.strictEqual(h.$("aib-auth-starterror").hidden, false); assert.strictEqual(h.$("aib-auth-begin").disabled, false);
});
test("cancelling the sign-in sends one cancel request and stops the polling", async () => {
  const h = harness({ routes: signInRoutes({ script: [sess("awaiting_browser")] }) });
  await h.open(); await h.click("aib-connect"); await h.click("aib-auth-begin"); await tick(20);
  await h.click("aib-auth-cancel"); await tick(10);
  assert.strictEqual(h.posts().filter(p => p.url.endsWith("/auth/cancel")).length, 1); assert.strictEqual(h.text("aib-auth-text"), "Sign-in cancelled.");
  const before = h.fetches.length; await tick(30); assert.strictEqual(h.fetches.length, before, "polling ended"); h.$("aib-close").onclick();
});
test("Disconnect needs two clicks, then signs out and offers Connect again", async () => {
  const routes = signInRoutes();
  routes["GET /api/ai-builder/health"] = () => (routes.loggedOut ? HEALTH_NOLOGIN : HEALTH_OK);
  routes["GET /api/ai-builder/auth/status"] = () => authBody(!routes.loggedOut, null);
  routes["POST /api/ai-builder/auth/logout"] = () => { routes.loggedOut = true; return authBody(false, null); };
  const h = harness({ routes });
  await h.open();
  assert.strictEqual(h.$("aib-disconnect").hidden, false); assert.strictEqual(h.$("aib-connect").hidden, true);
  await h.click("aib-disconnect");
  assert.strictEqual(h.posts().length, 0, "the first click only asks for confirmation"); assert.strictEqual(h.text("aib-disconnect"), "Confirm disconnect");
  await h.click("aib-disconnect"); await tick(20);
  const out = h.posts(); assert.strictEqual(out.length, 1); assert.ok(out[0].url.endsWith("/auth/logout")); assert.strictEqual(out[0].headers["X-Requested-With"], "playground");
  assert.strictEqual(h.$("aib-connect").hidden, false); assert.match(h.text("aib-status"), /not signed in/); assert.match(h.text("aib-conv-note"), /Disconnected from Claude/);
});
test("an expired session (credentials present, Claude says logged out) offers to reconnect and blocks generation", async () => {
  const h = harness({ routes: { "GET /api/ai-builder/health": HEALTH_OK, "GET /api/ai-builder/auth/status": authBody(false, null) } });
  await h.open();
  assert.match(h.text("aib-status"), /session expired/); assert.match(h.text("aib-banner"), /no longer valid/);
  assert.strictEqual(h.$("aib-connect").hidden, false);
});
test("an unknown sign-in status (status call failed) never blocks generation or shows the session as expired", async () => {
  const h = harness({ routes: { "GET /api/ai-builder/health": HEALTH_OK, "GET /api/ai-builder/auth/status": { status: 200, body: { logged_in: null, error: "status_unavailable", session: null } } } });
  await h.open(); assert.match(h.text("aib-status"), /Ready/); assert.strictEqual(h.$("aib-connect").hidden, true);
});
test("host mode (browser sign-in disabled by the AI Builder) shows no Connect or Disconnect", async () => {
  const h = harness({ routes: { "GET /api/ai-builder/health": HEALTH_NOLOGIN, "GET /api/ai-builder/auth/status": { status: 200, body: { logged_in: null, enabled: false, session: null } } } });
  await h.open(); assert.strictEqual(h.$("aib-connect").hidden, true); assert.strictEqual(h.$("aib-disconnect").hidden, true);
  const ok = harness({ routes: { "GET /api/ai-builder/health": { status: 200, body: { available: true, state: "ready", claude_credentials_present: null } }, "GET /api/ai-builder/auth/status": { status: 200, body: { logged_in: null, enabled: false, session: null } } } });
  await ok.open(); assert.strictEqual(ok.$("aib-disconnect").hidden, true, "never offered where it would act on the user's own login");
});
test("a stopped AI Builder offers no sign-in controls", async () => {
  const h = harness({ routes: { "GET /api/ai-builder/health": { status: 200, body: { available: false, state: "stopped", hint: "./playground ai-builder start" } } } });
  await h.open(); assert.strictEqual(h.$("aib-connect").hidden, true); assert.strictEqual(h.$("aib-disconnect").hidden, true); assert.strictEqual(h.$("aib-auth").hidden, true);
});
test("the sign-in never leaves /api/ai-builder/ and never carries credential headers", async () => {
  const h = harness({ routes: signInRoutes({ script: [sess("awaiting_browser")], afterCode: [sess("succeeded")] }) });
  await h.open(); await h.click("aib-connect"); await h.click("aib-auth-begin"); await tick(10);
  h.$("aib-auth-code").value = CODE; await h.click("aib-auth-submit"); await tick(40); h.$("aib-close").onclick();
  assert.ok(h.fetches.length >= 6);
  for (const f of h.fetches) {
    assert.ok(f.url.startsWith("/api/ai-builder/"), f.url); assert.ok(!/8099|ai-builder:|^https?:/.test(f.url), f.url);
    assert.deepStrictEqual(Object.keys(f.headers).filter(k => !["X-Requested-With", "Content-Type"].includes(k)), []);
  }
  assert.ok(!JSON.stringify(h.fetches.filter(f => !f.url.endsWith("/auth/code"))).includes(CODE), "the code appears only in the one code request");
});
test("static: the sign-in markup exists, the code field is a password input, the link opens safely, and the code is never stored", () => {
  for (const id of ["aib-connect", "aib-disconnect", "aib-auth", "aib-auth-method", "aib-auth-email", "aib-auth-begin", "aib-auth-text", "aib-auth-error", "aib-auth-starterror", "aib-auth-link", "aib-auth-code", "aib-auth-submit", "aib-auth-cancel", "aib-auth-dismiss"]) assert.ok(HTML_IDS.has(id), id);
  assert.match(HTML, /<input id="aib-auth-code" type="password" autocomplete="off"/); assert.match(HTML, /id="aib-auth-link"[^>]*target="_blank" rel="noopener noreferrer"/);
  assert.ok(!/localStorage\.setItem\([^)]*code/i.test(SRC) && !/store\.set\([^)]*code/i.test(SRC), "no storage of the code");
  assert.ok(!/console\.(log|info|warn|error|debug)/.test(SRC), "the panel never logs");
  assert.ok(!SRC.includes(".href =") || SRC.includes("session.url"), "links come only from the validated session address");
});

// ---------------------------------------------------------------------------------------------------------------------
// 3. Conversations tab (SPEC-022)
// ---------------------------------------------------------------------------------------------------------------------
const CID = "c-20261117-120000-abc123";
const USAGE = { input_tokens: 4, output_tokens: 100, cache_read_input_tokens: 1000, cache_creation_input_tokens: 500 };
const turn = (n, extra = {}) => ({ n, user: "What does scenario 01 do?", assistant: "It installs the cluster.", status: "ok", error: null, model: "sonnet", seconds: 3.2, cost_usd: 0.0421, usage: USAGE, ...extra });
const budget = (state = "ok", percent = 10) => ({ limit_usd: 10, spent_usd: percent / 10, remaining_usd: 10 - percent / 10, percent, state, warn_at_percent: 80 });
const convView = (extra = {}) => ({ id: CID, title: "What does scenario 01 do?", lab: "cnpg-standard", status: "idle", model: "sonnet", messages: [], pending: null, read_only: true,
  budget: budget(), context: { last_tokens: 1500, warning: false }, limits: { max_turns: 100 }, ...extra });
const summary = (v = convView()) => ({ id: v.id, title: v.title, lab: v.lab, status: v.status, turns: v.messages.length, cost_usd: v.budget.spent_usd, budget_state: v.budget.state, archived: !!v.archived });

function chatRoutes(state) {
  return {
    "GET /api/ai-builder/health": HEALTH_OK,
    "GET /api/ai-builder/auth/status": { status: 200, body: { logged_in: true, session: null } },
    "GET /api/ai-builder/conversations": () => ({ status: 200, body: { conversations: [...(state.conv ? [summary(state.conv)] : []), ...(state.others || [])] } }),
    "POST /api/ai-builder/conversations": () => { state.conv = convView({ lab: null }); return { status: 201, body: state.conv }; },
    [`POST /api/ai-builder/conversations/${CID}/meta`]: opts => { if (state.failNext) { state.failNext = false; return { status: 405, body: { error: "Method Not Allowed" } }; } const b = JSON.parse(opts.body); state.conv = { ...state.conv, ...(b.title !== undefined ? { title: b.title } : {}), ...(b.archived !== undefined ? { archived: b.archived } : {}) }; return { status: 200, body: state.conv }; },
    [`POST /api/ai-builder/conversations/${CID}/context`]: opts => { state.conv = { ...state.conv, edit_approved: ["allow_edit", "create_lab"].includes(JSON.parse(opts.body).action), ...(JSON.parse(opts.body).action === "create_lab" ? { lab: JSON.parse(opts.body).lab } : {}) }; if (JSON.parse(opts.body).action === "decline_edit") state.conv.messages = state.conv.messages.map((m, i, a) => (i === a.length - 1 ? { ...m, edit_request: false, create_request: null } : m)); return { status: 200, body: state.conv }; },
    [`DELETE /api/ai-builder/conversations/${CID}`]: () => { state.deletes = (state.deletes || 0) + 1; state.conv = null; return { status: 200, body: { deleted: CID } }; },
    [`GET /api/ai-builder/conversations/${CID}`]: () => { state.gets = (state.gets || 0) + 1; if (state.becomeIdleAfter && state.gets >= state.becomeIdleAfter) state.finish && state.finish(); return { status: 200, body: state.conv }; },
    [`POST /api/ai-builder/conversations/${CID}/messages`]: opts => {
      if (state.sendReply) return state.sendReply;
      const text = JSON.parse(opts.body).message;
      state.conv = { ...state.conv, status: "running", pending: { n: state.conv.messages.length + 1, user: text } };
      state.finish = () => { state.conv = { ...state.conv, status: "idle", pending: null, messages: [...state.conv.messages, turn(state.conv.messages.length + 1, { user: text, assistant: "Here is the answer." })], budget: budget("ok", 20) }; state.finish = null; };
      state.becomeIdleAfter = 2;
      return { status: 202, body: state.conv };
    },
  };
}
const chat = async (state, saved) => { const h = harness({ routes: chatRoutes(state) }); if (saved) h.store.set("aibConv", saved); await h.open(); await tick(10); return h; };
const textOf = el => el.textContent + el.children.map(textOf).join("");                                       // the fake DOM does not join children
const bubbles = h => h.$("aib-conv-messages").children.map(c => ({ kind: c.className, text: textOf(c) }));

test("message rules, send guard, budget, context and usage lines", () => {
  assert.ok(core.validateMessage("")); assert.ok(core.validateMessage("   ")); assert.ok(core.validateMessage("x".repeat(4001))); assert.strictEqual(core.validateMessage("What is replica lag?"), "");
  const ok = { conv: convView(), busy: false, canGenerate: true, text: "hello" };
  assert.strictEqual(core.canSend(ok), true);
  for (const bad of [{ conv: null }, { busy: true }, { canGenerate: false }, { text: " " }, { conv: convView({ status: "running" }) }, { conv: convView({ pending: { user: "x" } }) },
    { conv: convView({ budget: budget("exhausted", 100) }) }, { conv: convView({ messages: new Array(100).fill(turn(1)) }) }]) assert.strictEqual(core.canSend({ ...ok, ...bad }), false, JSON.stringify(Object.keys(bad)));
  assert.strictEqual(core.canSend({ ...ok, conv: convView({ budget: budget("warning", 85) }) }), true, "a warning never blocks");
  assert.deepStrictEqual([core.describeBudget(budget()).level, core.describeBudget(budget()).warning], ["ok", ""]);
  const w = core.describeBudget(budget("warning", 85)); assert.strictEqual(w.level, "warn"); assert.match(w.warning, /80% .*estimated cost/);
  const x = core.describeBudget(budget("exhausted", 100)); assert.strictEqual(x.level, "bad"); assert.match(x.warning, /Start a new conversation/); assert.match(x.text, /^Estimated \$10\.00 of \$10\.00 \(100%\)$/);
  assert.match(core.turnMeta(turn(1)), /^sonnet · in 4 · out 100 · cache read 1,000 · cache write 500 · est\. \$0\.0421 · 3\.2 s$/);
  assert.match(core.turnMeta({ model: "sonnet", usage: null, cost_usd: null }), /^sonnet · tokens n\/a · est\. n\/a$/);
  assert.match(core.turnMeta({ usage: { input_tokens: null, output_tokens: 5 } }), /model n\/a · in n\/a · out 5/);
  assert.match(core.describeContext({ last_tokens: 12345, warning: true }).warning, /new conversation/); assert.strictEqual(core.describeContext({ last_tokens: null }).text, "");
});
test("a new conversation needs no Lab: one POST with the CSRF header and an empty body, then it is open and remembered", async () => {
  const state = {}; const h = await chat(state);
  await h.click("aib-conv-new"); await tick(10);
  const posts = h.posts(); assert.strictEqual(posts.length, 1);
  assert.deepStrictEqual([posts[0].url, posts[0].body, posts[0].headers["X-Requested-With"]], ["/api/ai-builder/conversations", {}, "playground"]);
  assert.strictEqual(h.$("aib-conv").hidden, false); assert.strictEqual(h.store.get("aibConv"), CID); assert.match(h.text("aib-conv-meta"), /^No Lab · sonnet · 0 messages/);
  assert.ok(!HTML_IDS.has("aib-conv-form") && !HTML_IDS.has("aib-conv-lab") && !HTML_IDS.has("aib-conv-context") && !HTML_IDS.has("aib-conv-lab-chip"), "no Lab picker, no Context menu, no Lab indicator");
});
test("sending a message: pending bubble, locked controls, reply with model, tokens and estimated cost", async () => {
  const state = { conv: convView() }; const h = await chat(state, CID);
  assert.strictEqual(h.$("aib-conv").hidden, false);
  h.$("aib-conv-input").value = "How do I read from the replica?"; await h.$("aib-conv-input").oninput();
  assert.strictEqual(h.$("aib-conv-send").disabled, false); assert.strictEqual(h.text("aib-conv-count"), "31 / 4000");
  await h.$("aib-conv-send-form").onsubmit({ preventDefault() {} });
  const post = h.posts().find(p => p.url.endsWith("/messages"));
  assert.deepStrictEqual([post.url, post.body, post.headers["X-Requested-With"]], [`/api/ai-builder/conversations/${CID}/messages`, { message: "How do I read from the replica?" }, "playground"]);
  assert.strictEqual(h.$("aib-conv-input").value, "", "cleared once accepted");
  await tick(40);
  const b = bubbles(h);
  assert.deepStrictEqual(b.map(x => x.kind.split(" ").slice(0, 2).join(" ")), ["aib-msg user", "aib-msg assistant"]);
  assert.match(b[1].text, /^Here is the answer\.Sonnet · 3\.2s · est\. \$0\.042Details/); assert.match(b[1].text, /Input tokens4Output tokens100Cache read tokens1,000Cache creation tokens500Estimated cost\$0\.0421Duration3\.2 s/);
  assert.match(h.text("aib-conv-budget"), /^Estimated \$2\.00 of \$10\.00 \(20%\)$/); assert.strictEqual(h.$("aib-conv-send").disabled, true, "empty input");
  assert.ok(state.gets >= 2, "the reply was polled");
});
test("while Claude answers the send button and the input are locked and a second send does nothing", async () => {
  const state = { conv: convView({ status: "running", pending: { n: 1, user: "slow question" } }), becomeIdleAfter: 99 };
  const h = await chat(state, CID);
  assert.strictEqual(h.$("aib-conv-input").disabled, false, "you can keep typing"); assert.strictEqual(h.$("aib-conv-send").disabled, true); assert.match(h.text("aib-conv-send"), /Waiting/); assert.strictEqual(h.$("aib-send-spinner").hidden, false);
  assert.deepStrictEqual(bubbles(h).map(x => x.kind.split(" ")[1] + (x.kind.includes("pending") ? "-pending" : "")), ["user", "assistant-pending"]);
  h.$("aib-conv-input").value = "again"; await h.$("aib-conv-send-form").onsubmit({ preventDefault() {} });
  assert.strictEqual(h.posts().length, 0); h.$("aib-close").onclick();
});
test("double submit sends one message", async () => {
  const state = { conv: convView() }; const h = await chat(state, CID);
  h.$("aib-conv-input").value = "one"; const f = h.$("aib-conv-send-form").onsubmit;
  await Promise.all([f({ preventDefault() {} }), f({ preventDefault() {} })]); await tick(20);
  assert.strictEqual(h.posts().filter(p => p.url.endsWith("/messages")).length, 1);
});
test("a refused message keeps the text and shows the reason; an invalid message is never sent", async () => {
  const state = { conv: convView(), sendReply: { status: 409, body: { error: "the conversation budget of $10 is used up: start a new conversation" } } };
  const h = await chat(state, CID);
  h.$("aib-conv-input").value = "my careful question"; await h.$("aib-conv-send-form").onsubmit({ preventDefault() {} }); await tick(10);
  assert.match(h.text("aib-conv-error"), /budget of \$10 is used up/); assert.strictEqual(h.$("aib-conv-input").value, "my careful question");
  const before = h.posts().length;
  h.$("aib-conv-input").value = "x".repeat(4001); await h.$("aib-conv-send-form").onsubmit({ preventDefault() {} }); h.$("aib-conv-input").value = "  "; await h.$("aib-conv-send-form").onsubmit({ preventDefault() {} });
  assert.strictEqual(h.posts().length, before);
});
test("reopening restores the conversation after a page reload, with its messages, budget and context", async () => {
  const state = { conv: convView({ messages: [turn(1), turn(2, { user: "second", assistant: "second answer" })], budget: budget("ok", 30), context: { last_tokens: 2500, warning: false } }) };
  const h = await chat(state, CID);
  assert.deepStrictEqual(bubbles(h).map(x => x.text.split("Sonnet")[0]), ["What does scenario 01 do?", "It installs the cluster.", "second", "second answer"]);
  assert.match(h.text("aib-conv-meta"), /2 messages · Context ≈ 2,500 tokens/); assert.match(h.text("aib-conv-budget"), /\(30%\)/); assert.strictEqual(h.text("aib-conv-title"), "What does scenario 01 do?");
  const other = harness({ routes: chatRoutes({ conv: null }) }); other.store.set("aibConv", "c-20200101-000000-ffffff"); await other.open();
  assert.strictEqual(other.$("aib-conv").hidden, true, "a saved id the server no longer lists is ignored");
});
test("budget warning at 80% and stop at 100% are shown; at 100% nothing can be sent", async () => {
  const warn = await chat({ conv: convView({ budget: budget("warning", 85), context: { last_tokens: 200000, warning: true } }) }, CID);
  assert.strictEqual(warn.$("aib-conv-warn").hidden, false); assert.match(warn.text("aib-conv-warn"), /80% .*estimated cost.*large/s); assert.match(warn.$("aib-budget").className, /warn/);
  warn.$("aib-conv-input").value = "still allowed"; await warn.$("aib-conv-input").oninput(); assert.strictEqual(warn.$("aib-conv-send").disabled, false);
  const stop = await chat({ conv: convView({ budget: budget("exhausted", 100) }) }, CID);
  assert.match(stop.text("aib-conv-warn"), /budget is used up/); assert.match(stop.$("aib-budget").className, /bad/);
  stop.$("aib-conv-input").value = "blocked"; await stop.$("aib-conv-send-form").onsubmit({ preventDefault() {} }); assert.strictEqual(stop.posts().length, 0);
  assert.strictEqual(stop.$("aib-conv-send").disabled, true);
});
test("a failed reply is shown as an error with its metrics; missing metrics read n/a", async () => {
  const bad = turn(1, { status: "error", error: "Claude Code timed out after 900s", assistant: "", usage: null, cost_usd: null, seconds: 900 });
  const h = await chat({ conv: convView({ messages: [bad] }) }, CID);
  const b = bubbles(h); assert.ok(b[1].kind.includes("error")); assert.match(b[1].text, /timed out after 900s.*Sonnet · 900sDetails.*Input tokensn\/a.*Estimated costn\/a/);
});
test("sending is off while Claude is not signed in or the AI Builder is stopped", async () => {
  const h = harness({ routes: { ...chatRoutes({ conv: convView() }), "GET /api/ai-builder/health": { status: 200, body: { available: true, state: "not_signed_in", claude_credentials_present: false } } } });
  h.store.set("aibConv", CID); await h.open();
  h.$("aib-conv-input").value = "hello"; await h.$("aib-conv-input").oninput(); assert.strictEqual(h.$("aib-conv-send").disabled, true);
  await h.$("aib-conv-send-form").onsubmit({ preventDefault() {} }); assert.strictEqual(h.posts().length, 0);
});
test("conversations only use /api/ai-builder/, never store message text, and are written with textContent", async () => {
  const state = { conv: convView() }; const h = await chat(state, CID);
  h.$("aib-conv-input").value = "secret-looking question"; await h.$("aib-conv-send-form").onsubmit({ preventDefault() {} }); await tick(30);
  for (const f of h.fetches) { assert.ok(f.url.startsWith("/api/ai-builder/"), f.url); assert.deepStrictEqual(Object.keys(f.headers).filter(k => !["X-Requested-With", "Content-Type"].includes(k)), []); }
  assert.deepStrictEqual([...h.store.keys()].sort(), ["aibConv"]); assert.ok(![...h.store.values()].join("").includes("secret-looking"), "only the conversation id is remembered");
  for (const id of ["aib-chat-pane", "aib-hist-toggle", "aib-hist", "aib-hist-search", "aib-hist-list", "aib-hist-archived", "aib-conv-title", "aib-conv-new", "aib-conv",
    "aib-conv-meta", "aib-budget", "aib-conv-bar", "aib-conv-budget", "aib-conv-warn", "aib-conv-messages", "aib-conv-send-form", "aib-conv-input", "aib-conv-count", "aib-conv-send", "aib-conv-error"]) assert.ok(HTML_IDS.has(id), id);
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML/.test(SRC.replace(/\/\/.*$/gm, "")), "no markup from backend values");
  assert.match(CSS, /#aib \.aib-msg\b/);
});

// ---------------------------------------------------------------------------------------------------------------------
// 4. Editing a Lab in a conversation (SPEC-023)
// ---------------------------------------------------------------------------------------------------------------------
const WS = (changes = { modified: 1, added: 1 }, extra = {}) => {
  const c = { added: 0, modified: 0, deleted: 0, ...changes }; c.total = c.added + c.modified + c.deleted;
  return { lab: "cnpg-standard", exists: true, editing: true, changes: c, can_undo: true, conflict: false, publications: 0, ...extra };
};
const REVIEW = (extra = {}) => ({ lab: "cnpg-standard", changes: { modified: ["README.md"], added: ["02_new.sh"], deleted: [] }, total: 2, tree_hash: "a".repeat(64), conflict: false, can_undo: true, can_publish: true,
  validation: { passed: true, errors: [] }, diff: [
    { path: "README.md", change: "modified", diff: "--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-# Old\n+# New\n", truncated: false },
    { path: "02_new.sh", change: "added", diff: "--- a/02_new.sh\n+++ b/02_new.sh\n+echo hi\n", truncated: false }], ...extra });
const U = `/api/ai-builder/conversations/${CID}`;
function editRoutes(state) {
  const r = chatRoutes(state);
  r[`GET ${U}/review`] = () => ({ status: 200, body: state.review || REVIEW() });
  for (const op of ["undo", "reset", "discard"]) r[`POST ${U}/${op}`] = () => { state.ops = [...(state.ops || []), op]; if (state.opReply) return state.opReply; state.conv = { ...state.conv, workspace: op === "discard" ? WS({}, { exists: false, can_undo: false }) : WS({}, { can_undo: false }) }; return { status: 200, body: state.conv }; };
  r[`POST ${U}/publish`] = opts => {
    state.published = (state.published || 0) + 1; state.publishBody = JSON.parse(opts.body);
    if (state.publishReply) return state.publishReply;
    state.conv = { ...state.conv, workspace: WS({}, { can_undo: false, editing: false, publications: 1 }) };
    return { status: 200, body: { lab: "cnpg-standard", published: "usecases/cnpg-standard", changes: { modified: 1, added: 1, deleted: 0 }, run: "./playground usecase start cnpg-standard", conversation: state.conv } };
  };
  return r;
}
const editChat = async (state) => { const h = harness({ routes: editRoutes(state) }); h.store.set("aibConv", CID); await h.open(); await tick(10); return h; };
const withWs = (ws, extra = {}) => ({ conv: convView({ workspace: ws, can_edit: true, ...extra }) });
const spanClasses = h => h.$("aib-cr-diff").children.map(s => s.className);

test("pending changes: text, tags, publish rule and diff coloring", () => {
  assert.strictEqual(core.describeChanges(null).show, false); assert.strictEqual(core.describeChanges(WS({}, { exists: false })).show, false);
  assert.strictEqual(core.describeChanges(WS({}, { can_undo: false })).show, false, "nothing pending and nothing to undo: no bar");
  assert.strictEqual(core.describeChanges(WS({})).show, true);
  const d = core.describeChanges(WS({ modified: 1, added: 2, deleted: 1 }));
  assert.strictEqual(d.text, "4 files changed in the working copy (1 modified, 2 added, 1 deleted) · not published");
  assert.match(core.describeChanges(WS({ modified: 1 })).text, /^1 file changed/); assert.strictEqual(core.describeChanges(WS({}, { conflict: true })).conflict, false, "a conflict only matters when there are changes");
  assert.strictEqual(core.describeChanges(WS({ added: 1 }, { conflict: true })).conflict, true);
  assert.deepStrictEqual(["modified", "added", "deleted"].map(core.changeTag), ["~", "+", "−"]);
  const ok = { review: REVIEW(), confirmed: true, busy: false };
  assert.strictEqual(core.canPublishChanges(ok), true);
  for (const bad of [{ confirmed: false }, { busy: true }, { review: null }, { review: REVIEW({ can_publish: false }) }, { review: REVIEW({ conflict: true, can_publish: false }) }, { review: REVIEW({ validation: { passed: false, errors: ["x"] }, can_publish: false }) }])
    assert.strictEqual(core.canPublishChanges({ ...ok, ...bad }), false, JSON.stringify(Object.keys(bad)));
  assert.deepStrictEqual(core.diffLines("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same\n").map(l => l.cls), ["meta", "meta", "hunk", "del", "add", ""]);
  assert.match(core.turnMeta(turn(1, { changed: ["README.md", "02_new.sh"] })), /changed README\.md, 02_new\.sh$/);
});
test("the pending-changes bar appears with counts and its three buttons; no bar without changes", async () => {
  const h = await editChat({ conv: convView({ workspace: WS(), can_edit: true }) });
  assert.strictEqual(h.$("aib-changes").hidden, false); assert.match(h.text("aib-changes-text"), /^2 files changed in the working copy \(1 modified, 1 added\) · not published$/);
  assert.deepStrictEqual(["aib-changes-review", "aib-changes-undo", "aib-changes-reset"].map(id => h.$(id).disabled), [false, false, false]);
  assert.strictEqual(h.$("aib-changes-conflict").hidden, true); assert.strictEqual(h.$("aib-cr").hidden, true);
  assert.match(h.$("aib-conv-input").placeholder, /ask for a change to the Lab/);
  const none = await editChat({ conv: convView({ workspace: WS({}, { exists: false, can_undo: false }), can_edit: true }) }); assert.strictEqual(none.$("aib-changes").hidden, true);
  const free = await editChat({ conv: convView({ workspace: null, can_edit: false, lab: null }) }); assert.strictEqual(free.$("aib-changes").hidden, true); assert.doesNotMatch(free.$("aib-conv-input").placeholder, /change to the Lab/);
});
test("the bar is locked while Claude answers", async () => {
  const h = await editChat({ conv: convView({ workspace: WS(), can_edit: true, status: "running", pending: { n: 1, user: "x" } }), becomeIdleAfter: 99 });
  assert.deepStrictEqual(["aib-changes-review", "aib-changes-undo", "aib-changes-reset"].map(id => h.$(id).disabled), [true, true, true]); h.$("aib-close").onclick();
});
test("Review changes lists the files with their change, shows the colored diff and keeps Publish off until approved", async () => {
  const state = { conv: convView({ workspace: WS(), can_edit: true }) }; const h = await editChat(state);
  await h.click("aib-changes-review");
  assert.strictEqual(h.fetches.filter(f => f.url === `${U}/review`).length, 1); assert.strictEqual(h.$("aib-cr").hidden, false);
  assert.deepStrictEqual(h.$("aib-cr-files").children.map(li => li.children[0].textContent), ["~ README.md", "+ 02_new.sh"]);
  assert.deepStrictEqual(spanClasses(h), ["aib-dl meta", "aib-dl meta", "aib-dl hunk", "aib-dl del", "aib-dl add"]); assert.match(h.text("aib-cr-validation"), /Validation passed/);
  assert.match(h.text("aib-cr-confirm-text"), /approve publishing them to usecases\/cnpg-standard/);
  assert.strictEqual(h.$("aib-cr-publish").disabled, true, "needs the explicit approval");
  h.$("aib-cr-files").children[1].children[0].onclick(); assert.match(h.$("aib-cr-diff").children.map(textOf).join(""), /\+echo hi/);
  h.$("aib-cr-confirm").checked = true; await h.$("aib-cr-confirm").onchange(); assert.strictEqual(h.$("aib-cr-publish").disabled, false);
  assert.strictEqual(h.posts().length, 0, "reviewing publishes nothing");
});
test("a failed validation or a conflict keeps Publish disabled even when approved", async () => {
  const bad = { conv: convView({ workspace: WS(), can_edit: true }), review: REVIEW({ can_publish: false, validation: { passed: false, errors: ["a scenario references manifests/x.yaml, which does not exist in the draft"] } }) };
  const h = await editChat(bad); await h.click("aib-changes-review");
  assert.match(h.text("aib-cr-validation"), /Validation failed/); assert.deepStrictEqual(h.$("aib-cr-errors").children.map(li => li.textContent), [bad.review.validation.errors[0]]);
  h.$("aib-cr-confirm").checked = true; await h.$("aib-cr-confirm").onchange(); assert.strictEqual(h.$("aib-cr-publish").disabled, true);
  const state = { conv: convView({ workspace: WS({ modified: 1 }, { conflict: true }), can_edit: true }), review: REVIEW({ conflict: true, can_publish: false }) };
  const c = await editChat(state); assert.strictEqual(c.$("aib-changes-conflict").hidden, false);
  await c.click("aib-changes-review"); c.$("aib-cr-confirm").checked = true; await c.$("aib-cr-confirm").onchange();
  assert.strictEqual(c.$("aib-cr-publish").disabled, true); assert.match(c.text("aib-cr-note"), /published Lab changed/);
  await c.$("aib-cr-publish").onclick(); assert.strictEqual(c.posts().length, 0, "never sent");
});
test("publishing sends the approval and the reviewed hash once, then shows the result and refreshes the Lab list", async () => {
  const state = { conv: convView({ workspace: WS(), can_edit: true }) }; const h = await editChat(state);
  await h.click("aib-changes-review"); h.$("aib-cr-confirm").checked = true; await h.$("aib-cr-confirm").onchange();
  const f = h.$("aib-cr-publish").onclick; await Promise.all([f(), f()]); await tick(20);
  assert.strictEqual(state.published, 1, "a double click publishes once");
  const post = h.posts().find(p => p.url.endsWith("/publish"));
  assert.deepStrictEqual([post.body, post.headers["X-Requested-With"]], [{ approve: true, tree_hash: "a".repeat(64) }, "playground"]);
  assert.match(h.text("aib-cr-result"), /^Published as usecases\/cnpg-standard\. Start it from the sidebar, or run: \.\/playground usecase start cnpg-standard$/);
  assert.strictEqual(h.counters.refreshUseCases, 1); assert.strictEqual(h.$("aib-changes").hidden, true, "the working copy is clean again"); assert.strictEqual(h.$("aib-cr").hidden, true);
});
test("a refused publication keeps the reason, reloads the real state and publishes nothing", async () => {
  const state = { conv: convView({ workspace: WS(), can_edit: true }), publishReply: { status: 409, body: { error: "conflict: usecases/cnpg-standard changed since the working copy was made. Nothing was overwritten" } } };
  const h = await editChat(state); await h.click("aib-changes-review"); h.$("aib-cr-confirm").checked = true; await h.$("aib-cr-confirm").onchange(); await h.click("aib-cr-publish"); await tick(10);
  assert.match(h.text("aib-conv-error"), /^Publish refused: conflict: usecases\/cnpg-standard changed/); assert.strictEqual(h.counters.refreshUseCases, 0);
  assert.ok(h.fetches.filter(f => f.url === U).length >= 2, "the conversation was reloaded"); assert.strictEqual(h.$("aib-cr-publish").disabled, true);
});
test("Undo is one click; Reset and Start over need a second click; nothing is sent on the first", async () => {
  const state = { conv: convView({ workspace: WS(), can_edit: true }) }; const h = await editChat(state);
  await h.click("aib-changes-undo"); assert.deepStrictEqual(state.ops, ["undo"]); assert.strictEqual(h.$("aib-changes").hidden, true, "the answer had no pending changes left");
  const s2 = { conv: convView({ workspace: WS(), can_edit: true }) }; const r = await editChat(s2);
  await r.click("aib-changes-reset"); assert.strictEqual(s2.ops, undefined); assert.strictEqual(r.text("aib-changes-reset"), "Confirm reset?");
  await r.click("aib-changes-reset"); assert.deepStrictEqual(s2.ops, ["reset"]); assert.strictEqual(r.posts().filter(p => p.url.endsWith("/reset"))[0].headers["X-Requested-With"], "playground");
  const s3 = { conv: convView({ workspace: WS({ modified: 1 }, { conflict: true }), can_edit: true }) }; const d = await editChat(s3);
  await d.click("aib-changes-discard"); assert.strictEqual(s3.ops, undefined); assert.match(d.text("aib-changes-discard"), /Confirm/);
  await d.click("aib-changes-discard"); assert.deepStrictEqual(s3.ops, ["discard"]); assert.strictEqual(d.$("aib-changes-conflict").hidden, true);
});
test("an undo that the server refuses shows its message and leaves the state alone", async () => {
  const state = { conv: convView({ workspace: WS(), can_edit: true }), opReply: { status: 409, body: { error: "nothing to undo" } } }; const h = await editChat(state);
  await h.click("aib-changes-undo"); assert.match(h.text("aib-conv-error"), /nothing to undo/); assert.strictEqual(h.$("aib-changes").hidden, false);
});
test("editing controls only use /api/ai-builder/, the CSRF header on every POST, and markup is never built from backend text", async () => {
  const state = { conv: convView({ workspace: WS(), can_edit: true }) }; const h = await editChat(state);
  await h.click("aib-changes-review"); h.$("aib-cr-confirm").checked = true; await h.$("aib-cr-confirm").onchange(); await h.click("aib-cr-publish"); await tick(10); await h.click("aib-changes-undo");
  for (const f of h.fetches) { assert.ok(f.url.startsWith("/api/ai-builder/"), f.url); if (f.method === "POST") assert.strictEqual(f.headers["X-Requested-With"], "playground"); }
  for (const id of ["aib-changes", "aib-changes-text", "aib-changes-review", "aib-changes-undo", "aib-changes-reset", "aib-changes-conflict", "aib-changes-discard", "aib-cr", "aib-cr-files", "aib-cr-diff",
    "aib-cr-validation", "aib-cr-errors", "aib-cr-confirm", "aib-cr-confirm-text", "aib-cr-note", "aib-cr-publish", "aib-cr-result"]) assert.ok(HTML_IDS.has(id), id);
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML/.test(SRC.replace(/\/\/.*$/gm, "")));
  assert.deepStrictEqual([...h.store.keys()].sort(), ["aibConv"], "no diff, file or message text is stored in the browser");
});

// ---------------------------------------------------------------------------------------------------------------------
// 5. The redesigned panel (SPEC-024): Markdown, highlighting, docked layout, composer, scrolling, activity, changes
// ---------------------------------------------------------------------------------------------------------------------
const { AIBMarkdown: MD, AIBHighlight: HL } = require(path.join(ROOT, "web/static/ai-markdown.js"));
const mdDoc = { createElement: tag => new El(null, tag), createTextNode: s => { const e = new El(null, "#text"); e.textContent = s; return e; } };
const walk = (el, fn) => { fn(el); (el.children || []).forEach(c => walk(c, fn)); };
const tags = el => { const out = []; walk(el, e => out.push(e.tag)); return out; };
const renderMd = (text, opts) => MD.render(text, mdDoc, opts);

test("Markdown: blocks, inline styles, lists, tables, quotes and code", () => {
  const ast = MD.parse("# Title\n\nSome **bold**, *it*, `code` and ~~gone~~.\nsecond line\n\n- one\n- two\n  - nested\n3. a\n4. b\n\n> quote\n\n---\n\n| a | b |\n|:-:|--:|\n| 1 | 2 |\n\n```bash\nls -l\n```");
  assert.deepStrictEqual(ast.map(b => b.t), ["h", "p", "ul", "ol", "quote", "hr", "table", "code"]);
  assert.strictEqual(ast[0].level, 1); assert.deepStrictEqual(ast[1].c.map(n => n.t), ["text", "strong", "text", "em", "text", "code", "text", "del", "text"]);
  assert.strictEqual(ast[1].c[ast[1].c.length - 1].v, ". second line", "a soft line break reads as a space");
  assert.deepStrictEqual(ast[2].items.map(i => i.map(b => b.t)), [["p"], ["p", "ul"]]); assert.strictEqual(ast[3].start, 3);
  assert.deepStrictEqual(ast[6].align, ["center", "right"]); assert.strictEqual(ast[7].lang, "bash"); assert.strictEqual(ast[7].text, "ls -l");
});
test("Markdown: snake_case, multiplication, escapes, unclosed fences and empty input are handled", () => {
  assert.deepStrictEqual(MD.inline("snake_case_word and 2 * 3 * 4").map(n => n.t), ["text"]);
  assert.deepStrictEqual(MD.inline("window.__xss=true and x__y__z").map(n => n.t), ["text"], "double underscores inside a word are not emphasis");
  assert.deepStrictEqual(MD.inline("__bold__ and **bold**").map(n => n.t), ["strong", "text", "strong"]);
  assert.strictEqual(MD.inline("a \\*not italic\\* b")[0].v, "a *not italic* b");
  assert.strictEqual(MD.parse("```yaml\nkey: value\nno closing fence")[0].text, "key: value\nno closing fence");
  assert.deepStrictEqual(MD.parse(""), []); assert.deepStrictEqual(MD.parse(null), []); assert.deepStrictEqual(MD.parse("   \n\n"), []);
  assert.ok(JSON.stringify(MD.parse("x".repeat(100000))).length < 40000, "very long input is capped");
});
test("Markdown: HTML in a reply is text, never an element; only http(s) and mailto links are links", () => {
  const root = renderMd("<script>alert(1)</script> <img src=x onerror=alert(1)>\n\n[ok](https://example.com/a) [mail](mailto:a@b.c) [bad](javascript:alert(1)) [data](data:text/html,x) [rel](/etc/passwd)");
  const t = tags(root); for (const bad of ["script", "img", "iframe", "style"]) assert.ok(!t.includes(bad), bad);
  assert.match(textOf(root), /<script>alert\(1\)<\/script> <img src=x onerror=alert\(1\)>/);
  const links = []; walk(root, e => { if (e.tag === "a") links.push(e); });
  assert.deepStrictEqual(links.map(a => a.href), ["https://example.com/a", "mailto:a@b.c"]);
  for (const a of links) assert.deepStrictEqual([a.target, a.rel], ["_blank", "noopener noreferrer"]);
  assert.ok(!JSON.stringify([...links]).includes("javascript:"));
});
test("Markdown: a code block has its language, a Copy button that copies exactly the code, and highlighted tokens", () => {
  const copied = [];
  const root = renderMd("Run:\n\n```bash\nkubectl get pods --all-namespaces # list\n```", { copy: (code, btn) => copied.push([code, btn.textContent]) });
  let box = null; walk(root, e => { if (e.className === "aib-codeblock") box = e; });
  assert.ok(box, "code block"); const [head] = box.children; assert.strictEqual(head.children[0].textContent, "bash");
  const copy = head.children[1]; assert.deepStrictEqual([copy.tag, copy.textContent, copy.type], ["button", "Copy", "button"]);
  copy.onclick(); assert.deepStrictEqual(copied, [["kubectl get pods --all-namespaces # list", "Copy"]]);
  const classes = []; walk(box, e => { if (/^tk-/.test(e.className)) classes.push(e.className); }); assert.deepStrictEqual(classes, ["tk-flag", "tk-com"]);
  assert.strictEqual(textOf(box.children[1]), "kubectl get pods --all-namespaces # list");
});
test("highlighting: languages, aliases, whole-line coverage and diff lines", () => {
  for (const [alias, lang] of [["sh", "bash"], ["Bash", "bash"], ["zsh", "bash"], ["yml", "yaml"], ["YAML", "yaml"], ["psql", "sql"], ["patch", "diff"], ["01_demo.sh", "bash"], ["manifests/cluster.yaml", "yaml"], ["README.md", "text"], ["", "text"], [null, "text"], ["rust", "text"]]) assert.strictEqual(HL.langFor(alias), lang, String(alias));
  const kinds = (lang, line) => HL.line(lang, line).filter(t => t.cls).map(t => `${t.cls}:${t.text}`);
  assert.deepStrictEqual(kinds("bash", 'if [ -n "$X" ]; then echo "hi" # c'), ["kw:if", "flag:-n", 'str:"$X"', "op:;", "kw:then", "kw:echo", 'str:"hi"', "com:# c"]);
  assert.ok(kinds("bash", 'echo "$HOME" ${VAR} $(date) --flag -n 3').includes("var:${VAR}") && kinds("bash", "ls --all -l").includes("flag:--all"));
  assert.deepStrictEqual(kinds("yaml", "  name: demo # c"), ["key:name", "com:# c"]); assert.deepStrictEqual(kinds("yaml", "replicas: 3"), ["key:replicas", "num:3"]);
  assert.deepStrictEqual(kinds("json", '{"a": 1, "b": true, "c": "x"}'), ['key:"a"', "num:1", 'key:"b"', "kw:true", 'key:"c"', 'str:"x"']);
  assert.deepStrictEqual(kinds("sql", "SELECT count(*) FROM t WHERE a = 'x' -- c"), ["kw:SELECT", "kw:count", "kw:FROM", "kw:WHERE", "str:'x'", "com:-- c"]); assert.ok(kinds("sql", "select 1").includes("kw:select"), "case-insensitive");
  assert.deepStrictEqual(["+++ b/x", "--- a/x", "@@ -1 +1 @@", "+new", "-old", " ctx"].map(l => HL.line("diff", l)[0].cls), ["meta", "meta", "hunk", "add", "del", ""]);
  const samples = ['a "unclosed string', "it's # not a comment", "", "$", "--", "{[(", "tab\tand  spaces ", "ünïcödé 日本語 \"x\""];
  for (const lang of ["bash", "yaml", "json", "sql", "diff", "text"]) for (const line of samples) assert.strictEqual(HL.line(lang, line).map(t => t.text).join(""), line, `${lang}: ${JSON.stringify(line)}`);
});
test("panel width: limits, room left for the terminals, pointer and keyboard math", () => {
  const c = core.clampPanelWidth;
  assert.strictEqual(c(500, 1400, 293), 500); assert.strictEqual(c(100, 1400, 293), 320, "minimum"); assert.strictEqual(c(5000, 1400, 0), 1260, "maximum: 90% of the viewport"); assert.strictEqual(c(5000, 0, 0), 720, "unknown geometry: the absolute limit");
  assert.strictEqual(c(5000, 1400, 293), 1059, "with the sidebar open the terminals keep 48 px: 1400 - 293 - 48"); assert.strictEqual(c(720, 900, 293), 559, "900 - 293 - 48"); assert.strictEqual(c(720, 500, 293), 320, "never below the minimum");
  assert.strictEqual(c(undefined, 1400, 0), 440); assert.strictEqual(c(NaN, 1400, 0), 440); assert.strictEqual(c("abc", 1400, 0), 440); assert.strictEqual(c(450.6, 0, 0), 451, "unknown geometry: only the absolute limits");
  assert.strictEqual(core.panelWidthFromPointer(900, 1400), 500);
  assert.strictEqual(core.composerHeight(10), 40); assert.strictEqual(core.composerHeight(100), 102); assert.strictEqual(core.composerHeight(900), 180);
  assert.strictEqual(core.isNearBottom({ scrollHeight: 1000, scrollTop: 700, clientHeight: 300 }), true); assert.strictEqual(core.isNearBottom({ scrollHeight: 1000, scrollTop: 100, clientHeight: 300 }), false);
  assert.strictEqual(core.isNearBottom({}), true, "unknown geometry never blocks the scroll");
});
test("activity: every state comes from real information; no percentages, no guessed sub-steps", () => {
  const now = Date.parse("2026-11-17T12:00:30Z"), a = o => core.describeActivity({ canGenerate: true, now, ...o });
  const idle = convView({ messages: [turn(1)] });
  assert.deepStrictEqual([a({ conv: idle }).kind, a({ conv: idle }).text], ["ready", "Ready · waiting for your message"]); assert.strictEqual(a({ conv: null }).text, "Select a conversation or start a new one");
  const run = a({ conv: convView({ status: "running", pending: { n: 1, user: "x", started: "2026-11-17T12:00:00Z", edit: false } }) });
  assert.deepStrictEqual([run.kind, run.busy, run.text], ["busy", true, "Claude is thinking · 00:30…"]);
  const edit = a({ conv: convView({ status: "running", pending: { n: 1, user: "x", started: "2026-11-17T12:00:00Z", edit: true } }) });
  assert.match(edit.text, /^Claude is working on your request \(editing is enabled for this message\) · 00:30…$/);
  assert.match(a({ conv: idle, sending: true }).text, /^Sending your message/); assert.match(a({ conv: idle, ops: { review: true } }).text, /^Validating the changes/);
  assert.match(a({ conv: idle, ops: { publish: true } }).text, /^Publishing to usecases\/cnpg-standard/); assert.match(a({ conv: idle, ops: { undo: true } }).text, /^Undoing/);
  assert.match(a({ conv: idle, ops: { reset: true } }).text, /^Resetting/); assert.match(a({ conv: idle, ops: { discard: true } }).text, /^Starting over/);
  const failed = a({ conv: convView({ messages: [turn(1, { status: "error", error: "Claude Code timed out after 900s" })] }) });
  assert.deepStrictEqual([failed.kind, failed.busy], ["error", false]); assert.match(failed.text, /timed out after 900s/);
  assert.deepStrictEqual([a({ conv: idle, canGenerate: false }).kind, a({ conv: idle, canGenerate: false }).busy], ["offline", false]);
  for (const s of [run, edit, a({ conv: idle, sending: true }), a({ conv: idle, ops: { review: true } }), a({ conv: idle })]) assert.doesNotMatch(s.text, /\d+\s?%|step \d|analy[sz]ing|reading the lab/i, s.text);
  assert.strictEqual(a({ conv: convView({ status: "running", pending: { n: 1, user: "x" } }) }).text, "Claude is thinking…", "no elapsed time without a start time");
});

const panelChat = async (state, extra = {}) => { const h = harness({ routes: { ...editRoutes(state), ...(extra.routes || {}) }, ...(extra.saved ? { saved: extra.saved } : {}) }); if (extra.width) h.$("app-main").width = extra.width;
  for (const [k, v] of Object.entries(extra.store || {})) h.store.set(k, v); h.store.set("aibConv", CID); await h.open(); await tick(10); return h; };
const ptr = (h, type, x, extra = {}) => h.$("aib-resizer")["on" + type]({ pointerId: 1, clientX: x, button: 0, preventDefault() {}, ...extra });

test("open and close: the header button toggles the docked panel, with its state, focus and polling", async () => {
  const state = { conv: convView({ messages: [turn(1)] }) }; const h = harness({ routes: chatRoutes(state) }); h.store.set("aibConv", CID);
  assert.strictEqual(h.$("aib-open").attrs["aria-expanded"], undefined);
  await h.click("aib-open"); await tick(10);
  assert.deepStrictEqual([h.$("aib").hidden, h.$("aib-resizer").hidden, h.$("app-main").className, h.$("aib-open").attrs["aria-expanded"]], [false, false, "aib-open", "true"]);
  assert.match(h.$("aib-open").title, /^Close/); assert.strictEqual(h.$("aib-chat-pane").hidden, false, "the assistant is the whole panel");
  assert.ok(h.$("aib-conv-input").focused > 0, "the composer takes the focus"); assert.ok(h.$("aib-conv").hidden === false);
  await h.click("aib-open");                                                      // the same button closes it
  assert.deepStrictEqual([h.$("aib").hidden, h.$("aib-resizer").hidden, h.$("app-main").className, h.$("aib-open").attrs["aria-expanded"]], [true, true, "", "false"]);
  assert.ok(h.$("aib-open").focused > 0, "the focus returns to the button");
  await h.click("aib-open"); assert.strictEqual(h.$("aib").hidden, false); await h.click("aib-close"); assert.strictEqual(h.$("aib").hidden, true, "the close button works too");
  const n = h.fetches.length; await tick(30); assert.strictEqual(h.fetches.length, n, "nothing polls while the panel is closed");
});
test("a running reply is followed again when the panel is reopened", async () => {
  const state = { conv: convView({ status: "running", pending: { n: 1, user: "slow", started: new Date().toISOString() } }), becomeIdleAfter: 2 };
  state.finish = () => { state.conv = { ...state.conv, status: "idle", pending: null, messages: [turn(1, { user: "slow", assistant: "done" })] }; state.finish = null; };
  const h = harness({ routes: chatRoutes(state) }); h.store.set("aibConv", CID); await h.click("aib-open"); await h.click("aib-close"); await h.click("aib-open"); await tick(40);
  assert.strictEqual(bubbles(h).some(b => /done/.test(b.text)), true);
});
test("the width: default, drag with the pointer, limits, persistence, keyboard, double-click, window resize", async () => {
  const h = harness({ routes: chatRoutes({ conv: null }) }); const main = h.$("app-main");
  await h.click("aib-open"); assert.strictEqual(main.style.props["--aib-w"], "440px"); assert.strictEqual(h.$("aib-resizer").attrs["aria-valuenow"], "440");
  ptr(h, "pointerdown", 960); assert.match(main.className, /aib-dragging/, "the terminals ignore the pointer during a drag");
  ptr(h, "pointermove", 900); assert.strictEqual(main.style.props["--aib-w"], "500px");
  ptr(h, "pointermove", 1390); assert.strictEqual(main.style.props["--aib-w"], "320px", "minimum"); ptr(h, "pointermove", 10); assert.strictEqual(main.style.props["--aib-w"], "1260px", "maximum: 90% of a 1400 px window");
  ptr(h, "pointermove", 800); ptr(h, "pointerup", 800);
  assert.doesNotMatch(main.className, /aib-dragging/); assert.strictEqual(h.store.get("aibPanelWidth"), "600"); assert.strictEqual(h.$("aib-resizer").attrs["aria-valuenow"], "600");
  ptr(h, "pointermove", 700); assert.strictEqual(main.style.props["--aib-w"], "600px", "moving without a drag changes nothing");
  const key = (k, shift) => h.$("aib-resizer").onkeydown({ key: k, shiftKey: !!shift, preventDefault() {} });
  key("ArrowLeft"); assert.strictEqual(main.style.props["--aib-w"], "616px"); key("ArrowLeft", true); assert.strictEqual(main.style.props["--aib-w"], "680px");
  key("ArrowRight"); assert.strictEqual(main.style.props["--aib-w"], "664px"); key("Home"); assert.strictEqual(main.style.props["--aib-w"], "320px"); key("End"); assert.strictEqual(main.style.props["--aib-w"], "1260px");
  assert.strictEqual(h.store.get("aibPanelWidth"), "1260"); key("a");                                              // another key is ignored
  h.$("aib-resizer").ondblclick(); assert.strictEqual(main.style.props["--aib-w"], "440px"); assert.strictEqual(h.store.get("aibPanelWidth"), "440");
  key("End"); main.width = 700; const resize = h.windowListeners.filter(([t]) => t === "resize"); assert.strictEqual(resize.length, 1, "one window listener");
  resize[0][1](); assert.strictEqual(main.style.props["--aib-w"], "630px", "the width follows a smaller window (90% of 700)");
  await h.click("aib-close"); main.width = 1400; resize[0][1](); assert.strictEqual(main.style.props["--aib-w"], "630px", "a closed panel is left alone");
});
test("the saved width is restored on the next visit and a damaged value is ignored", async () => {
  for (const [saved, expected] of [["600", "600px"], ["5000", "1260px"], ["10", "320px"], ["abc", "440px"], ["-5", "440px"], ["", "440px"]]) {
    const h = harness({ routes: chatRoutes({ conv: null }), storage: { aibPanelWidth: saved } }); await h.click("aib-open"); assert.strictEqual(h.$("app-main").style.props["--aib-w"], expected, saved);
  }
});
test("opening, closing and resizing the panel never touch the terminals or add resize logic of their own", () => {
  const code = SRC.replace(/\/\/.*$/gm, "");
  for (const word of ["#panes", "panes", "iframe", "ttyd", "focusActive", "--cx", "--cy", "terminal"]) assert.ok(!code.includes(word), `ai-builder.js must not mention ${word}`);
  assert.strictEqual((code.match(/addEventListener\("resize"/g) || []).length, 1); assert.ok(!/ResizeObserver|onresize/.test(code), "no competing resize observers");
  assert.ok(/addEventListener\("resize", \(\) => \{ if \(S\.panelOpen\) applyWidth\(panelState\.width, false\); \}\)/.test(code), "the one listener only re-clamps the panel width");
  assert.ok(!/ai-builder|aib/.test(fs.readFileSync(path.join(ROOT, "web/static/app.js"), "utf8")), "app.js is untouched");
  assert.ok(/main\.aib-dragging #panes iframe \{ pointer-events: none; \}/.test(CSS), "the CSS keeps iframes from swallowing a drag");
});
test("composer: Enter sends, Shift+Enter is a new line, an IME composition never sends, and the textarea grows", async () => {
  const state = { conv: convView() }; const h = await panelChat(state); const ta = h.$("aib-conv-input");
  const key = (o) => { let prevented = false; ta.onkeydown({ key: "Enter", shiftKey: false, isComposing: false, keyCode: 13, preventDefault() { prevented = true; }, ...o }); return prevented; };
  ta.value = "Line one\nline two"; assert.strictEqual(key({ shiftKey: true }), false, "Shift+Enter is left to the browser (a new line)"); await tick(5); assert.strictEqual(h.posts().length, 0);
  assert.strictEqual(key({ isComposing: true }), false); assert.strictEqual(key({ keyCode: 229 }), false); await tick(5); assert.strictEqual(h.posts().length, 0, "no send while composing");
  ta.value = "   "; key({}); await tick(5); assert.strictEqual(h.posts().length, 0, "an empty message is never sent");
  ta.value = "How do I read from the replica?"; assert.strictEqual(key({}), true); await tick(10);
  const post = h.posts().find(p => p.url.endsWith("/messages")); assert.deepStrictEqual(post.body, { message: "How do I read from the replica?" });
  ta.scrollHeight = 120; ta.value = "x"; ta.oninput(); assert.strictEqual(ta.style.height, "122px"); ta.scrollHeight = 900; ta.oninput(); assert.strictEqual(ta.style.height, "180px", "capped");
  assert.strictEqual(h.text("aib-conv-count"), "1 / 4000");
});
test("smart scroll: it follows the conversation at the bottom, stays put when you read above, and offers a jump", async () => {
  const state = { conv: convView({ messages: [turn(1), turn(2)] }) }; const h = await panelChat(state); const box = h.$("aib-conv-messages");
  box.scrollHeight = 1000; box.clientHeight = 300; box.scrollTop = 700; box.onscroll();
  const reply = (n, text) => ({ ...state.conv, messages: [...state.conv.messages, turn(n, { assistant: text, finished: "t" + n })] });
  state.conv = reply(3, "third"); await reopen(h); await tick(10);
  assert.strictEqual(box.scrollTop, box.scrollHeight, "at the bottom: new content scrolls into view"); assert.strictEqual(h.$("aib-scroll-bottom").hidden, true);
  box.scrollTop = 100; box.onscroll();
  state.conv = { ...state.conv, status: "running", pending: { n: 5, user: "again", started: new Date().toISOString() } }; state.becomeIdleAfter = 1; state.gets = 0;
  state.finish = () => { state.conv = { ...state.conv, status: "idle", pending: null, messages: [...state.conv.messages, turn(5, { user: "again", assistant: "fifth", finished: "t5" })] }; state.finish = null; };
  await reopen(h); await tick(40);
  assert.strictEqual(box.scrollTop, 100, "the reader's position is kept"); assert.strictEqual(h.$("aib-scroll-bottom").hidden, false, "a jump button announces the new messages");
  h.$("aib-scroll-bottom").onclick(); assert.strictEqual(box.scrollTop, box.scrollHeight); assert.strictEqual(h.$("aib-scroll-bottom").hidden, true);
});
test("an unchanged conversation is not rebuilt on every poll (a selection or a focused Copy button survives)", async () => {
  const state = { conv: convView({ messages: [turn(1)] }) }; const h = await panelChat(state); const before = h.$("aib-conv-messages").children;
  await reopen(h); await tick(10);
  assert.ok(h.$("aib-conv-messages").children === before || h.$("aib-conv-messages").children.every((c, i) => c === before[i]), "same nodes");
});
test("replies are rendered as Markdown with a working Copy button; your own message and errors stay plain text", async () => {
  const reply = "Use **kubectl**:\n\n- one\n- two\n\n```bash\nkubectl get pods\n```\n\n<img src=x onerror=alert(1)>";
  const state = { conv: convView({ messages: [turn(1, { user: "show **me** <b>x</b>", assistant: reply }), turn(2, { status: "error", error: "**not** markdown", assistant: "" })] }) };
  const h = await panelChat(state); const kids = h.$("aib-conv-messages").children;
  const user = kids[0], assistant = kids[1], failed = kids[3];
  assert.strictEqual(user.textContent, "show **me** <b>x</b>", "plain text, nothing interpreted"); assert.strictEqual(user.children.length, 0);
  const t = tags(assistant); assert.ok(t.includes("strong") && t.includes("ul") && t.includes("li") && t.includes("pre") && t.includes("code") && !t.includes("img") && !t.includes("script"));
  assert.match(textOf(assistant), /<img src=x onerror=alert\(1\)>/); assert.match(textOf(assistant), /Sonnet · 3\.2s · est\. \$0\.042Details.*Input tokens4/);
  let copy = null; walk(assistant, e => { if (e.className === "aib-copy") copy = e; }); assert.ok(copy);
  const texts = []; let current = copy.textContent; Object.defineProperty(copy, "textContent", { get: () => current, set: v => { current = v; texts.push(v); } });
  await copy.onclick(); await tick(5); assert.deepStrictEqual(h.copied, ["kubectl get pods"]); assert.deepStrictEqual(texts, ["Copied", "Copy"], "feedback, then back to Copy");
  assert.strictEqual(failed.children[0] === undefined || failed.children[0].className === "aib-msg-meta", true); assert.match(failed.textContent, /\*\*not\*\* markdown/);
});
test("the Lab, the model and the estimated cost are shown, unobtrusively", async () => {
  const h = await panelChat({ conv: convView({ messages: [turn(1)], budget: budget("ok", 12) }) });
  assert.match(h.text("aib-conv-meta"), /^sonnet · 1 message · Context ≈ 1,500 tokens$/); assert.match(h.text("aib-conv-budget"), /^Estimated \$1\.20 of \$10\.00 \(12%\)$/);
  assert.match(HTML, /id="aib-budget"[^>]*title="[^"]*not a charge/);
  const free = await panelChat({ conv: convView({ lab: null, can_edit: false, workspace: null }) }); assert.match(free.text("aib-conv-meta"), /^No Lab · sonnet/);
});
test("the status line follows the conversation: ready, working (with the real start time), validating, publishing, error, offline", async () => {
  const idle = await panelChat({ conv: convView({ messages: [turn(1)] }) });
  assert.deepStrictEqual([idle.$("aib-activity").className, idle.text("aib-activity-text"), idle.$("aib-conv-messages").attrs["aria-busy"]], ["aib-activity ready", "Ready · waiting for your message", "false"]);
  const started = new Date(Date.now() - 12000).toISOString();
  const run = await panelChat({ conv: convView({ status: "running", pending: { n: 1, user: "x", started, edit: true } }), becomeIdleAfter: 99 });
  assert.match(run.$("aib-activity").className, /busy/); assert.match(run.text("aib-activity-text"), /^Claude is working on your request \(editing is enabled for this message\) · 00:1\d…$/);
  assert.strictEqual(run.$("aib-conv-messages").attrs["aria-busy"], "true"); assert.strictEqual(run.$("aib-conv-input").disabled, false); run.$("aib-close").onclick();
  const err = await panelChat({ conv: convView({ messages: [turn(1, { status: "error", error: "Claude Code timed out after 900s" })] }) });
  assert.match(err.$("aib-activity").className, /error/); assert.match(err.text("aib-activity-text"), /timed out after 900s/);
  let release; const gate = new Promise(r => { release = r; });
  const val = await panelChat({ conv: convView({ workspace: WS(), can_edit: true }) }, { routes: { [`GET ${U}/review`]: async () => { await gate; return { status: 200, body: REVIEW() }; } } });
  val.$("aib-changes-review").onclick(); await tick(5);
  assert.match(val.text("aib-activity-text"), /^Validating the changes/); assert.match(val.$("aib-activity").className, /busy/); release(); await tick(10); assert.match(val.text("aib-activity-text"), /^Ready/);
  const off = harness({ routes: { ...chatRoutes({ conv: convView() }), "GET /api/ai-builder/health": { status: 200, body: { available: false, state: "stopped" } } } }); off.store.set("aibConv", CID); await off.open(); await tick(10);
  assert.match(off.$("aib-activity").className, /offline/); assert.match(off.text("aib-activity-text"), /^Claude is not available right now/); assert.strictEqual(off.$("aib-conv-send").disabled, true);
});
test("publishing shows its own state while the request is in flight", async () => {
  let release; const gate = new Promise(r => { release = r; }); const state = { conv: convView({ workspace: WS(), can_edit: true }) };
  const h = await panelChat(state, { routes: { [`POST ${U}/publish`]: async () => { await gate; state.conv = { ...state.conv, workspace: WS({}, { can_undo: false }) }; return { status: 200, body: { published: "usecases/cnpg-standard", run: "r", conversation: state.conv } }; } } });
  await h.click("aib-changes-review"); h.$("aib-cr-confirm").checked = true; await h.$("aib-cr-confirm").onchange();
  h.$("aib-cr-publish").onclick(); await tick(5);
  assert.match(h.text("aib-activity-text"), /^Publishing to usecases\/cnpg-standard/); assert.strictEqual(h.text("aib-cr-publish"), "Publishing…"); assert.strictEqual(h.$("aib-cr-publish").disabled, true);
  release(); await tick(10); assert.match(h.text("aib-cr-result"), /^Published as usecases\/cnpg-standard/);
});
test("changes: the review and its file list collapse, feedback follows Undo, Reset and Start over", async () => {
  const state = { conv: convView({ workspace: WS(), can_edit: true }) }; const h = await panelChat(state);
  assert.deepStrictEqual([h.text("aib-changes-review"), h.$("aib-changes-review").attrs["aria-expanded"]], ["Review changes", "false"]);
  await h.click("aib-changes-review"); assert.deepStrictEqual([h.text("aib-changes-review"), h.$("aib-changes-review").attrs["aria-expanded"], h.$("aib-cr").hidden], ["Hide changes", "true", false]);
  assert.strictEqual(h.text("aib-cr-files-toggle"), "Files (2)"); assert.strictEqual(h.$("aib-cr-files-toggle").attrs["aria-expanded"], "true"); assert.strictEqual(h.$("aib-cr-files").hidden, false);
  await h.click("aib-cr-files-toggle"); assert.deepStrictEqual([h.$("aib-cr-files").hidden, h.$("aib-cr-files-toggle").attrs["aria-expanded"]], [true, "false"]);
  assert.strictEqual(h.$("aib-cr-diff").children.length > 0, true, "the diff stays while the list is folded"); assert.match(h.$("aib-cr-validation").className, /ok/);
  assert.strictEqual(h.fetches.filter(f => f.url === `${U}/review`).length, 1);
  await h.click("aib-changes-review"); assert.strictEqual(h.$("aib-cr").hidden, true); assert.strictEqual(h.fetches.filter(f => f.url === `${U}/review`).length, 1, "hiding needs no request");
  await h.click("aib-changes-undo"); assert.match(h.text("aib-cr-result"), /^Undone: the working copy is back/); assert.match(h.$("aib-cr-result").className, /ok/);
  const s2 = { conv: convView({ workspace: WS(), can_edit: true }) }; const r = await panelChat(s2);
  await r.click("aib-changes-reset"); assert.strictEqual(r.text("aib-cr-result"), ""); await r.click("aib-changes-reset"); assert.match(r.text("aib-cr-result"), /^Reset: the working copy is the original Lab/);
});
test("the review keeps the conversation visible and shows a highlighted diff and the validation state", async () => {
  const review = REVIEW({ diff: [{ path: "01_demo.sh", change: "modified", truncated: false, diff: "--- a/01_demo.sh\n+++ b/01_demo.sh\n@@ -1 +1 @@\n-echo old\n+kubectl get pods --all-namespaces # list\n" }] });
  const h = await panelChat({ conv: convView({ workspace: WS(), can_edit: true, messages: [turn(1)] }), review }); await h.click("aib-changes-review");
  assert.strictEqual(h.$("aib-conv").hidden, false); assert.ok(h.$("aib-conv-messages").children.length > 0, "the messages are still there");
  const rows = h.$("aib-cr-diff").children, add = rows[4];
  assert.match(add.className, /aib-dl add/); assert.strictEqual(add.children[0].textContent, "+"); assert.strictEqual(add.children[0].className, "mk");
  assert.deepStrictEqual(add.children.slice(1).filter(c => /^tk-/.test(c.className)).map(c => `${c.className}:${c.textContent}`), ["tk-flag:--all-namespaces", "tk-com:# list"]);
  assert.strictEqual(textOf(rows[4]).replace(/\n$/, ""), "+kubectl get pods --all-namespaces # list"); assert.match(rows[0].className, /meta/); assert.match(rows[2].className, /hunk/);
  const bad = await panelChat({ conv: convView({ workspace: WS(), can_edit: true }), review: REVIEW({ can_publish: false, validation: { passed: false, errors: ["x"] } }) }); await bad.click("aib-changes-review");
  assert.match(bad.$("aib-cr-validation").className, /bad/); assert.match(bad.text("aib-cr-validation"), /^✕ Validation failed/);
});
test("the stylesheets and script of the redesign keep the project rules", () => {
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function/.test(MD_SRC), "ai-markdown.js builds DOM nodes only");
  assert.ok(!/fetch\(|XMLHttpRequest|localStorage|\.href\s*=\s*[^n]/.test(MD_SRC.replace(/el\.href = n\.href;/, "")), "the renderer has no network, no storage");
  const names = [...MD_SRC.matchAll(/^(?:const|let|function)\s+([A-Za-z_]+)/gm)].map(m => m[1]); for (const n of names) assert.ok(n.startsWith("AIB") || n.startsWith("aib"), `top-level name ${n}`);
  assert.match(HTML, /src="ai-markdown\.js"/);
  for (const prop of ["--code-bg", "--tk-str", "--tk-kw"]) assert.ok(CSS.includes(prop), prop);
  assert.match(CSS, /:root\[data-theme="dark"\] main #aib \{ --code-bg/, "the dark theme has its own code and diff colors");
  assert.match(CSS, /#aib :focus-visible \{ outline: 2px solid var\(--accent\)/); assert.match(CSS, /\.aib-sr \{/);
});

// ---------------------------------------------------------------------------------------------------------------------
// 6. Deleting a conversation
// ---------------------------------------------------------------------------------------------------------------------
function deleteRoutes(state, reply) {
  const r = chatRoutes(state);
  r["GET /api/ai-builder/conversations"] = () => ({ status: 200, body: { conversations: state.conv ? [summary(state.conv)] : [] } });
  r[`DELETE ${U}`] = () => { state.deletes = (state.deletes || 0) + 1; if (reply) return reply; state.conv = null; return { status: 200, body: { deleted: CID, workspace_removed: true, sessions_removed: 2, warnings: [] } }; };
  return r;
}
const delChat = async (state, reply, over = {}) => { const h = harness({ routes: { ...deleteRoutes(state, reply), ...over } }); h.store.set("aibConv", CID); await h.open(); await tick(10); return h; };

const reopen = async h => { if (h.$("aib-hist").hidden) await h.click("aib-hist-toggle"); await h.$("aib-hist-list").children[0].children[0].onclick(); await tick(10); };
const findBtn = (node, text) => { if (node.tag === "button" && textOf(node) === text) return node; for (const c of node.children) { const r = findBtn(c, text); if (r) return r; } return null; };
const OLD = "c-20200101-000000-aaaaaa";
test("history: closed by default, newest first, titles only, the active one highlighted, searchable, archived hidden until asked", async () => {
  const state = { conv: convView({ messages: [turn(1)] }), others: [{ ...summary(convView({ title: "ClickHouse notes" })), id: OLD }, { ...summary(convView({ title: "Old archived" })), id: "c-20190101-000000-bbbbbb", archived: true }] };
  const h = await panelChat(state);
  assert.strictEqual(h.$("aib-hist").hidden, true); assert.strictEqual(h.$("aib-hist-toggle").attrs["aria-expanded"], "false");
  await h.click("aib-hist-toggle");
  assert.strictEqual(h.$("aib-hist").hidden, false); assert.strictEqual(h.$("aib-hist-toggle").attrs["aria-expanded"], "true");
  const rows = h.$("aib-hist-list").children;
  assert.deepStrictEqual(rows.map(li => li.children[0].textContent), ["What does scenario 01 do?", "ClickHouse notes"], "list order is kept (newest activity first); the archived one is hidden");
  assert.ok(rows[0].className.includes("active") && !rows[1].className.includes("active")); assert.ok(!/\$|msg|token/i.test(rows.map(textOf).join("")), "no usage or cost in the list");
  h.$("aib-hist-search").value = "click"; await h.$("aib-hist-search").oninput();
  assert.deepStrictEqual(h.$("aib-hist-list").children.map(li => li.children[0].textContent), ["ClickHouse notes"]);
  h.$("aib-hist-search").value = "zzz"; await h.$("aib-hist-search").oninput(); assert.match(textOf(h.$("aib-hist-list")), /No conversation matches/);
  h.$("aib-hist-search").value = ""; await h.$("aib-hist-search").oninput(); h.$("aib-hist-archived").checked = true; await h.$("aib-hist-archived").onchange();
  assert.strictEqual(h.$("aib-hist-list").children.length, 3, "archived conversations are recoverable from the list");
});
test("history: rename keeps the id; archive is one request; nothing else changes", async () => {
  const state = { conv: convView({ messages: [turn(1)] }) }; const h = await panelChat(state);
  await h.click("aib-hist-toggle"); await findBtn(h.$("aib-hist-list").children[0], "…").onclick(); await findBtn(h.$("aib-hist-pop"), "Rename").onclick();
  const inp = h.$("aib-hist-list").children[0].children[0]; inp.value = "  Better title "; await inp.onkeydown({ key: "Enter", preventDefault() {} }); await tick(10);
  const p = h.posts().at(-1); assert.deepStrictEqual([p.url, p.body, p.headers["X-Requested-With"]], [`/api/ai-builder/conversations/${CID}/meta`, { title: "Better title" }, "playground"]);
  assert.strictEqual(h.text("aib-conv-title"), "Better title"); assert.strictEqual(h.$("aib-hist-list").children[0].children[0].textContent, "Better title");
  await findBtn(h.$("aib-hist-list").children[0], "…").onclick(); await findBtn(h.$("aib-hist-pop"), "Archive").onclick(); await tick(10);
  assert.deepStrictEqual(h.posts().at(-1).body, { archived: true }); assert.match(textOf(h.$("aib-hist-list")), /No conversations yet/, "archived: gone from the default list");
});
test("history: delete asks first, warns about unpublished changes, never touches Labs, and Cancel sends nothing", async () => {
  const ws = { lab: "cnpg-standard", exists: true, editing: true, changes: { added: 1, modified: 1, deleted: 0, total: 2 }, can_undo: true, conflict: false, publications: 0 };
  const state = { conv: convView({ messages: [turn(1)], workspace: ws }) }; const h = await panelChat(state);
  await h.click("aib-hist-toggle"); await findBtn(h.$("aib-hist-list").children[0], "…").onclick(); await findBtn(h.$("aib-hist-pop"), "Delete…").onclick(); await tick(10);
  const box = textOf(h.$("aib-hist-list")); assert.match(box, /permanently/); assert.match(box, /Published Labs are never deleted/); assert.match(box, /2 unpublished changes in its working copy will be lost/);
  assert.strictEqual(h.fetches.filter(f => f.method === "DELETE").length, 0, "asking deletes nothing");
  await findBtn(h.$("aib-hist-list").children[0], "Cancel").onclick(); assert.ok(!/permanently/.test(textOf(h.$("aib-hist-list"))));
  await findBtn(h.$("aib-hist-list").children[0], "…").onclick(); await findBtn(h.$("aib-hist-pop"), "Delete…").onclick(); await tick(10);
  await findBtn(h.$("aib-hist-list").children[0], "Delete").onclick(); await tick(20);
  const d = h.fetches.filter(f => f.method === "DELETE"); assert.strictEqual(d.length, 1); assert.strictEqual(d[0].headers["X-Requested-With"], "playground"); assert.strictEqual(d[0].url, `/api/ai-builder/conversations/${CID}`);
  assert.strictEqual(h.$("aib-conv").hidden, true, "the active conversation is gone: the empty state"); assert.strictEqual(h.store.get("aibConv"), undefined);
});
test("inline approval: a card under the proposal, Cancel sends nothing, Allow changes enables editing then asks Claude to apply; no internal directive is shown", async () => {
  const state = { conv: convView({ messages: [turn(1, { assistant: "I would rename the title.\n[[context: edit]]", edit_request: true })], can_edit: true, edit_approved: false }) };
  const h = await panelChat(state);
  const card = () => h.$("aib-conv-messages").children.find(c => c.className === "aib-approval");
  assert.ok(card(), "the card is shown"); assert.ok(!/\[\[/.test(bubbles(h).map(b => b.text).join("")), "the directive is never displayed");
  assert.match(textOf(card()), /cnpg-standard/); assert.strictEqual(h.posts().length, 0);
  await findBtn(card(), "Cancel").onclick(); await tick(10); assert.ok(!card(), "dismissed"); assert.deepStrictEqual(h.posts().map(p => p.body), [{ action: "decline_edit" }], "Cancel only tells the server to forget the request");
  state.conv = { ...state.conv, messages: [turn(1, { edit_request: true }), turn(2, { assistant: "Another proposal.", edit_request: true })] }; await reopen(h);
  await findBtn(card(), "Allow changes").onclick(); await tick(30);
  const ps = h.posts().slice(1); assert.deepStrictEqual(ps[0].body, { action: "allow_edit" }); assert.strictEqual(ps[0].url, `/api/ai-builder/conversations/${CID}/context`);
  assert.match(ps[1].body.message, /Changes allowed/); assert.ok(!card(), "no card once editing is allowed (no approval loop)");
  const free = await panelChat({ conv: convView({ messages: [turn(1, { edit_request: true })], edit_approved: true }) }); assert.ok(!free.$("aib-conv-messages").children.some(c => c.className === "aib-approval"));
});
const inEl = (target, ids) => ({ target: { closest: sel => (ids.includes(sel) ? {} : null) } });
test("history: outside click and Escape close it, one layer at a time; choosing a conversation closes it; the toggle and inside clicks keep it", async () => {
  const state = { conv: convView({ messages: [turn(1)] }) }; const h = await panelChat(state);
  const click = e => h.docListeners.click.forEach(f => f(e)), key = k => h.docListeners.keydown.forEach(f => f({ key: k }));
  await h.click("aib-hist-toggle"); assert.strictEqual(h.$("aib-hist").hidden, false);
  click(inEl("search", ["#aib-hist"])); assert.strictEqual(h.$("aib-hist").hidden, false, "a click inside (search) keeps it open");
  click(inEl("toggle", ["#aib-hist-toggle"])); assert.strictEqual(h.$("aib-hist").hidden, false, "the toggle has its own handler");
  await findBtn(h.$("aib-hist-list").children[0], "…").onclick(); assert.ok(findBtn(h.$("aib-hist-pop"), "Rename"));
  click(inEl("menu", ["#aib-hist", ".aib-hist-menu"])); assert.ok(findBtn(h.$("aib-hist-pop"), "Rename"), "a click in the menu keeps the menu");
  click(inEl("elsewhere in the list", ["#aib-hist"])); assert.ok(!findBtn(h.$("aib-hist-pop"), "Rename"), "a click elsewhere in the panel closes only the menu"); assert.strictEqual(h.$("aib-hist").hidden, false);
  await findBtn(h.$("aib-hist-list").children[0], "…").onclick(); key("Escape"); assert.ok(!findBtn(h.$("aib-hist-pop"), "Rename")); assert.strictEqual(h.$("aib-hist").hidden, false, "Escape closes the menu first");
  key("Escape"); assert.strictEqual(h.$("aib-hist").hidden, true, "then the panel"); assert.strictEqual(h.$("aib-hist-toggle").attrs["aria-expanded"], "false");
  await h.click("aib-hist-toggle"); click({ target: { closest: () => null } }); assert.strictEqual(h.$("aib-hist").hidden, true, "a click outside closes it");
  await h.click("aib-hist-toggle"); await h.$("aib-hist-list").children[0].children[0].onclick(); await tick(10); assert.strictEqual(h.$("aib-hist").hidden, true, "choosing a conversation closes it");
});
test("history: the rename editor saves on Enter, cancels on Escape and shows a discreet error when saving fails", async () => {
  const state = { conv: convView({ messages: [turn(1)] }) }; const h = await panelChat(state); const key = k => h.docListeners.keydown.forEach(f => f({ key: k }));
  await h.click("aib-hist-toggle"); const row = () => h.$("aib-hist-list").children[0];
  const startRename = async () => { await findBtn(row(), "…").onclick(); await findBtn(h.$("aib-hist-pop"), "Rename").onclick(); };
  await startRename(); key("Escape"); assert.strictEqual(row().children[0].tag, "button", "Escape cancels the editor"); assert.strictEqual(h.$("aib-hist").hidden, false, "and keeps the panel");
  await startRename(); const inp = row().children[0]; inp.value = "New name";
  state.failNext = true; await inp.onkeydown({ key: "Enter", preventDefault() {} }); await tick(10);
  assert.match(textOf(row()), /Not renamed/); assert.strictEqual(row().children[0].tag, "input", "still in the editor: Enter retries");
  assert.strictEqual(h.text("aib-conv-title"), "What does scenario 01 do?", "the title is unchanged after a failure");
});
test("Lab creation: a Create Lab card from the conversation, Cancel forgets it, Create Lab asks the backend then Claude; no directive is shown", async () => {
  const state = { conv: convView({ lab: null, can_edit: false, messages: [turn(1, { assistant: "Plan: operator and two scenarios.\n[[context: create clickhouse-demo]]", create_request: "clickhouse-demo" })] }) };
  const h = await panelChat(state); const card = () => h.$("aib-conv-messages").children.find(c => c.className === "aib-approval");
  assert.ok(card()); assert.match(textOf(card()), /Create the new Lab 'clickhouse-demo'/); assert.ok(findBtn(card(), "Create Lab") && !findBtn(card(), "Allow changes")); assert.ok(!/\[\[/.test(bubbles(h).map(b => b.text).join("")));
  assert.strictEqual(h.posts().length, 0, "nothing is created by displaying the card");
  await findBtn(card(), "Cancel").onclick(); await tick(10); assert.ok(!card()); assert.deepStrictEqual(h.posts().map(p => p.body), [{ action: "decline_edit" }]);
  state.conv = convView({ lab: null, messages: [turn(1), turn(2, { create_request: "clickhouse-demo" })] }); await reopen(h);
  await findBtn(card(), "Create Lab").onclick(); await tick(30);
  const ps = h.posts().slice(1); assert.deepStrictEqual(ps[0].body, { action: "create_lab", lab: "clickhouse-demo" }); assert.match(ps[1].body.message, /Lab creation approved: create the Lab 'clickhouse-demo'/);
  assert.ok(!card(), "no card once the creation is approved");
});
test("several Labs: one card lists them all, the bar shows one Lab at a time, and review, undo, reset and publish go to that Lab's route", async () => {
  const wsA = WS({ modified: 1 }, { lab: "cnpg-standard" }), wsB = WS({ modified: 2, added: 1 }, { lab: "pg4k-tde" }), posts = [];
  const state = { conv: convView({ workspace: wsA, workspaces: [wsA, wsB], can_edit: true, messages: [turn(1), turn(2, { assistant: "Plan for both.\n[[context: edit cnpg-standard]]", edit_request: true, edit_labs: ["cnpg-standard", "pg4k-tde"] })] }) };
  const routes = editRoutes(state); const lab = `POST ${U}/lab`;
  routes[lab] = opts => { const b = JSON.parse(opts.body); posts.push(b);
    if (b.action === "review") return { status: 200, body: REVIEW({ lab: b.lab, tree_hash: (b.lab === "pg4k-tde" ? "b" : "a").repeat(64) }) };
    if (b.action === "publish") return { status: 200, body: { published: `usecases/${b.lab}`, run: "x", conversation: state.conv } };
    return { status: 200, body: state.conv }; };
  const h = harness({ routes }); h.store.set("aibConv", CID); await h.open(); await tick(10);
  const card = () => h.$("aib-conv-messages").children.find(c => c.className === "aib-approval");
  assert.match(textOf(card()), /cnpg-standard, pg4k-tde/); await findBtn(card(), "Allow changes").onclick(); await tick(30);
  const ctx = h.posts().find(p => p.url.endsWith("/context")); assert.deepStrictEqual(ctx.body, { action: "allow_edit", labs: ["cnpg-standard", "pg4k-tde"] }, "the approval names every Lab");
  const sel = h.$("aib-changes-lab"); assert.strictEqual(sel.hidden, false); assert.deepStrictEqual(sel.children.map(o => o.value), ["cnpg-standard", "pg4k-tde"]); assert.strictEqual(sel.children[1].textContent, "pg4k-tde (3)");
  sel.value = "pg4k-tde"; await sel.onchange(); assert.match(h.text("aib-changes-text"), /3/);
  await h.click("aib-changes-review"); await tick(10); assert.deepStrictEqual(posts[0], { lab: "pg4k-tde", action: "review" });
  h.$("aib-cr-confirm").checked = true; await h.$("aib-cr-confirm").onchange(); await h.click("aib-cr-publish"); await tick(10);
  const pub = posts.find(b => b.action === "publish"); assert.deepStrictEqual([pub.lab, pub.approve, pub.tree_hash], ["pg4k-tde", true, "b".repeat(64)]);
  await h.click("aib-changes-undo"); await tick(10); assert.strictEqual(posts.at(-1).action, "undo"); assert.strictEqual(posts.at(-1).lab, "pg4k-tde");
  assert.strictEqual(h.fetches.filter(f => f.url === `${U}/review` || f.url === `${U}/publish`).length, 0, "the single-Lab routes are not used with several Labs");
  const one = await editChat(withWs(WS())); assert.strictEqual(one.$("aib-changes-lab").hidden, true, "one Lab: no selector, the usual controls");
});
test("usage under a reply: compact by default, every figure behind a Details disclosure", async () => {
  assert.strictEqual(core.turnSummary({ model: "sonnet", seconds: 15.7, cost_usd: 0.0528 }), "Sonnet · 15.7s · est. $0.053");
  assert.strictEqual(core.turnSummary({ model: "sonnet", seconds: 900, cost_usd: null }), "Sonnet · 900s"); assert.strictEqual(core.turnSummary({}), "");
  assert.strictEqual(core.turnSummary({ model: "opus", seconds: 2, cost_usd: 1.234 }), "Opus · 2s · est. $1.23");
  assert.deepStrictEqual(core.turnDetails(turn(1)).map(r => r[0]), ["Model", "Input tokens", "Output tokens", "Cache read tokens", "Cache creation tokens", "Estimated cost", "Duration"]);
  assert.deepStrictEqual(core.turnDetails({}).map(r => r[1]), ["n/a", "n/a", "n/a", "n/a", "n/a", "n/a", "n/a"]);
  const h = await panelChat({ conv: convView({ messages: [turn(1, { seconds: 15.7, cost_usd: 0.0528, usage: { ...USAGE, input_tokens: 8, output_tokens: 2641, cache_read_input_tokens: 66571, cache_creation_input_tokens: 4920 } })] }) });
  const msg = h.$("aib-conv-messages").children[1], meta = msg.children[msg.children.length - 1], [line, tog, dl] = meta.children;
  assert.strictEqual(line.textContent, "Sonnet · 15.7s · est. $0.053"); assert.deepStrictEqual([tog.textContent, tog.attrs["aria-expanded"], dl.hidden], ["Details", "false", true]);
  assert.match(tog.title, /^sonnet · in 8 · out 2,641 · cache read 66,571 · cache write 4,920/, "the full line stays as a tooltip");
  tog.onclick(); assert.deepStrictEqual([tog.attrs["aria-expanded"], dl.hidden], ["true", false]); assert.deepStrictEqual(dl.children.map(r => textOf(r)), ["Modelsonnet", "Input tokens8", "Output tokens2,641", "Cache read tokens66,571", "Cache creation tokens4,920", "Estimated cost$0.0528", "Duration15.7 s"]);
  tog.onclick(); assert.strictEqual(dl.hidden, true);
});
test("a message that changed files gets a compact card from the backend's list, with no diff and no guessed kinds", async () => {
  const files = ["08_version_and_primary.sh", "07_postgresql_upgrades.sh", "README.md"];
  const state = { conv: convView({ workspace: WS(), can_edit: true, messages: [turn(1, { edit: true, changed: files }), turn(2, { edit: false, changed: ["x.sh"] }), turn(3, { edit: true, changed: [] })] }) };
  const h = await panelChat(state);
  const cards = []; walk(h.$("aib-conv-messages"), e => { if (e.className === "aib-changecard") cards.push(e); });
  assert.strictEqual(cards.length, 1, "only the message that edited files, and only when files are listed");
  const card = cards[0]; assert.match(textOf(card), /^3 files changedReview changes08_version_and_primary\.sh07_postgresql_upgrades\.shREADME\.mdTouched by this message/);
  assert.doesNotMatch(textOf(card), /^.*[+~−] \w/, "no added/modified/deleted marker is invented for a message"); assert.ok(!tags(card).includes("pre"), "no diff in the conversation");
  await card.children[0].children[1].onclick(); await tick(10); assert.strictEqual(h.fetches.filter(f => f.url === `${U}/review`).length, 1, "the button opens the existing review");
  const many = await panelChat({ conv: convView({ messages: [turn(1, { edit: true, changed: Array.from({ length: 9 }, (_, i) => `f${i}.sh`) })] }) });
  const c2 = []; walk(many.$("aib-conv-messages"), e => { if (e.className === "aib-changecard") c2.push(e); }); assert.match(textOf(c2[0]), /^9 files changed/); assert.match(textOf(c2[0]), /\+ 3 more/); assert.ok(!/f6\.sh/.test(textOf(c2[0])));
  const gone = await panelChat({ conv: convView({ workspace: WS({}, { can_undo: false }), messages: [turn(1, { edit: true, changed: ["a.sh"] })] }) });
  let btn = null; walk(gone.$("aib-conv-messages"), e => { if (e.className === "aib-changecard") btn = e.children[0].children[1]; }); await btn.onclick();
  assert.match(gone.text("aib-cr-result"), /no longer pending/); assert.strictEqual(gone.fetches.filter(f => f.url === `${U}/review`).length, 0);
});
test("a message card reviews the Labs it touched even when the Lab in focus has no changes; resolved Labs say so", async () => {
  const none = WS({}, { lab: "clickhouse-operator", can_undo: false }), a = WS({ modified: 1 }, { lab: "cnpg-standard" }), b = WS({ modified: 1 }, { lab: "pgd4k-single-group" });
  const files = ["cnpg-standard/README.md", "pgd4k-single-group/README.md"], posts = [];
  const open = async (workspaces, msgFiles, lab = "clickhouse-operator", workspace = none) => {
    const state = { conv: convView({ lab, workspace, workspaces, can_edit: true, messages: [turn(1, { edit: true, changed: msgFiles })] }) };
    const routes = editRoutes(state); routes[`POST ${U}/lab`] = opts => { const x = JSON.parse(opts.body); posts.push(x); return { status: 200, body: REVIEW({ lab: x.lab }) }; };
    const h = harness({ routes }); h.store.set("aibConv", CID); await h.open(); await tick(10);
    let btn = null; walk(h.$("aib-conv-messages"), e => { if (e.className === "aib-changecard") btn = e.children[0].children[1]; }); return { h, btn }; };
  let { h, btn } = await open([none, a, b], files); await btn.onclick(); await tick(10);
  assert.deepStrictEqual(posts, [{ lab: "cnpg-standard", action: "review" }], "the first touched Lab with changes is reviewed, through the per-Lab route"); assert.doesNotMatch(h.text("aib-cr-result"), /no longer pending/);
  const sel = h.$("aib-changes-lab"); assert.deepStrictEqual(sel.children.map(o => o.value), ["clickhouse-operator", "cnpg-standard", "pgd4k-single-group"]); assert.strictEqual(sel.value, "cnpg-standard");
  sel.value = "pgd4k-single-group"; await sel.onchange(); await h.click("aib-changes-review"); await h.click("aib-changes-review"); await tick(10);
  assert.strictEqual(posts.at(-1).lab, "pgd4k-single-group", "the selector still moves between the Labs");
  ({ h, btn } = await open([none, WS({}, { lab: "cnpg-standard", can_undo: false }), b], files)); posts.length = 0; await btn.onclick(); await tick(10);
  assert.deepStrictEqual(posts, [{ lab: "pgd4k-single-group", action: "review" }], "a Lab already reset is skipped");
  ({ h, btn } = await open([none, WS({}, { lab: "cnpg-standard", can_undo: false }), WS({}, { lab: "pgd4k-single-group", can_undo: false })], files)); posts.length = 0; await btn.onclick(); await tick(10);
  assert.match(h.text("aib-cr-result"), /no longer pending/); assert.strictEqual(posts.length, 0);
  ({ h, btn } = await open([a, b], ["README.md"], "cnpg-standard", a)); posts.length = 0; await btn.onclick(); await tick(10);
  assert.deepStrictEqual(posts, [{ lab: "cnpg-standard", action: "review" }], "an unprefixed path belongs to the Lab in focus");
});
test("publishing a Lab with removed files warns that a running environment is not changed", async () => {
  const conv = convView({ workspace: WS(), can_edit: true });
  const state = { conv, publishReply: { status: 200, body: { lab: "cnpg-standard", published: "usecases/cnpg-standard", changes: { added: 0, modified: 0, deleted: 2 }, run: "./playground usecase start cnpg-standard", conversation: conv } } };
  const h = await editChat(state); await h.click("aib-changes-review"); h.$("aib-cr-confirm").checked = true; await h.$("aib-cr-confirm").onchange(); await h.click("aib-cr-publish"); await tick(20);
  assert.match(h.text("aib-cr-result"), /already running is not changed/);
});
const DEL = (state = null, extra = {}) => ({ lab: "demo-lab", title: "Demo Lab", files: 14, state, ...extra });
function deleteHarness(state, verdicts) {
  const routes = editRoutes(state), calls = [];
  routes[`POST ${U}/delete_check`] = opts => { calls.push(["check", JSON.parse(opts.body)]); return { status: 200, body: verdicts.check(state) }; };
  routes[`POST ${U}/delete_lab`] = opts => { const b = JSON.parse(opts.body); calls.push(["delete", b]); return verdicts.del(state, b); };
  return { h: harness({ routes }), calls };
}
const deleteCardOf = h => h.$("aib-conv-messages").children.find(c => c.className === "aib-approval aib-delete");
test("a deletion request is checked once by the server and, when the Lab is stopped, shows its own confirmation card that needs the exact name", async () => {
  const state = { conv: convView({ messages: [turn(1, { delete_request: "demo-lab" })], delete_request: DEL(null) }) };
  const { h, calls } = deleteHarness(state, { check: st => { st.conv = { ...st.conv, delete_request: DEL("ready") }; return st.conv; }, del: () => ({ status: 500, body: { error: "no" } }) });
  h.store.set("aibConv", CID); await h.open(); await tick(20);
  assert.deepStrictEqual(calls, [["check", { lab: "demo-lab" }]], "asked once, naming only the Lab: the verdict is the server's");
  const card = deleteCardOf(h); assert.ok(card, "the dedicated card is shown"); const text = textOf(card);
  assert.match(text, /Delete the Lab demo-lab \(Demo Lab\)\?/); assert.match(text, /14 files/); assert.match(text, /usecases\/\.trash\//); assert.match(text, /Other conversations/);
  const input = card.children.find(c => c.tag === "label").children.find(c => c.tag === "input"), yes = findBtn(card, "Delete Lab");
  assert.strictEqual(yes.disabled, true); input.value = "Demo-Lab"; await input.oninput(); assert.strictEqual(yes.disabled, true, "case matters");
  input.value = "demo-lab "; await input.oninput(); assert.strictEqual(yes.disabled, true); input.value = "demo"; await input.oninput(); assert.strictEqual(yes.disabled, true);
  await yes.onclick(); await tick(5); assert.strictEqual(calls.filter(c => c[0] === "delete").length, 0, "a disabled button sends nothing");
  assert.ok(!h.posts().some(p => p.body && p.body.action === "allow_edit"), "editing approval is a different thing");
});
test("a running Lab shows no confirmation: the explanation is part of the conversation and the request is kept", async () => {
  const text = "I would delete it.\n\nThe Lab demo-lab is currently running.\n\nYou must stop its infrastructure from the Playground before deleting it.\n\nOnce stopped, tell me and we can continue.";
  const state = { conv: convView({ messages: [turn(1, { delete_request: "demo-lab" })], delete_request: DEL(null) }) };
  const { h, calls } = deleteHarness(state, { check: st => { st.conv = { ...st.conv, messages: [turn(1, { assistant: text, delete_request: "demo-lab" })], delete_request: DEL("blocked") }; return st.conv; }, del: () => ({ status: 500, body: {} }) });
  h.store.set("aibConv", CID); await h.open(); await tick(20);
  assert.ok(!deleteCardOf(h)); assert.match(bubbles(h).map(b => b.text).join(" "), /currently running[\s\S]*Once stopped, tell me and we can continue/); assert.strictEqual(calls.length, 1);
  h.$("aib-conv-input").value = "it is stopped"; await tick(5); assert.strictEqual(calls.filter(c => c[0] === "delete").length, 0);
});
test("confirming deletes through the dedicated route, refreshes the Labs and clears the card; a refusal keeps the card and says why", async () => {
  const state = { conv: convView({ messages: [turn(1, { delete_request: "demo-lab" })], delete_request: DEL("ready") }) };
  let refuse = true;
  const { h, calls } = deleteHarness(state, { check: st => st.conv, del: (st, b) => refuse ? { status: 409, body: { error: "the infrastructure of this Lab is not confirmed stopped: nothing was deleted" } }
    : (st.conv = { ...st.conv, lab: null, labs: [], delete_request: null, can_edit: false, read_only: true }, { status: 200, body: { lab: b.lab, trash: "usecases/.trash/demo-lab-20261118T100000Z-ab12cd34", conversation: st.conv } }) });
  h.store.set("aibConv", CID); await h.open(); await tick(20);
  let card = deleteCardOf(h); const input = card.children.find(c => c.tag === "label").children.find(c => c.tag === "input"), yes = findBtn(card, "Delete Lab");
  input.value = "demo-lab"; await input.oninput(); assert.strictEqual(yes.disabled, false); await yes.onclick(); await tick(20);
  assert.deepStrictEqual(calls.filter(c => c[0] === "delete"), [["delete", { lab: "demo-lab", confirm: "demo-lab" }]]); assert.match(h.text("aib-conv-error"), /not confirmed stopped/); assert.ok(deleteCardOf(h), "the card stays");
  assert.strictEqual(h.counters.refreshUseCases || 0, 0);
  refuse = false; card = deleteCardOf(h); const i2 = card.children.find(c => c.tag === "label").children.find(c => c.tag === "input"); i2.value = "demo-lab"; await i2.oninput(); await findBtn(card, "Delete Lab").onclick(); await tick(30);
  assert.ok(!deleteCardOf(h)); assert.strictEqual(h.counters.refreshUseCases, 1, "the Lab list is refreshed"); assert.match(h.text("aib-cr-result"), /The Lab demo-lab was removed from the Playground\. Its files are kept in usecases\/\.trash\/demo-lab-/);
});
test("Cancel forgets a deletion request and sends nothing else", async () => {
  const state = { conv: convView({ messages: [turn(1, { delete_request: "demo-lab" })], delete_request: DEL("ready") }) };
  const { h, calls } = deleteHarness(state, { check: st => st.conv, del: () => ({ status: 500, body: {} }) });
  const routes = h; h.store.set("aibConv", CID); await h.open(); await tick(20);
  const before = h.posts().length; state.conv = { ...state.conv, delete_request: null }; await findBtn(deleteCardOf(h), "Cancel").onclick(); await tick(20);
  const ps = h.posts().slice(before); assert.deepStrictEqual(ps.map(p => p.body), [{ action: "decline_delete" }]); assert.ok(!deleteCardOf(h)); assert.strictEqual(calls.filter(c => c[0] === "delete").length, 0);
});
test("the review marks added, modified and deleted files; the header is one compact row with a tooltip on the list", async () => {
  const h = await panelChat({ conv: convView({ workspace: WS(), can_edit: true }), review: REVIEW({ diff: [{ path: "a.sh", change: "added", diff: "", truncated: false }, { path: "b.sh", change: "modified", diff: "", truncated: false }, { path: "c.sh", change: "deleted", diff: "", truncated: false }] }) });
  await h.click("aib-changes-review");
  assert.deepStrictEqual(h.$("aib-cr-files").children.map(li => /chg-\w+/.exec(li.children[0].className)[0]), ["chg-added", "chg-modified", "chg-deleted"]);
  assert.ok(/class="aib-conv-head">\s*<span id="aib-conv-state"[\s\S]*id="aib-conv-meta"[\s\S]*id="aib-budget"/.test(HTML), "state, metadata and budget share one row");
});
test("composer: you can type while Claude works, a spinner shows, and the focus returns when the reply is done", async () => {
  const state = { conv: convView({ status: "running", pending: { n: 1, user: "slow", started: new Date().toISOString() } }), becomeIdleAfter: 9999 };
  state.finish = () => { state.conv = { ...state.conv, status: "idle", pending: null, messages: [turn(1, { user: "slow", assistant: "done" })] }; state.finish = null; };
  const h = harness({ routes: chatRoutes(state) }); h.store.set("aibConv", CID); await h.click("aib-open");
  assert.deepStrictEqual([h.$("aib-conv-input").disabled, h.$("aib-send-spinner").hidden, h.$("aib-conv-send").disabled], [false, false, true]);
  const before = h.$("aib-conv-input").focused; state.becomeIdleAfter = 1; await tick(40);       // now the reply completes
  assert.deepStrictEqual([h.$("aib-send-spinner").hidden, h.text("aib-conv-send")], [true, "Send"]); assert.ok(h.$("aib-conv-input").focused > before, "the composer has the focus again");
  const key = h.$("aib-conv-input"); key.value = "next question"; key.oninput(); assert.strictEqual(h.$("aib-conv-send").disabled, false);
  assert.match(CSS, /\.aib-composer-box \{[^}]*border-radius: 12px/); assert.match(CSS, /\.aib-spinner \{[^}]*animation: aib-spin/);
});

(async () => {
  for (const { name, fn } of queue) {
    try { await fn(); console.log("PASS " + name); } catch (e) { failures++; console.log(`FAIL ${name}   [${(e && e.message || e).toString().split("\n").slice(0, process.env.AIB_DEBUG ? 8 : 1).join(" | ")}]${process.env.AIB_DEBUG ? " @ " + ((e.stack || "").split("\n").find(l => l.includes("ai_builder_ui_test.js")) || "").trim() : ""}`); }
  }
  console.log(failures ? "SOME UI TESTS FAILED" : "ALL UI TESTS PASSED");
  process.exit(failures ? 1 : 0);
})();
