// The terminal is the existing ttyd, served on port 7681 of the same host.
const TTYD_PORT = 7681;
const ttydUrl = `${location.protocol}//${location.hostname}:${TTYD_PORT}/`;

// Connection indicator: is ttyd reachable? (The iframe is cross-origin, so its WebSocket is not
// observable from here; a no-cors request only tells whether the server answers.)
const conn = document.getElementById("conn");
const text = document.getElementById("conn-text");
async function check() {
  let up = false;
  try {
    await fetch(ttydUrl + "token", { mode: "no-cors", cache: "no-store", signal: AbortSignal.timeout(3000) });
    up = true;
  } catch (_) { /* unreachable */ }
  conn.className = "conn " + (up ? "up" : "down");
  text.textContent = up ? "Connected" : "Disconnected";
}
check();
setInterval(check, 5000);

// Terminal tabs. Each tab is a pane of one to four iframes on the one ttyd (?arg=<use case>); ttyd starts a Bash for each. Iframes are
// created on first use and then only shown/hidden, never reloaded, so switching tabs keeps every shell, running
// command and scrollback. Reloading the page (or closing a tab's iframe) ends its Bash: there are no sessions.
const tabsEl = document.getElementById("tabs");
const panes = document.getElementById("panes");
const splitBtn = document.getElementById("split");
splitBtn.onclick = splitActive;
const frames = new Map();            // tab id -> pane (grid of one to four terminal cells)
const MAX_PANELS = 4;                // split view: panel 1 is the tab's own terminal, 2-4 are splits
let terminals = [{ id: "main", title: "Playground", usecase: null }];
let activeTab = "main";
let tabsSignature = "";
let highlighted = null;              // use case highlighted in the sidebar (the active tab's, or a stopped one clicked)
let userChose = false, initialized = false, restored = false, usecasesLoaded = false, terminalsLoaded = false;
const store = {
  get() { try { return localStorage.getItem("activeTab"); } catch (_) { return null; } },
  set(v) { try { localStorage.setItem("activeTab", v); } catch (_) { /* optional */ } },
};
const savedTab = store.get();

// A use case's tab is visible from the data /api/usecases already returns: hidden while a Start is running
// (a cluster may exist before provisioning finishes), visible while a Stop is running, otherwise visible
// exactly when clusters exist (so a failed Start/Stop that leaves clusters keeps its tab). The Playground
// tab is always visible. Hiding a tab drops its iframe (and its Bash).
function tabEligible(name) {
  const u = items.find(x => x.name === name);
  if (!u) return false;
  const op = u.operation && u.operation.state;
  if (op === "starting") return false;
  if (op === "stopping") return true;
  return u.clusters > 0;
}
const visibleTabs = () => terminals.filter(t => t.usecase === null || tabEligible(t.usecase));

function focusActive() {
  const pane = frames.get(activeTab);
  focusFrame(pane && pane.querySelector("iframe"));
}

function focusFrame(frame) {
  if (!frame) return;
  frame.focus();
  try { frame.contentWindow.focus(); } catch (_) { /* not ready yet */ }
}

function renderTabs() {
  const visible = visibleTabs();
  const signature = activeTab + "|" + visible.map(t => t.id).join(",");
  if (signature === tabsSignature) return;
  tabsSignature = signature;
  tabsEl.replaceChildren(...visible.map(t => {
    const b = document.createElement("button");
    b.type = "button";
    b.role = "tab";
    b.textContent = t.title;
    b.className = t.id === activeTab ? "active" : "";
    b.onclick = () => selectTab(t.id);
    return b;
  }));
}

// remember=false for automatic selections (initial, fallback to Playground), so they never overwrite the user's choice.
function selectTab(id, { remember = true } = {}) {
  const tab = visibleTabs().find(t => t.id === id);
  if (!tab) return;
  activeTab = id;
  refreshStatus();                       // read-only: only the bar changes, nothing is sent to the shell
  highlighted = tab.usecase;
  if (remember) { store.set(id); userChose = true; }
  renderTabs();
  render();                                   // sidebar highlight follows the tab
  if (!frames.has(id)) {
    const pane = document.createElement("div");
    pane.className = "pane";
    pane.dataset.count = "0";
    pane.append(separator(pane, "v"), separator(pane, "h"));
    panes.append(pane);
    frames.set(id, pane);
    addPanel(tab, 1);
  }
  for (const [fid, pane] of frames) pane.classList.toggle("active", fid === activeTab);
  renderSplit();
  focusActive();
}

