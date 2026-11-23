// UI tests for the host resource cards (web/static/resource-cards.js) and their wiring in app.js / index.html / style.css.
// No browser, no network, no Docker: the script runs against a tiny fake DOM. Not covered (manual check): real rendering, layout, themes.
// Run: tests/ui.sh
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");
const ROOT = path.resolve(__dirname, "..");
const read = f => fs.readFileSync(path.join(ROOT, f), "utf8");
const RC = require(path.join(ROOT, "web/static/resource-cards.js"));
const APP = read("web/static/app.js"), HTML = read("web/static/index.html"), CSS = read("web/static/style.css");

class El {
  constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this.className = ""; this.style = {}; this.attrs = {}; this._text = ""; }
  set textContent(t) { this._text = String(t); this.children = []; }
  get textContent() { return this._text + this.children.map(c => c.textContent).join(""); }
  setAttribute(k, v) { this.attrs[k] = v; }
  append(...n) { for (const x of n) this.children.push(typeof x === "string" ? Object.assign(new El("#text"), { _text: x }) : x); }
  appendChild(n) { this.children.push(n); return n; }
  removeChild(n) { this.children = this.children.filter(c => c !== n); }
  replaceChildren(...n) { this.children = []; this.append(...n); }
  select() {}
}
const doc = { createElement: t => new El(t), body: new El("body"), execCommand: () => true };
const all = (n, f, out = []) => { if (f(n)) out.push(n); n.children.forEach(c => all(c, f, out)); return out; };
const byClass = (n, c) => all(n, e => (" " + e.className + " ").includes(" " + c + " "));
const text = n => n.textContent;

const INOTIFY = { id: "inotify", status: "WARNING", title: "Linux inotify limits", current: "max_user_instances = 128 / max_user_watches   = 65536",
  current_lines: ["max_user_instances = 128", "max_user_watches   = 65536"], recommended: "max_user_instances = 1024 / max_user_watches   = 131072", recommended_lines: ["max_user_instances = 1024", "max_user_watches   = 131072"],
  impact: "Low inotify limits may affect Kubernetes workloads under heavy activity.",
  fix: [{ text: "Run these on the Linux host itself, not inside the Playground container.", command: false },
        { text: "sudo sysctl -w fs.inotify.max_user_instances=1024", command: true }, { text: "sudo sysctl -w fs.inotify.max_user_watches=131072", command: true }],
  restore: [{ text: "sudo sysctl -w fs.inotify.max_user_instances=128", command: true }, { text: "sudo sysctl -w fs.inotify.max_user_watches=65536", command: true }] };
const DISK = { id: "disk", status: "CRITICAL", title: "Host disk usage", current: "99% used, 3.3 GiB available of 100 GiB on /var/lib/docker", current_lines: ["99% used, 3.3 GiB available of 100 GiB on /var/lib/docker"],
  recommended: "less than 85% used", recommended_lines: ["less than 85% used"], impact: "Low disk space may cause Kubernetes DiskPressure and prevent Pods from starting.",
  fix: [{ text: "Free disk space before continuing.", command: false }, { text: "docker system df", command: true }, { text: "docker builder du", command: true },
        { text: "Pruning deletes unused images; review first.", command: false }], restore: [] };

let failures = 0;
const queue = [], test = (n, f) => queue.push({ n, f });