const cellsOf = pane => [...pane.querySelectorAll(":scope > .cell")];

// Draggable separators (resizable split): "v" moves the column boundary (--cx), "h" the row boundary (--cy), both
// as fractions of the pane. Only the grid template changes: iframes are resized in place, so ttyd's own window
// resize handler refits xterm.js and nothing reconnects. Each side keeps at least MIN_PANEL pixels.
const MIN_PANEL = 160;
function separator(pane, kind) {
  const bar = document.createElement("div");
  bar.className = "sep sep-" + kind;
  bar.setAttribute("role", "separator");
  bar.setAttribute("aria-orientation", kind === "v" ? "vertical" : "horizontal");
  bar.onpointerdown = e => {
    e.preventDefault();
    bar.setPointerCapture(e.pointerId);
    pane.classList.add("dragging");                 // iframes ignore the pointer while dragging
  };
  bar.onpointermove = e => {
    if (!bar.hasPointerCapture(e.pointerId)) return;
    const r = pane.getBoundingClientRect();
    const size = kind === "v" ? r.width : r.height;
    const pos = kind === "v" ? e.clientX - r.left : e.clientY - r.top;
    const min = Math.min(MIN_PANEL, size / 2 - 1) / size;
    pane.style.setProperty(kind === "v" ? "--cx" : "--cy", Math.max(min, Math.min(1 - min, pos / size)).toFixed(4));
  };
  const stop = e => { bar.releasePointerCapture?.(e.pointerId); pane.classList.remove("dragging"); };
  bar.onpointerup = stop;
  bar.onpointercancel = stop;
  bar.ondblclick = () => pane.style.removeProperty(kind === "v" ? "--cx" : "--cy");   // back to an even split
  return bar;
}

// A panel = a cell with one iframe = one ttyd connection = one Bash with its own kubeconfig. Panel 1 loads the same
// URL as before the split view existed; panels 2-4 add a second ?arg=<n> (engine/terminal.sh). Cells stay in panel
// order, the CSS grid lays them out from data-count.
function addPanel(tab, slot) {
  const pane = frames.get(tab.id);
  const cell = document.createElement("div");
  cell.className = "cell";
  cell.dataset.slot = slot;
  const label = document.createElement("div");
  label.className = "cell-label";
  const name = document.createElement("span");
  name.textContent = "Terminal " + slot;
  label.append(name);
  if (slot > 1) {
    const close = document.createElement("button");
    close.type = "button";
    close.textContent = "✕";
    close.title = "Close this terminal";
    close.setAttribute("aria-label", "Close terminal " + slot);
    close.onclick = () => { cell.remove(); pane.dataset.count = cellsOf(pane).length; renderSplit(); focusActive(); };
    label.append(close);
  }
  const frame = document.createElement("iframe");
  frame.title = tab.title + " - terminal " + slot;
  frame.onload = () => { if (tab.id === activeTab) focusFrame(frame); };
  const arg = tab.usecase ? `?arg=${encodeURIComponent(tab.usecase)}${slot > 1 ? "&arg=" + slot : ""}` : "";
  frame.src = ttydUrl + arg;
  cell.append(label, frame);
  const next = cellsOf(pane).find(c => Number(c.dataset.slot) > slot);
  pane.insertBefore(cell, next || null);
  pane.dataset.count = cellsOf(pane).length;
}

function splitActive() {
  const tab = visibleTabs().find(t => t.id === activeTab), pane = frames.get(activeTab);
  if (!tab || !tab.usecase || !pane || cellsOf(pane).length >= MAX_PANELS) return;
  const used = cellsOf(pane).map(c => Number(c.dataset.slot));
  const slot = [2, 3, 4].find(n => !used.includes(n));
  addPanel(tab, slot);
  renderSplit();
}

// The Split button belongs to use case tabs only and disappears at four panels.
function renderSplit() {
  const tab = terminals.find(t => t.id === activeTab), pane = frames.get(activeTab);
  splitBtn.hidden = !(tab && tab.usecase && pane && cellsOf(pane).length < MAX_PANELS);
}