test("a card shows severity, resource, current value, impact, recommended action and commands", () => {
  const box = new El("div"); RC.render(doc, box, [DISK, INOTIFY], () => Promise.resolve());
  const cards = byClass(box, "rc-card"); assert.strictEqual(cards.length, 2);
  assert.match(cards[0].className, /rc-critical/); assert.match(cards[1].className, /rc-warning/);
  assert.deepStrictEqual(byClass(box, "rc-badge").map(text), ["CRITICAL", "WARNING"]);
  assert.deepStrictEqual(byClass(box, "rc-title").map(text), ["Host disk usage", "Linux inotify limits"]);
  const t = text(cards[0]);
  assert.match(t, /99% used, 3\.3 GiB available/); assert.match(t, /DiskPressure/); assert.match(t, /Recommended action/); assert.match(t, /Free disk space before continuing/);
  assert.match(text(cards[1]), /max_user_instances = 128/); assert.match(text(cards[1]), /max_user_watches   = 65536/);
  assert.match(text(cards[1]), /Recommended: max_user_instances = 1024 · max_user_watches   = 131072/);
});
test("commands are grouped in one copyable block each; explanations stay text", () => {
  const box = new El("div"); RC.render(doc, box, [DISK], () => Promise.resolve());
  const blocks = byClass(box, "rc-cmd"); assert.strictEqual(blocks.length, 1);
  assert.strictEqual(text(all(blocks[0], e => e.tagName === "PRE")[0]), "docker system df\ndocker builder du");
  assert.strictEqual(all(blocks[0], e => e.tagName === "BUTTON").length, 1);
  assert.ok(byClass(box, "rc-text").some(p => /Pruning deletes unused images/.test(text(p))));       // prose after the commands is not inside the block
});
test("inotify: correction block, restore block with the detected values, and the where-to-run explanation", () => {
  const box = new El("div"); RC.render(doc, box, [INOTIFY], () => Promise.resolve());
  const blocks = byClass(box, "rc-cmd").map(b => text(all(b, e => e.tagName === "PRE")[0]));
  assert.deepStrictEqual(blocks, ["sudo sysctl -w fs.inotify.max_user_instances=1024\nsudo sysctl -w fs.inotify.max_user_watches=131072",
                                  "sudo sysctl -w fs.inotify.max_user_instances=128\nsudo sysctl -w fs.inotify.max_user_watches=65536"]);
  assert.match(text(box), /not inside the Playground container/); assert.match(text(box), /To restore the previous values/);
});
test("no restore section when there is nothing to restore (disk)", () => {
  const box = new El("div"); RC.render(doc, box, [DISK], () => Promise.resolve());
  assert.doesNotMatch(text(box), /To restore/);
});
test("a macOS-style finding set has no Linux command", () => {
  const box = new El("div"); RC.render(doc, box, [DISK], () => Promise.resolve());
  assert.doesNotMatch(text(box), /sysctl|sudo /);
});
test("Copy sends exactly the block's commands and reports Copied, then returns to Copy", async () => {
  const box = new El("div"), sent = []; RC.render(doc, box, [INOTIFY], t => { sent.push(t); return Promise.resolve(); });
  const btn = all(byClass(box, "rc-cmd")[0], e => e.tagName === "BUTTON")[0];
  btn.onclick(); await new Promise(r => setImmediate(r));
  assert.deepStrictEqual(sent, ["sudo sysctl -w fs.inotify.max_user_instances=1024\nsudo sysctl -w fs.inotify.max_user_watches=131072"]);
  assert.strictEqual(btn.textContent, "Copied");
});
test("Copy failure is shown, not hidden", async () => {
  const box = new El("div"); RC.render(doc, box, [DISK], () => Promise.reject(new Error("no")));
  const btn = byClass(box, "rc-copy")[0]; btn.onclick(); await new Promise(r => setImmediate(r));
  assert.strictEqual(btn.textContent, "Copy failed");
});
test("copyText: the clipboard API when available, else the textarea fallback (http over a LAN address)", async () => {
  const written = []; await RC.copyText("abc", { navigator: { clipboard: { writeText: t => { written.push(t); return Promise.resolve(); } } } });
  assert.deepStrictEqual(written, ["abc"]);
  const d = { body: new El("body"), createElement: t => new El(t), execCommand: c => { assert.strictEqual(c, "copy"); d.copied = d.body.children[0].value; return true; } };
  await RC.copyText("xyz", { navigator: {}, document: d }); assert.strictEqual(d.copied, "xyz"); assert.strictEqual(d.body.children.length, 0);
  await assert.rejects(RC.copyText("q", { navigator: {}, document: Object.assign(d, { execCommand: () => false }) }));
});
test("untrusted text is never interpreted as HTML", () => {
  const box = new El("div"); RC.render(doc, box, [{ ...DISK, title: "<img src=x onerror=alert(1)>" }], () => Promise.resolve());
  assert.ok(byClass(box, "rc-title")[0].textContent.includes("<img")); assert.doesNotMatch(fs.readFileSync(path.join(ROOT, "web/static/resource-cards.js"), "utf8"), /innerHTML|insertAdjacentHTML/);
});

// --- compact cards and Show fix / Hide fix ---
test("by default a card is compact: severity, resource, current, recommended, one impact sentence and a Show fix button; the fix is hidden", () => {
  const box = new El("div"); RC.render(doc, box, [DISK, INOTIFY], () => Promise.resolve());
  const [d, i] = byClass(box, "rc-card");
  assert.strictEqual(text(byClass(d, "rc-sum")[0]), "Current: 99% used, 3.3 GiB available of 100 GiB on /var/lib/docker" + "Recommended: less than 85% used");
  assert.strictEqual(text(byClass(i, "rc-sum")[0]), "Current: max_user_instances = 128 · max_user_watches   = 65536" + "Recommended: max_user_instances = 1024 · max_user_watches   = 131072");
  assert.strictEqual(text(d.children[2]), "Low disk space may cause Kubernetes DiskPressure and prevent Pods from starting.");        // the one impact sentence
  const toggles = byClass(box, "rc-toggle"); assert.deepStrictEqual(toggles.map(text), ["Show fix", "Show fix"]);
  assert.deepStrictEqual(byClass(box, "rc-fix").map(f => f.hidden), [true, true]);
  assert.deepStrictEqual(toggles.map(t => t.attrs["aria-expanded"]), ["false", "false"]);
});
test("Show fix expands the corrections, Hide fix collapses them", () => {
  const box = new El("div"); RC.render(doc, box, [INOTIFY], () => Promise.resolve());
  const t = byClass(box, "rc-toggle")[0], f = byClass(box, "rc-fix")[0];
  t.onclick(); assert.strictEqual(f.hidden, false); assert.strictEqual(t.textContent, "Hide fix"); assert.strictEqual(t.attrs["aria-expanded"], "true");
  assert.match(text(f), /Recommended action/); assert.match(text(f), /To restore the previous values/);
  t.onclick(); assert.strictEqual(f.hidden, true); assert.strictEqual(t.textContent, "Show fix"); assert.strictEqual(t.attrs["aria-expanded"], "false");
});
test("cards toggle independently", () => {
  const box = new El("div"); RC.render(doc, box, [DISK, INOTIFY], () => Promise.resolve());
  const [t1, t2] = byClass(box, "rc-toggle"), [f1, f2] = byClass(box, "rc-fix");
  t1.onclick(); assert.deepStrictEqual([f1.hidden, f2.hidden], [false, true]); t2.onclick(); assert.deepStrictEqual([f1.hidden, f2.hidden], [false, false]);
});
test("a finding without any fix has no Show fix button", () => {
  const box = new El("div"); RC.render(doc, box, [{ ...DISK, fix: [], restore: [] }], () => Promise.resolve());
  assert.strictEqual(byClass(box, "rc-toggle").length, 0);
});
test("Copy lives inside the expandable fix and still copies the block", async () => {
  const box = new El("div"), sent = []; RC.render(doc, box, [DISK], t => { sent.push(t); return Promise.resolve(); });
  const fix = byClass(box, "rc-fix")[0]; assert.strictEqual(fix.hidden, true);
  all(fix, e => e.tagName === "BUTTON")[0].onclick(); await new Promise(r => setImmediate(r));
  assert.deepStrictEqual(sent, ["docker system df\ndocker builder du"]);
});
test("disk fix: read-only diagnostics, cleanup explained as manual (from the data, not from the script)", () => {
  const box = new El("div"); RC.render(doc, box, [DISK], () => Promise.resolve());
  assert.deepStrictEqual(byClass(box, "rc-cmd").map(b => text(all(b, e => e.tagName === "PRE")[0])), ["docker system df\ndocker builder du"]);
  assert.doesNotMatch(fs.readFileSync(path.join(ROOT, "web/static/resource-cards.js"), "utf8"), /docker|sysctl|inotify|DiskPressure/);        // nothing platform-specific is hardcoded
});