// Tabs follow the lifecycle of the use cases. A hidden tab loses its iframe, so its Bash ends; when the tab comes
// back it starts a new one. API errors keep the last known tabs.
function syncTabs() {
  const visible = visibleTabs();
  for (const [id, frame] of frames) {
    if (!visible.some(t => t.id === id)) { frame.remove(); frames.delete(id); }
  }
  if (!terminalsLoaded) return;
  if (!initialized) { initialized = true; return selectTab(activeTab, { remember: false }); }
  if (!visible.some(t => t.id === activeTab)) return selectTab("main", { remember: false });
  if (!restored && usecasesLoaded) {
    restored = true;
    if (!userChose && visible.some(t => t.id === savedTab)) return selectTab(savedTab, { remember: false });
  }
  renderTabs();
}

async function refreshTerminals() {
  try {
    terminals = (await api("GET", "/api/terminals")).terminals;
  } catch (_) { return; }
  terminalsLoaded = true;
  syncTabs();
}

// Clicking a use case selects its tab when it has one; a stopped/starting use case is only highlighted.
function selectUseCase(name) {
  if (visibleTabs().some(t => t.usecase === name)) return selectTab("uc-" + name);
  highlighted = name;
  render();
}

// Use case sidebar, polled every 3 s. Selecting only highlights; Start/Stop run the CLI lifecycle (./playground usecase start|stop)
// through the API (never in the terminal session).
const list = document.getElementById("usecases");
const errorBox = document.getElementById("uc-error");
let items = [];
let lastSignature = "";

const active = op => op && (op.state === "starting" || op.state === "stopping");
const showError = msg => { errorBox.textContent = msg; errorBox.hidden = !msg; };

async function api(method, path, body) {
  const r = await fetch(path, {
    method, cache: "no-store", signal: AbortSignal.timeout(10000),
    headers: body ? { "Content-Type": "application/json" } : {}, body: body ? JSON.stringify(body) : undefined,
  });
  const data = await r.json();
  if (!r.ok) throw new Error(data.error || r.status);
  return data;
}

// Provider logos, keyed by provider.name from usecase.yaml (never inferred from the use case name or provider.type). Add a provider here.
const PROVIDER_ICONS = { kind: "icons/kind.svg", k3d: "icons/k3d.svg", openshift: "icons/openshift.svg" };
const DEFAULT_PROVIDER_ICON = "icons/kubernetes.svg";
function providerIcon(u) {
  const pname = u.provider && u.provider.name;
  const img = document.createElement("img");
  img.className = "uc-provider";
  img.src = PROVIDER_ICONS[pname] || DEFAULT_PROVIDER_ICON;
  img.alt = ""; img.title = pname || "kubernetes";
  return img;
}

// Sidebar groups: Running first, then Available; an instant case-insensitive filter; each group collapses (kept in memory).
const searchBox = document.getElementById("uc-search");
const groupCollapsed = { running: false, available: false };
let searchTyped = false;     // the filter applies only to text the person typed or pasted, never to a value a browser autofilled into the box
const matches = u => {
  const q = searchTyped ? searchBox.value.trim().toLowerCase() : "";
  return !q || [u.name, u.title, u.description, u.provider && u.provider.name].some(t => (t || "").toLowerCase().includes(q));
};
function ucGroup(key, label, members, selected) {
  const head = document.createElement("li");
  head.className = "uc-section" + (groupCollapsed[key] ? " collapsed" : "");
  head.setAttribute("role", "button");
  head.tabIndex = 0;
  head.setAttribute("aria-expanded", String(!groupCollapsed[key]));
  head.textContent = `${label} (${members.length})`;
  const toggle = () => { groupCollapsed[key] = !groupCollapsed[key]; render(); };
  head.onclick = toggle;
  head.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } };
  return [head, ...(groupCollapsed[key] ? [] : members.map(u => ucItem(u, selected)))];
}
searchBox.addEventListener("keydown", () => { searchTyped = true; });
searchBox.addEventListener("paste", () => { searchTyped = true; });
searchBox.oninput = () => { if (!searchTyped && searchBox.value) searchBox.value = ""; if (!searchBox.value) searchTyped = false; render(); };

function ucItem(u, selected) {
    const op = u.operation;
    const li = document.createElement("li");
    li.className = u.status + (u.name === selected ? " selected" : "");
    li.onclick = () => selectUseCase(u.name);

    const row = document.createElement("div");
    row.className = "uc-row";
    const name = document.createElement("div");
    name.className = "uc-name";
    name.append(providerIcon(u), u.title || u.name);
    if (u.description) li.title = u.description;
    const button = document.createElement("button");
    button.type = "button";
    if (active(op)) {
      button.disabled = true;
      button.className = "busy";
      button.textContent = op.state === "starting" ? "Starting" : "Stopping";
    } else {
      button.textContent = u.status === "running" ? "Stop" : "Start";
      button.onclick = e => { e.stopPropagation(); (u.status === "running" ? askStop : start)(u.name); };
    }
    row.append(name, button);

    const meta = document.createElement("div");
    meta.className = "uc-meta";
    meta.textContent = `${u.status === "running" ? "Running" : "Stopped"} · ${u.clusters} cluster${u.clusters === 1 ? "" : "s"}`;
    li.append(row, meta);

    if (op) {
      const line = document.createElement("div");
      line.className = "uc-op" + (op.state === "failed" ? " failed" : "");
      const label = document.createElement("span");
      label.className = "timer";
      label.textContent = opText(u);
      opViews.set(u.name, label);
      const link = document.createElement("a");
      link.textContent = "logs";
      link.onclick = e => { e.stopPropagation(); openLogs(u.name); };
      line.append(label, " · ", link);
      li.append(line);
    }
  return li;
}

function render() {
  opViews.clear();
  if (highlighted && !items.some(u => u.name === highlighted)) highlighted = null;
  const selected = highlighted;
  const shown = items.filter(matches);
  const running = shown.filter(u => u.status === "running"), available = shown.filter(u => u.status !== "running");
  list.replaceChildren(...ucGroup("running", "Running", running, selected), ...ucGroup("available", "Available", available, selected));
  if (!items.length) list.innerHTML = '<li class="muted">No use case found</li>';
  else if (!shown.length) list.append(Object.assign(document.createElement("li"), { className: "muted", textContent: "No match" }));
}

// --- Start timer. The backend stamps each operation (server clock) and reports `elapsed` / `since_finished` with
// every poll; between polls the page extends them with its own clock. One 1 s ticker redraws the labels; polling
// never restarts a timer, and a refreshed page resumes from the server's value.
const opClock = new Map();     // use case -> { started, elapsed, since, running, at, shown }
const opViews = new Map();     // use case -> label element currently in the list
const SUCCESS_SHOWN = 8;       // seconds the final duration of a successful Start stays visible
function trackClocks(usecases) {
  const now = Date.now();
  for (const u of usecases) {
    const op = u.operation;
    if (!op) { opClock.delete(u.name); continue; }
    const prev = opClock.get(u.name);
    opClock.set(u.name, { started: op.started, elapsed: op.elapsed, since: op.since_finished, running: active(op), at: now,
      shown: prev && prev.started === op.started ? prev.shown : 0 });
  }
}
const pad2 = n => String(n).padStart(2, "0");
const fmtDuration = secs => `${pad2(Math.floor(secs / 60))}:${pad2(Math.floor(secs % 60))}`;
function clockSeconds(name) {
  const c = opClock.get(name);
  if (!c) return 0;
  let e = c.elapsed + (c.running ? (Date.now() - c.at) / 1000 : 0);
  if (c.running) { e = Math.max(e, c.shown); c.shown = e; }          // never goes backwards when a poll re-bases it
  return e;
}
function opText(u) {
  const op = u.operation, c = opClock.get(u.name);
  if (op.state === "starting") return `Starting… ${fmtDuration(clockSeconds(u.name))}`;
  if (op.state === "stopping") return "stopping…";
  const took = op.kind === "start" ? ` — ${fmtDuration(clockSeconds(u.name))}` : "";
  if (op.state === "failed") return `${op.kind} failed (exit ${op.exit_code})${took}`;
  const sinceDone = c && c.since !== null ? c.since + (Date.now() - c.at) / 1000 : Infinity;
  return op.kind === "start" && sinceDone < SUCCESS_SHOWN ? `Running${took}` : `${op.kind} succeeded`;
}
setInterval(() => {
  for (const [name, el] of opViews) {
    const u = items.find(x => x.name === name);
    if (u && u.operation) { const t = opText(u); if (el.textContent !== t) el.textContent = t; }
  }
}, 1000);

async function refreshUseCases() {
  try {
    const body = await api("GET", "/api/usecases");
    showError("");
    trackClocks(body.usecases);
    // Durations change on every poll: they must not force a rebuild of the list (the 1 s ticker draws them).
    const signature = JSON.stringify(body.usecases, (k, v) => (k === "elapsed" || k === "since_finished" ? undefined : v));
    if (signature !== lastSignature) {   // no DOM rebuild (and no lost click) when nothing changed
      lastSignature = signature;
      items = body.usecases;
      usecasesLoaded = true;
      render();
      syncTabs();                        // tab visibility depends on status and operation state
    }
  } catch (e) {
    // Keep the last known list: an error is not "Stopped".
    showError(`Status unavailable: ${e.message}`);
  }
}