// --- wiring: the warning marker, the dialogs and the unchanged Start / Stop / Cancel ---
test("the warning marker is a button, shown only when there are findings, and opens the read-only view", () => {
  assert.match(APP, /h && h\.issues && h\.issues\.length \? \[alertItem\(h\)\] : \[\]/);
  assert.match(APP, /sbEl\("button", "res-item res-alert/); assert.match(APP, /item\.onclick = \(\) => showResourceInfo\(issues\)/);
  assert.match(APP, /function showResourceInfo\(issues\) \{\s*setDialog\("info"/); assert.match(APP, /confirmOk\.hidden = mode === "info"/);
});
test("the preflight dialog uses the cards and no longer carries the removed text", () => {
  assert.match(APP, /setDialog\("resources", "Resource warnings before starting ", name, "", issues\)/);
  for (const f of ["web/static/app.js", "web/static/index.html"]) { assert.doesNotMatch(read(f), /Nothing has been started/); assert.doesNotMatch(read(f), /Details and corrections: \.\/playground doctor/); }
  assert.match(APP, /e\.code === "resource_confirmation"/); assert.match(APP, /confirm_resources: true/);
});
test("no dialog without findings: the start is posted straight away", () => {
  assert.match(APP, /async function start\(name, confirmResources\) \{\s*try \{ await api\("POST"/);      // the dialog opens only from the 409 answer
});
test("Start, Stop and Cancel keep their behavior", () => {
  assert.match(APP, /askStop\(u\.name, true\)/); assert.match(APP, /"Cancel the start of "/); assert.match(APP, /`\/api\/usecases\/\$\{name\}\/stop`, \{ confirm: true \}/);
  assert.match(APP, /\(running \? askStop : start\)\(u\.name\)/);
});
test("index.html: the cards container exists and the script loads before app.js", () => {
  assert.match(HTML, /id="confirm-cards"/); assert.ok(HTML.indexOf("resource-cards.js") > 0 && HTML.indexOf("resource-cards.js") < HTML.indexOf("app.js"));
});
test("styles follow the theme: only CSS variables (light and dark), a scrolling list, a wide dialog", () => {
  const block = CSS.slice(CSS.indexOf("/* Host resource findings"));
  assert.doesNotMatch(block, /#[0-9a-fA-F]{3,6}\b|rgb\(/); assert.match(block, /var\(--warn\)/); assert.match(block, /var\(--bad\)/);
  assert.match(block, /\.rc-cards \{[^}]*overflow: auto/); assert.match(block, /max-height: 60vh/); assert.match(block, /#confirm\.wide/);
  assert.match(block, /#confirm\.wide \{[^}]*max-height: 92vh; overflow: auto/); assert.match(block, /@media \(max-height: 640px\) \{ \.rc-cards \{ max-height: 42vh/);       // scrolls on small screens
  assert.match(CSS, /--bad: #c8472b/); assert.match(CSS, /--warn: #964c0a/); assert.match(CSS, /--bad: #f48771/); assert.match(CSS, /--warn: #e5a14f/);   // both themes define the colors used
});

(async () => {
  for (const { n, f } of queue) { try { await f(); console.log("PASS " + n); } catch (e) { failures++; console.log("FAIL " + n + "\n   " + (e.message || e).split("\n").slice(0, 4).join("\n   ")); } }
  console.log(failures ? "SOME RESOURCE UI TESTS FAILED" : "ALL RESOURCE UI TESTS PASSED"); process.exit(failures ? 1 : 0);
})();