async function start(name) {
  try { await api("POST", `/api/usecases/${name}/start`); openLogs(name); }
  catch (e) { showError(`Start ${name}: ${e.message}`); }
  refreshUseCases();
}

const dialog = document.getElementById("confirm");
let stopTarget = null;
function askStop(name) {
  stopTarget = name;
  document.getElementById("confirm-name").textContent = name;
  dialog.showModal();
}
document.getElementById("confirm-cancel").onclick = () => dialog.close();
document.getElementById("confirm-ok").onclick = async () => {
  dialog.close();
  const name = stopTarget;
  try { await api("POST", `/api/usecases/${name}/stop`, { confirm: true }); openLogs(name); }
  catch (e) { showError(`Stop ${name}: ${e.message}`); }
  refreshUseCases();
};

// Log panel: polls the operation output of one use case while open.
const panel = document.getElementById("logs");
const logBody = document.getElementById("logs-body");
let logName = null, logOffset = 0, logStarted = null, logTimer = null;

// Minimal ANSI SGR renderer: foreground colors (8/16, 256 and truecolor), bold, reset. Text is only ever
// added with textContent, so log content cannot inject HTML. State and an unfinished escape sequence
// carry over between polling chunks.
const XTERM16 = ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
  "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff"];
function color256(n) {
  if (n < 16) return XTERM16[n];
  if (n >= 232) { const g = 8 + (n - 232) * 10; return `rgb(${g},${g},${g})`; }
  const c = n - 16, level = v => (v ? 55 + v * 40 : 0);
  return `rgb(${level(Math.floor(c / 36))},${level(Math.floor(c / 6) % 6)},${level(c % 6)})`;
}
let ansiStyle = { fg: null, bold: false }, ansiPending = "";
function ansiReset() { ansiStyle = { fg: null, bold: false }; ansiPending = ""; }

function applySgr(params) {
  const p = params === "" ? [0] : params.split(";").map(Number);
  for (let i = 0; i < p.length; i++) {
    const n = p[i];
    if (n === 0) ansiStyle = { fg: null, bold: false };
    else if (n === 1) ansiStyle.bold = true;
    else if (n === 22) ansiStyle.bold = false;
    else if (n >= 30 && n <= 37) ansiStyle.fg = XTERM16[n - 30];
    else if (n >= 90 && n <= 97) ansiStyle.fg = XTERM16[n - 90 + 8];
    else if (n === 39) ansiStyle.fg = null;
    else if (n === 38 && p[i + 1] === 5) { ansiStyle.fg = color256(p[i + 2] || 0); i += 2; }
    else if (n === 38 && p[i + 1] === 2) { ansiStyle.fg = `rgb(${p[i + 2] || 0},${p[i + 3] || 0},${p[i + 4] || 0})`; i += 4; }
  }
}

function emitText(container, text) {
  text = text.replace(/\r/g, "");
  if (!text) return;
  const span = document.createElement("span");
  if (ansiStyle.fg) span.style.color = ansiStyle.fg;
  if (ansiStyle.bold) span.style.fontWeight = "bold";
  span.textContent = text;
  container.append(span);
}

function appendAnsi(container, chunk) {
  const text = ansiPending + chunk;
  const re = /\x1b\[([0-9;?]*)([@-~])/g;
  let last = 0, m;
  ansiPending = "";
  while ((m = re.exec(text))) {
    emitText(container, text.slice(last, m.index));
    if (m[2] === "m") applySgr(m[1]);
    last = re.lastIndex;
  }
  let rest = text.slice(last);
  const esc = rest.lastIndexOf("\x1b");
  if (esc >= 0 && /^\x1b(\[[0-9;?]*)?$/.test(rest.slice(esc))) {   // sequence cut by the chunk boundary
    ansiPending = rest.slice(esc);
    rest = rest.slice(0, esc);
  }
  emitText(container, rest);
}

async function pollLogs() {
  if (!logName) return;
  try {
    const op = await api("GET", `/api/usecases/${logName}/operation?offset=${logOffset}`);
    if (op.state === "idle") { logBody.textContent = "No operation yet."; }
    else {
      if (op.started !== logStarted) {   // a different operation: start reading its log from the top
        logBody.textContent = ""; ansiReset(); logStarted = op.started; logOffset = 0;
        logTimer = setTimeout(pollLogs, 0);
        return;
      }
      if (op.log) {
        const atBottom = logBody.scrollTop + logBody.clientHeight >= logBody.scrollHeight - 20;
        appendAnsi(logBody, op.log);
        if (atBottom) logBody.scrollTop = logBody.scrollHeight;
      }
      logOffset = op.offset;
      document.getElementById("logs-state").textContent =
        op.state + (op.exit_code === null ? "" : ` (exit ${op.exit_code})`);
    }
  } catch (e) { document.getElementById("logs-state").textContent = e.message; }
  logTimer = setTimeout(pollLogs, 1000);
}

function openLogs(name) {
  clearTimeout(logTimer);
  logName = name; logOffset = 0; logStarted = null; logBody.textContent = ""; ansiReset();
  document.getElementById("logs-title").textContent = `Operation log: ${name}`;
  panel.hidden = false;
  pollLogs();
}
document.getElementById("logs-close").onclick = () => { clearTimeout(logTimer); logName = null; panel.hidden = true; };

refreshUseCases();
setInterval(refreshUseCases, 3000);
refreshTerminals();
setInterval(refreshTerminals, 3000);

// --- Status bar: read-only view of the selected tab (GET /api/status). All backend values go in through
// textContent / setAttribute on elements built here, never through innerHTML.
const statusBar = document.getElementById("statusbar");
let statusSignature = "";
function sbEl(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
function sbLink(label, url, title) {
  if (!url) { const na = sbEl("span", "na", label + " —"); na.title = "Not available"; return na; }
  const a = sbEl("a", "", label + " ↗");
  a.href = url; a.target = "_blank"; a.rel = "noopener noreferrer";
  if (title) a.title = title;
  return a;
}
function renderStatus(s, tab) {
  const signature = JSON.stringify(s);
  if (signature === statusSignature) return;
  statusSignature = signature;
  const parts = [sbEl("span", "sb-term", tab.title)];
  if (s.status) parts.push(sbEl("span", "sb-badge " + s.status, s.status[0].toUpperCase() + s.status.slice(1)));
  const ctx = sbEl("span", "sb-ctx" + (s.context_state === "ok" ? "" : s.context_state === "unavailable" ? " warn" : " muted"), "Context: ");
  ctx.title = "Current Kubernetes context for this terminal";
  const hints = { ok: s.context, none: "No context", unavailable: s.context + " (not found)", "no-session": "No context (terminal not opened yet)" };
  ctx.append(sbEl("code", "", hints[s.context_state] || "No context"));
  parts.push(ctx);
  if (s.error) parts.push(sbEl("span", "na", "Clusters unavailable: " + s.error));
  for (const c of s.clusters) {
    const box = sbEl("span", "sb-cluster" + (c.context === s.context ? " current" : ""));
    box.title = `Cluster: ${c.name}\nContext: ${c.context}`;
    box.append(sbEl("code", "", c.name), sbLink("Grafana", c.grafana_url), sbLink("MinIO", c.minio_console_url, "Open MinIO Console"));
    parts.push(box);
  }
  statusBar.replaceChildren(...parts);
}
async function refreshStatus() {
  const id = activeTab, tab = terminals.find(t => t.id === id);
  if (!tab) return;
  try {
    const res = await fetch("/api/status?terminal=" + encodeURIComponent(id), { signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const s = await res.json();
    if (id === activeTab) renderStatus(s, tab);      // a slower answer for a tab we left is dropped
  } catch (_) {
    if (id === activeTab) renderStatus({ status: null, context: null, context_state: "none", clusters: [], error: "status unavailable" }, tab);
  }
}
refreshStatus();
setInterval(refreshStatus, 3000);

// --- Docker resources (GET /api/docker/resources, read-only; the backend caches, so polling is cheap).
// Playground = Kind nodes of this project only. CPU is Docker's raw % (100% = one logical CPU), never capped;
// the bar is the share of the Engine's CPU capacity. RAM is Playground usage against the Engine's memory.
const resBar = document.getElementById("resources");
let resData = null, resFetchedAt = 0, resFailure = null, resAgeEl = null;
const GIB = 1024 ** 3;
const fmtBytes = b => b >= GIB ? (b / GIB).toFixed(1) + " GiB" : Math.round(b / 1024 ** 2) + " MiB";
function resItem(label, value, title, fraction) {
  const item = sbEl("span", "res-item");
  item.title = title;
  item.append(sbEl("span", "", label), sbEl("b", "", value));
  if (fraction !== undefined) {
    const bar = sbEl("span", "res-bar"), fill = sbEl("i", fraction > 0.85 ? "hot" : "");
    fill.style.width = Math.min(100, Math.max(0, fraction * 100)).toFixed(0) + "%";
    bar.append(fill); item.append(bar);
  }
  return item;
}
function ageText() {
  if (!resData || resData.age_seconds === null) return "never";
  const secs = Math.max(0, Math.round(resData.age_seconds + (Date.now() - resFetchedAt) / 1000));
  return secs + "s ago";
}
// Utilisation level of a 0..1 fraction: ok (< 70%), warn (70-85%), crit (> 85%). Colors the percentage and the bar.
const resLevel = f => f > 0.85 ? "crit" : f >= 0.70 ? "warn" : "ok";
function usageItem(label, fraction, tip) {          // fraction null = not available
  const item = sbEl("span", "res-item lvl-" + (fraction === null ? "na" : resLevel(fraction)));
  item.title = tip;
  const pct = fraction === null ? "N/A" : (fraction * 100 < 10 ? (fraction * 100).toFixed(1) : String(Math.round(fraction * 100))) + "%";
  item.append(sbEl("span", "res-lbl", label), sbEl("b", "res-pct", pct));
  if (fraction !== null) {
    const bar = sbEl("span", "res-bar"), fill = sbEl("i", "");
    fill.style.width = Math.min(100, Math.max(0, fraction * 100)).toFixed(0) + "%";
    bar.append(fill); item.append(bar);
  }
  return item;
}
const countItem = (label, value, tip, unit) => { const i = sbEl("span", "res-item"); i.title = tip; i.append(...(label ? [sbEl("span", "res-lbl", label)] : []), sbEl("b", "", value), ...(unit ? [sbEl("span", "res-lbl", unit)] : [])); return i; };
function renderResources() {
  const d = resData, secs = [];
  // Section icons (local SVGs, tinted with the mask technique) instead of names; the host icon follows the real host OS.
  const OS_ICONS = { macos: ["os-apple.svg", "macOS"], windows: ["os-windows.svg", "Windows"], linux: ["os-linux.svg", "Linux"] };
  const icon = (file, tip, color) => { const i = sbEl("span", "res-icon"); i.title = tip; i.style.setProperty("--icon", `url("icons/${file}")`); if (color) i.style.setProperty("--tint", color); return i; };
  const section = (ic, ...items) => { const s = sbEl("span", "res-sec"); s.append(ic, ...items); secs.push(s); };
  // HOST: the machine itself (host-side sampler); N/A without a fresh sample, never a container figure
  const h = d && d.host;
  const [osFile, osName] = (h && OS_ICONS[h.os]) || ["computer.svg", h ? "Host (OS unknown)" : "Host (no host metrics)"];
  section(icon(osFile, "Host: " + osName),
    usageItem("CPU", h ? h.cpu_percent / 100 : null, h ? `Host CPU: ${h.cpu_percent.toFixed(1)}% of ${h.cpus} logical CPUs` : "Host metrics are not available (no host-side sampler running)"),
    usageItem("RAM", h ? h.mem_used_bytes / h.mem_total_bytes : null, h ? `Host RAM: ${fmtBytes(h.mem_used_bytes)} used of ${fmtBytes(h.mem_total_bytes)}` : "Host metrics are not available (no host-side sampler running)"));
  if (d && d.engine && d.playground) {
    const e = d.engine, p = d.playground, cores = p.cpu_percent / 100;   // Docker: 100% = one logical CPU
    section(icon("docker.svg", "Docker", "#2496ed"),
      usageItem("CPU", e.cpus > 0 ? cores / e.cpus : null, `Docker CPU: ${cores.toFixed(2)} of ${e.cpus} cores allocated to the Docker Engine\n(Docker's raw figure: ${p.cpu_percent}% of one CPU)`),
      usageItem("RAM", p.memory_used_bytes / e.memory_total_bytes, `Docker RAM: ${fmtBytes(p.memory_used_bytes)} used by the Playground's Kubernetes nodes of ${fmtBytes(e.memory_total_bytes)} allocated to the Docker Engine`),
      countItem("", `${e.containers_running}`, `Docker containers: ${e.containers_running} running, ${e.containers_stopped} stopped`, "ctrs"));
    section(icon("kubernetes.svg", "Kubernetes", "none"),
      countItem("Nodes", String(p.kind_containers_running), `Running node containers of Playground clusters (Kind and k3d). Docker Engine: ${e.containers_running} running, ${e.containers_stopped} stopped`),
      countItem("Clusters", p.kind_clusters_running === p.kind_clusters_existing ? String(p.kind_clusters_running) : `${p.kind_clusters_running} of ${p.kind_clusters_existing}`, "Playground clusters (Kind and k3d) with all their nodes running" + (p.kind_clusters_running === p.kind_clusters_existing ? "" : " (some exist with stopped nodes)")));
  } else {
    section(icon("docker.svg", "Docker", "#2496ed"), sbEl("span", "res-stale", "Docker unavailable" + (resFailure ? ": " + resFailure : "")));
  }
  resAgeEl = sbEl("span", (d && d.stale) || resFailure ? "res-stale res-age" : "res-age", d && d.engine ? "Updated " + ageText() : "No measurement yet");
  const parts = [...secs];
  if (d && d.stale && d.engine) parts.push(sbEl("span", "res-stale", "Docker unavailable, last values"));
  parts.push(resAgeEl);
  resBar.replaceChildren(...parts);
}
async function refreshResources() {
  try {
    const res = await fetch("/api/docker/resources", { signal: AbortSignal.timeout(25000) });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const data = await res.json();
    resFailure = null;
    if (data.engine || !resData) resData = data;       // keep the last real numbers over an empty answer
    else resData = { ...resData, stale: true };
    if (!data.engine) resFailure = data.error;
    resFetchedAt = Date.now();
  } catch (e) {
    resFailure = "monitor unreachable";
    if (resData) resData = { ...resData, stale: true };
  }
  renderResources();
}
setInterval(() => { if (resAgeEl && resData && resData.engine) resAgeEl.textContent = "Updated " + ageText(); }, 1000);
renderResources();
refreshResources();
setInterval(refreshResources, 4000);

// --- Sidebar toggle: CSS class only (iframes and running commands are untouched), remembered per browser.
const mainEl = document.querySelector("main");
const sidebarToggle = document.getElementById("sidebar-toggle");
const sidebarStore = {
  get() { try { return localStorage.getItem("sidebarCollapsed") === "1"; } catch (_) { return false; } },
  set(v) { try { localStorage.setItem("sidebarCollapsed", v ? "1" : "0"); } catch (_) { /* optional */ } },
};
function setSidebar(collapsed, { remember = true } = {}) {
  mainEl.classList.toggle("collapsed", collapsed);
  sidebarToggle.setAttribute("aria-expanded", String(!collapsed));
  sidebarToggle.title = collapsed ? "Show sidebar" : "Hide sidebar";
  if (remember) sidebarStore.set(collapsed);
}
sidebarToggle.onclick = () => { setSidebar(!mainEl.classList.contains("collapsed")); focusActive(); };
setSidebar(sidebarStore.get(), { remember: false });

// --- Theme: light (EDB Blue Coal, default) or dark, switched by the header button. Only a data-theme attribute on
// <html> changes, so terminals and polling are untouched; the choice is remembered in this browser.
const themeBtn = document.getElementById("theme-toggle");
const themeStore = {
  get() { try { return localStorage.getItem("theme") === "dark" ? "dark" : "light"; } catch (_) { return "light"; } },
  set(v) { try { localStorage.setItem("theme", v); } catch (_) { /* optional */ } },
};
function applyTheme(theme, { remember = true } = {}) {
  const dark = theme === "dark";
  if (dark) document.documentElement.setAttribute("data-theme", "dark");
  else document.documentElement.removeAttribute("data-theme");
  themeBtn.textContent = dark ? "☀ Light" : "☾ Dark";
  themeBtn.title = dark ? "Switch to light mode" : "Switch to dark mode";
  themeBtn.setAttribute("aria-pressed", String(dark));
  if (remember) themeStore.set(theme);
}
themeBtn.onclick = () => { applyTheme(document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark"); focusActive(); };
applyTheme(themeStore.get(), { remember: false });

// --- Version: read from the backend (VERSION file), never hard-coded here. A failure just leaves it hidden.
(async () => {
  try {
    const res = await fetch("/api/meta", { cache: "no-store", signal: AbortSignal.timeout(5000) });
    const { version } = await res.json();
    if (version) document.getElementById("version").textContent = "v" + version;
  } catch (_) { /* optional */ }
})();
