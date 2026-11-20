// AI Use Case Builder panel. Talks ONLY to the Playground API under /api/ai-builder/ (a server-side
// proxy): never to the AI Builder's own port, and it never sees the bearer token or any Claude credential.
// Every backend value goes into the page through textContent / value, never as markup.
// The first half is pure logic (unit-tested with Node: tests/ai_builder_ui_test.js); the second half is the DOM wiring.

const AIB_API = "/api/ai-builder";
const AIB_START_CMD = "./playground ai-builder start";
const AIB_LOGIN_HOSTS = ["claude.ai", "claude.com", "anthropic.com"];
const AIB_CODE_RE = /^[A-Za-z0-9_\-#.~%+=\/]{8,2048}$/;
const AIB_AUTH_ACTIVE = ["starting", "awaiting_browser", "verifying"];
const AIB_MAX_MESSAGE = 4000;
const AIB_PANEL_MIN = 320, AIB_PANEL_MAX = 720, AIB_PANEL_DEFAULT = 440, AIB_TERMINAL_MIN = 48, AIB_PANEL_FRACTION = 0.9;     // pixels (MAX only when the geometry is unknown)

const AIBCore = {
  formatError(res) {
    const d = (res && res.data) || {};
    let msg = d.error || `The request failed (HTTP ${res ? res.status : "?"}).`;
    if (Array.isArray(d.details) && d.details.length && !msg.includes(d.details[0])) msg += " " + d.details.slice(0, 5).join(" · ");
    return msg;
  },
  // What the header badge and the banner say, and whether a new draft can be generated now.
  describeHealth(health, networkError, auth) {
    if (networkError || !health) return { level: "bad", badge: "Unreachable", canGenerate: false, banner: "The Playground API did not answer. Is the Playground running?" };
    if (!health.available) {
      const hint = health.hint || AIB_START_CMD;
      const texts = {
        stopped: `The AI Builder is not running. Start it on the host: ${hint}`,
        not_configured: `The AI Builder is not set up yet. Start it on the host: ${hint}`,
        timeout: "The AI Builder did not answer in time. Try again in a moment.",
      };
      return { level: "bad", badge: health.state === "timeout" ? "Not answering" : "Not running", canGenerate: false,
        banner: texts[health.state] || `The AI Builder is unavailable: ${health.error || "unknown error"}` };
    }
    if (health.state === "claude_missing") return { level: "bad", badge: "Claude CLI missing", canGenerate: false, banner: "The Claude Code CLI is not available in the AI Builder." };
    if (health.state === "not_signed_in") {
      return { level: "warn", badge: "Claude not signed in", canGenerate: false, needsConnect: true,
        banner: "Claude is not signed in. Select “Connect to Claude” to sign in from this page." };
    }
    if (auth && auth.logged_in === false) {                       // the credentials file exists but Claude says the login is not valid
      return { level: "warn", badge: "Claude session expired", canGenerate: false, needsConnect: true,
        banner: "Your Claude sign-in is no longer valid (expired or removed). Select “Connect to Claude” to sign in again." };
    }
    return { level: "ok", badge: health.claude_credentials_present === true ? "Ready · Claude signed in" : "Ready", canGenerate: true, banner: "" };
  },
  // Only an https address of an official Claude/Anthropic host is ever turned into a link.
  isAllowedLoginUrl(url) {
    try {
      const u = new URL(url);
      const host = u.hostname.toLowerCase();
      return u.protocol === "https:" && !u.username && !u.password && url.length <= 4096 && AIB_LOGIN_HOSTS.some(h => host === h || host.endsWith("." + h));
    } catch (_) { return false; }
  },
  // The authorization code is the text the sign-in page shows: a web address or text with spaces is a mistake.
  validateCode(code) {
    const c = (code || "").trim();
    if (!c) return "Paste the authorization code shown by the Claude sign-in page.";
    if (/^https?:\/\//i.test(c)) return "That is a web address, not the code. Paste the code shown on the last page of the sign-in.";
    if (/\s/.test(c)) return "The code has no spaces: copy it again from the sign-in page.";
    if (!AIB_CODE_RE.test(c)) return "That does not look like an authorization code.";
    return "";
  },
  // What the sign-in section shows for a session: text, whether the link and the code field are offered, whether it is still running.
  describeSession(session) {
    if (!session) return { active: false, text: "", showLink: false, showCode: false, done: false };
    const active = AIB_AUTH_ACTIVE.includes(session.state);
    const texts = {
      starting: "Starting the Claude Code sign-in…",
      awaiting_browser: "Open the Claude sign-in page and sign in. At the end it shows an authorization code: copy it and paste it below.",
      verifying: "Checking the code…",
      succeeded: "Connected to Claude.",
      failed: session.error || "The sign-in failed.",
      cancelled: "Sign-in cancelled.",
    };
    return { active, text: texts[session.state] || "", error: session.state === "failed", done: !active,
      showLink: session.state === "awaiting_browser" && AIBCore.isAllowedLoginUrl(session.url || ""),
      showCode: session.state === "awaiting_browser" && session.awaiting_code === true };
  },
  // --- conversations ---
  validateMessage(text) {
    const t = (text || "").trim();
    if (!t) return "Write a message.";
    if (t.length > AIB_MAX_MESSAGE) return `A message is limited to ${AIB_MAX_MESSAGE} characters.`;
    return "";
  },
  convBusy: conv => !!conv && (conv.status === "running" || !!conv.pending),
  // A message can be sent when Claude is usable, nothing is in flight for this conversation, and its budget and length allow it.
  canSend({ conv, busy, canGenerate, text }) {
    if (!conv || busy || !canGenerate || AIBCore.convBusy(conv) || AIBCore.validateMessage(text)) return false;
    if (conv.budget && conv.budget.state === "exhausted") return false;
    return !(conv.limits && conv.messages && conv.messages.length >= conv.limits.max_turns);
  },
  money: v => (typeof v === "number" ? (v < 0.1 ? "$" + v.toFixed(4) : "$" + v.toFixed(2)) : "n/a"),
  num: v => (typeof v === "number" ? v.toLocaleString("en-US") : "n/a"),
  // The budget line, its level (ok / warn / bad) and the warning text. Costs are API-equivalent estimates, not charges.
  describeBudget(budget) {
    if (!budget) return { level: "ok", percent: 0, text: "", warning: "" };
    const text = `Estimated ${AIBCore.money(budget.spent_usd)} of ${AIBCore.money(budget.limit_usd)} (${budget.percent}%)`;
    if (budget.state === "exhausted") return { level: "bad", percent: Math.min(100, budget.percent), text, warning: "The conversation budget is used up. Start a new conversation to continue." };
    if (budget.state === "warning") return { level: "warn", percent: budget.percent, text, warning: `${budget.warn_at_percent}% of the conversation budget is used (estimated cost). The conversation stops at 100%.` };
    return { level: "ok", percent: budget.percent, text, warning: "" };
  },
  describeContext(ctx) {
    if (!ctx || ctx.last_tokens == null) return { text: "", warning: "" };
    const text = `Context ≈ ${AIBCore.num(ctx.last_tokens)} tokens`;
    return { text, warning: ctx.warning ? "The context is large, so each message costs more. Consider starting a new conversation." : "" };
  },
  // One line under a reply: model, tokens, estimated cost, duration. Missing metrics read "n/a", never an error.
  turnMeta(turn) {
    const u = turn && turn.usage;
    const parts = [turn && turn.model ? turn.model : "model n/a"];
    if (u) parts.push(`in ${AIBCore.num(u.input_tokens)}`, `out ${AIBCore.num(u.output_tokens)}`, `cache read ${AIBCore.num(u.cache_read_input_tokens)}`, `cache write ${AIBCore.num(u.cache_creation_input_tokens)}`);
    else parts.push("tokens n/a");
    parts.push("est. " + AIBCore.money(turn ? turn.cost_usd : null));
    if (turn && typeof turn.seconds === "number") parts.push(turn.seconds + " s");
    if (turn && Array.isArray(turn.changed) && turn.changed.length) parts.push("changed " + turn.changed.join(", "));
    return parts.join(" · ");
  },
  modelLabel: m => (m ? String(m).charAt(0).toUpperCase() + String(m).slice(1) : ""),
  moneyShort: v => (typeof v === "number" ? "$" + v.toFixed(v < 1 ? 3 : 2) : "n/a"),
  // Under a reply by default: "Sonnet · 15.7s · est. $0.053" (only what is known). The full figures are in turnDetails, behind a disclosure.
  turnSummary(turn) {
    const parts = [];
    if (turn && turn.model) parts.push(AIBCore.modelLabel(turn.model));
    if (turn && typeof turn.seconds === "number") parts.push(turn.seconds + "s");
    if (turn && typeof turn.cost_usd === "number") parts.push("est. " + AIBCore.moneyShort(turn.cost_usd));
    return parts.join(" · ");
  },
  turnDetails(turn) {
    const u = (turn && turn.usage) || {};
    return [["Model", (turn && turn.model) || "n/a"], ["Input tokens", AIBCore.num(u.input_tokens)], ["Output tokens", AIBCore.num(u.output_tokens)],
      ["Cache read tokens", AIBCore.num(u.cache_read_input_tokens)], ["Cache creation tokens", AIBCore.num(u.cache_creation_input_tokens)],
      ["Estimated cost", AIBCore.money(turn ? turn.cost_usd : null)], ["Duration", turn && typeof turn.seconds === "number" ? turn.seconds + " s" : "n/a"]];
  },
  // What the conversation is doing to its Lab, from backend state only: editing (an edit message is running), unpublished changes
  // (the working copy differs from the published Lab), otherwise read-only. No Lab: no state.
  describeLabState(conv) {
    if (!conv || !conv.lab) return null;
    if (AIBCore.convBusy(conv) && conv.pending && conv.pending.edit) return { kind: "editing", text: "Editing", title: "Claude is making changes in the working copy" };
    const wl = conv.workspaces && conv.workspaces.length > 1 ? conv.workspaces : [conv.workspace];
    const ws = wl.find(w => w && w.exists && w.changes && w.changes.total > 0) || conv.workspace;
    if (ws && ws.exists && ws.changes && ws.changes.total > 0) return { kind: "unpublished", text: "Unpublished changes", title: "The working copy has changes that are not published to the Lab" };
    return { kind: "readonly", text: "Read-only", title: "No changes in the working copy: the published Lab is untouched" };
  },
  // --- editing a Lab inside a conversation ---
  // The pending-changes bar: shown while the working copy differs from the published Lab (or the last change can still be undone).
  describeChanges(ws) {
    const none = { show: false, text: "", conflict: false };
    if (!ws || !ws.exists || !ws.changes) return none;
    const c = ws.changes, total = c.total || 0;
    if (!total && !ws.can_undo) return none;
    const parts = [c.modified && `${c.modified} modified`, c.added && `${c.added} added`, c.deleted && `${c.deleted} deleted`].filter(Boolean);
    return { show: true, conflict: !!ws.conflict && total > 0,
      text: total ? `${total} file${total === 1 ? "" : "s"} changed in the working copy (${parts.join(", ")}) · not published` : "No pending changes (the last change can still be undone)." };
  },
  changeTag: change => ({ modified: "~", added: "+", deleted: "−" }[change] || "?"),
  // Publishing needs a review that says it can be published, the user's explicit confirmation, and no call in flight.
  canPublishChanges: ({ review, confirmed, busy }) => !!review && review.can_publish === true && !!confirmed && !busy,
  // Lines of a unified diff with the class that colors them (file headers "meta", hunk headers "hunk", context lines none).
  diffLines: text => String(text || "").replace(/\n$/, "").split("\n").map(l => ({
    cls: l.startsWith("+++") || l.startsWith("---") ? "meta" : l.startsWith("@@") ? "hunk" : l.startsWith("+") ? "add" : l.startsWith("-") ? "del" : "", text: l })),
  // --- the docked panel ---
  // Width of the panel for a requested width: at least AIB_PANEL_MIN, at most 90% of <main> (the viewport), and always leaving
  // AIB_TERMINAL_MIN pixels to the terminal area (<main> minus the sidebar). Unknown or absurd values fall back to the default.
  clampPanelWidth(width, mainWidth, sidebarWidth) {
    const w = Number.isFinite(width) ? width : AIB_PANEL_DEFAULT;
    const room = mainWidth > 0 ? Math.max(AIB_PANEL_MIN, Math.min(Math.floor(mainWidth * AIB_PANEL_FRACTION), mainWidth - (sidebarWidth || 0) - AIB_TERMINAL_MIN)) : AIB_PANEL_MAX;
    return Math.round(Math.max(AIB_PANEL_MIN, Math.min(room, w)));
  },
  // The panel is docked on the right: its width is the distance from the pointer to the right edge of <main>.
  panelWidthFromPointer: (clientX, mainRight) => mainRight - clientX,
  // Is the message list scrolled to (nearly) the bottom? Unknown geometry counts as "yes" so that nothing is ever stuck.
  isNearBottom: box => !(box.scrollHeight - box.scrollTop - box.clientHeight >= 80),
  composerHeight: scrollHeight => Math.round(Math.max(40, Math.min(180, scrollHeight + 2))),
  // What the status line says. Every state comes from something the backend or the browser really reports (a request in flight, the
  // conversation's `pending` record, the last reply's status): there are no progress percentages and no guessed sub-steps.
  describeActivity({ conv, ops = {}, sending, canGenerate, reason, now }) {
    const lab = conv && conv.lab;
    if (ops.publish) return { kind: "busy", busy: true, text: `Publishing to usecases/${lab || "…"}…` };
    if (ops.review) return { kind: "busy", busy: true, text: "Validating the changes and preparing the review…" };
    if (ops.undo) return { kind: "busy", busy: true, text: "Undoing the last change…" };
    if (ops.reset) return { kind: "busy", busy: true, text: "Resetting the working copy…" };
    if (ops.discard) return { kind: "busy", busy: true, text: "Starting over from the published Lab…" };
    if (sending) return { kind: "busy", busy: true, text: "Sending your message…" };
    if (conv && AIBCore.convBusy(conv)) {
      const p = conv.pending || {}, since = p.started ? AIBCore.elapsed(p.started, now) : "";
      return { kind: "busy", busy: true, text: (p.edit ? "Claude is working on your request (editing is enabled for this message)" : "Claude is thinking") + (since ? ` · ${since}` : "") + "…" };
    }
    const last = conv && conv.messages && conv.messages[conv.messages.length - 1];
    if (last && last.status === "error") return { kind: "error", busy: false, text: `The last reply failed: ${String(last.error || "unknown error").slice(0, 140)}` };
    if (!canGenerate) return { kind: "offline", busy: false, text: "Claude is not available right now" + (reason ? `: ${reason}` : " (see the status above).") };
    return { kind: "ready", busy: false, text: conv ? "Ready · waiting for your message" : "Select a conversation or start a new one" };
  },
  elapsed(createdIso, nowMs) {
    const t = Date.parse(createdIso);
    if (!Number.isFinite(t)) return "";
    const s = Math.max(0, Math.floor((nowMs - t) / 1000));
    return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
  },
};
if (typeof module !== "undefined" && module.exports) module.exports = AIBCore;

// ---------------------------------------------------------------------------------------------------------------------
// DOM wiring (skipped under Node)
// ---------------------------------------------------------------------------------------------------------------------
if (typeof document !== "undefined") (function () {
  const $ = id => document.getElementById(id);
  const dlg = $("aib"), mainEl = $("app-main"), resizer = $("aib-resizer");
  if (!dlg) return;
  const S = { panelOpen: false, health: null, healthError: false, healthTimer: null, tick: null, notice: "",
    auth: null, authOpen: false, authBusy: false, authPollToken: 0, confirmDisconnect: false, authNote: "" };

  // --- the docked panel: open/close and the draggable width -------------------------------------------------------------------------
  // The panel is a third column of <main>. Only a CSS variable (--aib-w) changes: the terminal column shrinks by itself, its iframes are
  // resized in place and ttyd refits xterm.js on its own window resize, exactly as for the sidebar toggle and the split separators. This
  // code adds no resize handling for the terminals; its one window "resize" listener only keeps the panel's own width within limits.
  const widthStore = {
    get() { try { const n = Number(localStorage.getItem("aibPanelWidth")); return Number.isFinite(n) && n > 0 ? n : null; } catch (_) { return null; } },
    set(v) { try { localStorage.setItem("aibPanelWidth", String(v)); } catch (_) { /* optional */ } },
  };
  const panelState = { width: widthStore.get() || AIB_PANEL_DEFAULT, drag: false };
  function applyWidth(width, remember) {
    const mw = mainEl.clientWidth || (mainEl.getBoundingClientRect ? mainEl.getBoundingClientRect().width : 0) || 0, sb = $("sidebar").offsetWidth || 0;
    const w = AIBCore.clampPanelWidth(width, mw, sb);
    panelState.width = w;
    mainEl.style.setProperty("--aib-w", w + "px");
    resizer.setAttribute("aria-valuenow", String(w));
    resizer.setAttribute("aria-valuemax", String(AIBCore.clampPanelWidth(1e6, mw, sb)));
    if (remember) widthStore.set(w);
    return w;
  }
  function setPanel(on) {
    S.panelOpen = on; dlg.hidden = !on; resizer.hidden = !on;
    mainEl.classList.toggle("aib-open", on);
    $("aib-open").setAttribute("aria-expanded", String(on));
    $("aib-open").title = on ? "Close the AI Lab Assistant" : "Open the AI Lab Assistant";
    if (on) applyWidth(panelState.width, false);
  }
  resizer.onpointerdown = e => {
    if (e.button > 0) return;
    e.preventDefault();
    if (resizer.setPointerCapture) { try { resizer.setPointerCapture(e.pointerId); } catch (_) { /* a pointer that is not active: the drag still works */ } }
    panelState.drag = true; mainEl.classList.add("aib-dragging");                // the CSS makes the terminal iframes ignore the pointer meanwhile
  };
  resizer.onpointermove = e => {
    if (!panelState.drag) return;
    applyWidth(AIBCore.panelWidthFromPointer(e.clientX, mainEl.getBoundingClientRect().right), false);
  };
  const endDrag = e => {
    if (!panelState.drag) return;
    panelState.drag = false; mainEl.classList.remove("aib-dragging");
    if (resizer.releasePointerCapture && e && e.pointerId !== undefined) { try { resizer.releasePointerCapture(e.pointerId); } catch (_) { /* already released */ } }
    widthStore.set(panelState.width);
  };
  resizer.onpointerup = endDrag; resizer.onpointercancel = endDrag;
  resizer.ondblclick = () => applyWidth(AIB_PANEL_DEFAULT, true);
  resizer.onkeydown = e => {                                                      // keyboard: arrows move the divider, Home/End go to the limits
    const step = e.shiftKey ? 64 : 16;
    const next = { ArrowLeft: panelState.width + step, ArrowRight: panelState.width - step, Home: AIB_PANEL_MIN, End: 1e6 }[e.key];
    if (next === undefined) return;
    e.preventDefault(); applyWidth(next, true);
  };
  if (typeof window !== "undefined" && window.addEventListener) window.addEventListener("resize", () => { if (S.panelOpen) applyWidth(panelState.width, false); });

  // The only network function: relative URLs under /api/ai-builder, the CSRF header on every POST.
  async function call(method, path, body, timeoutMs = 15000) {
    const headers = {};
    if (method !== "GET") headers["X-Requested-With"] = "playground";             // every state-changing call (POST, DELETE)
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const r = await fetch(AIB_API + path, { method, headers, cache: "no-store", signal: AbortSignal.timeout(timeoutMs),
      body: body === undefined ? undefined : JSON.stringify(body) });
    let data = {};
    try { data = await r.json(); } catch (_) { /* non-JSON error page */ }
    return { ok: r.ok, status: r.status, data };
  }

  const show = (el, on) => { el.hidden = !on; };
  const setList = (ul, items) => { ul.replaceChildren(...items.map(t => { const li = document.createElement("li"); li.textContent = t; return li; })); show(ul, items.length > 0); };

  // --- availability -----------------------------------------------------------------------------------------------------
  async function refreshHealth() {
    try { const r = await call("GET", "/health", undefined, 8000); S.health = r.ok ? r.data : null; S.healthError = !r.ok; }
    catch (_) { S.health = null; S.healthError = true; }
    if (S.health && S.health.available) await refreshAuth(); else { S.auth = null; }
    renderHealth(); renderAuth();
    if (C.conv) { renderActivity(); renderComposer(); }   // the chat depends on S.canGenerate too: never leave it stale
  }
  function renderHealth() {
    const d = AIBCore.describeHealth(S.health, S.healthError, S.auth);
    S.needsConnect = !!d.needsConnect;
    const badge = $("aib-status");
    badge.textContent = d.badge; badge.className = "aib-badge " + d.level; badge.title = d.badge;
    $("aib-banner").textContent = d.banner; show($("aib-banner"), !!d.banner);
    S.canGenerate = d.canGenerate; S.reason = d.canGenerate ? "" : d.badge;
  }

  // --- Claude sign-in: the AI Builder runs `claude auth login` in a controlled PTY; this panel shows the official
  // sign-in address, takes the pasted code and follows the session. The code lives only in the input field: it is sent once, then the field is
  // cleared, and it is never kept in a variable, in localStorage or in the page.
  const sessionActive = () => !!(S.auth && S.auth.session && AIB_AUTH_ACTIVE.includes(S.auth.session.state));
  async function refreshAuth(force) {
    if (!force && Date.now() - (S.authAt || 0) < 25000) return;               // `claude auth status` starts a process: not on every tick
    S.authAt = Date.now();
    try {
      const r = await call("GET", "/auth/status", undefined, 30000);
      if (r.ok) { S.auth = r.data; if (sessionActive()) pollAuth(); }
    } catch (_) { /* keep the last known state */ }
  }
  async function pollAuth() {
    const token = ++S.authPollToken;                                          // a newer chain cancels this one
    while (token === S.authPollToken && S.panelOpen && sessionActive()) {
      await new Promise(res => setTimeout(res, 1500));
      if (token !== S.authPollToken || !S.panelOpen) return;
      try {
        const r = await call("GET", "/auth/status", undefined, 30000);
        if (token !== S.authPollToken) return;
        if (r.ok) S.auth = r.data;
      } catch (_) { /* transient: keep polling until the session ends or the time runs out */ }
      renderAuth();
    }
    if (token === S.authPollToken && S.auth && S.auth.session && S.auth.session.state === "succeeded") { S.authAt = 0; await refreshHealth(); }
    renderAuth();
  }
  function renderAuth() {
    const session = S.auth && S.auth.session, d = AIBCore.describeSession(session);
    const available = !!(S.health && S.health.available);
    const enabled = !(S.auth && S.auth.enabled === false);                  // false in host mode: no browser sign-in there
    const succeeded = !!session && session.state === "succeeded";
    const ready = available && S.health.state === "ready" && !S.needsConnect && S.health.claude_credentials_present !== false;
    show($("aib-connect"), available && enabled && S.needsConnect && !d.active && !S.authOpen && S.health.claude_available !== false);
    show($("aib-disconnect"), enabled && ready && !d.active);
    $("aib-disconnect").disabled = S.authBusy;
    $("aib-disconnect").textContent = S.confirmDisconnect ? "Confirm disconnect" : "Disconnect";
    const showSection = S.authOpen || d.active;
    show($("aib-auth"), showSection);
    if (!showSection) return;
    show($("aib-auth-start"), !d.active && !succeeded);                      // method and e-mail, until a sign-in is running or done
    show($("aib-auth-session"), !!session);
    $("aib-auth-text").textContent = d.text;
    $("aib-auth-text").className = "aib-auth-text" + (d.error ? " bad" : succeeded ? " ok" : "");
    // Local and request errors have their own lines: the poller redraws the session text every 1.5 s and must not erase them.
    $("aib-auth-error").textContent = session ? S.authNote : ""; show($("aib-auth-error"), !!session && !!S.authNote);
    $("aib-auth-starterror").textContent = session ? "" : S.authNote; show($("aib-auth-starterror"), !session && !!S.authNote);
    show($("aib-auth-linkrow"), d.showLink);
    if (d.showLink) $("aib-auth-link").href = session.url;                   // only an allow-listed https Claude address (isAllowedLoginUrl)
    show($("aib-auth-coderow"), d.showCode || (!!session && session.state === "verifying"));
    $("aib-auth-code").disabled = $("aib-auth-submit").disabled = !d.showCode || S.authBusy;
    $("aib-auth-timer").textContent = d.active && session.seconds_left ? `Time left ${Math.floor(session.seconds_left / 60)}:${String(session.seconds_left % 60).padStart(2, "0")}` : "";
    show($("aib-auth-cancel"), d.active);
    $("aib-auth-begin").disabled = S.authBusy || d.active;
    $("aib-auth-begin").textContent = session && (session.state === "failed" || session.state === "cancelled") ? "Try again" : "Start sign-in";
    show($("aib-auth-dismiss"), !d.active);
  }
  async function authPost(path, body) {
    S.authBusy = true; renderAuth();
    try { return await call("POST", path, body, 60000); }
    catch (_) { return { ok: false, status: 0, data: { error: "The request did not complete. Check the AI Builder status and try again." } }; }
    finally { S.authBusy = false; }
  }
  async function beginSignIn() {
    if (S.authBusy || sessionActive()) return;
    const body = { method: $("aib-auth-method").value };
    const email = $("aib-auth-email").value.trim();
    if (email) body.email = email;
    S.authNote = "";
    const r = await authPost("/auth/login", body);
    if (r.ok) { S.auth = r.data; S.authOpen = true; pollAuth(); }
    else { S.authNote = AIBCore.formatError(r); S.auth = S.auth && { ...S.auth, session: null }; }
    renderAuth();
  }
  async function submitCode() {
    if (S.authBusy || !(S.auth && S.auth.session && S.auth.session.awaiting_code)) return;
    const input = $("aib-auth-code");
    const err = AIBCore.validateCode(input.value);
    if (err) { S.authNote = err; renderAuth(); return; }
    const payload = { code: input.value.trim() };
    input.value = "";                                                          // the field is cleared before the request leaves
    S.authNote = "";
    const r = await authPost("/auth/code", payload);
    payload.code = "";
    if (r.ok) { S.auth = r.data; pollAuth(); }
    else { S.authNote = AIBCore.formatError(r); }
    renderAuth();
  }
  async function cancelSignIn() {
    const r = await authPost("/auth/cancel");
    if (r.ok) S.auth = r.data;
    S.authPollToken++; renderAuth();
  }
  async function disconnect() {
    if (S.authBusy) return;
    if (!S.confirmDisconnect) {                                                // two clicks: nothing is signed out by accident
      S.confirmDisconnect = true; renderAuth();
      setTimeout(() => { S.confirmDisconnect = false; renderAuth(); }, 4000);
      return;
    }
    S.confirmDisconnect = false;
    const r = await authPost("/auth/logout");
    if (r.ok) { S.auth = r.data; S.authNote = "Disconnected from Claude."; S.authOpen = false; }
    else { S.authNote = AIBCore.formatError(r); S.authOpen = true; }
    S.authAt = 0; await refreshHealth();
    if (r.ok) { convError(""); convNote("Disconnected from Claude. Select “Connect to Claude” to sign in again."); } else { convNote(""); convError(S.authNote); }
  }
  async function copyLink() {
    const url = S.auth && S.auth.session && S.auth.session.url;
    if (!AIBCore.isAllowedLoginUrl(url || "")) return;
    try { await navigator.clipboard.writeText(url); $("aib-auth-copy").textContent = "Copied"; }
    catch (_) { $("aib-auth-copy").textContent = "Copy failed: select the link instead"; }
    setTimeout(() => { $("aib-auth-copy").textContent = "Copy link"; }, 2500);
  }

  function renderAll() { renderHealth(); renderAuth(); renderChat(); }

  // --- Conversations: read-only chats with Claude Code. The server keeps the conversation and Claude's own session;
  // this tab only lists, opens, sends a message and follows the reply. Replies, titles and errors go in through textContent.
  const C = { list: [], conv: null, pollToken: 0, sending: false, creating: false, stick: true, sig: "", shown: 0, forceScroll: false, filesCollapsed: false,
    review: null, reviewOpen: false, revFile: null, ops: { review: false, undo: false, reset: false, discard: false, publish: false, remove: false }, confirm: { reset: false, discard: false, del: false },
    revLab: null, hist: false, query: "", showArchived: false, menu: null, renaming: null, confirmDel: null, delInfo: null, dismissed: {} };
  const convStore = {
    get() { try { return localStorage.getItem("aibConv") || ""; } catch (_) { return ""; } },
    set(v) { try { v ? localStorage.setItem("aibConv", v) : localStorage.removeItem("aibConv"); } catch (_) { /* optional */ } },
  };
  function convError(msg) { $("aib-conv-error").textContent = msg || ""; show($("aib-conv-error"), !!msg); }
  function convNote(msg) { $("aib-conv-note").textContent = msg || ""; show($("aib-conv-note"), !!msg); }
  async function enterChat() {
    renderChat();
    await refreshConvList();
    if (C.conv) await openConv(C.conv.id);                                       // coming back: refresh it (and resume following a running reply)
    else { const saved = convStore.get(); if (saved && C.list.some(c => c.id === saved)) await openConv(saved); }
    renderChat();
  }
  async function refreshConvList() {
    try {
      const r = await call("GET", "/conversations", undefined, 12000);
      if (r.ok && Array.isArray(r.data.conversations)) { C.list = r.data.conversations; convError(""); }
      else convError(AIBCore.formatError(r));
    } catch (_) { convError("The Playground API did not answer."); }
    renderConvSelect();
  }
  // --- conversation history (P3.1d): an overlay in the narrow panel, a left sidebar when the panel is wide; titles only, newest activity first ---
  const narrow = () => ($("aib-chat-pane").clientWidth || 0) < 640;
  function histRow(c) {
    const li = el("li", "aib-hist-item" + (C.conv && C.conv.id === c.id ? " active" : "") + (c.archived ? " archived" : ""));
    if (C.renaming === c.id) {
      const inp = el("input", "aib-hist-rename"); inp.type = "text"; inp.maxLength = 80; inp.value = c.title || ""; inp.setAttribute("aria-label", "Conversation title");
      inp.onkeydown = e => { if (e.key === "Enter") { e.preventDefault(); renameConv(c.id, inp.value); } };    // Escape: the document handler cancels it
      li.appendChild(inp);
      if (C.renameError) li.appendChild(el("p", "aib-hist-err", C.renameError));
      if (!C.renameFocused) { C.renameFocused = true; setTimeout(() => focusEl(inp), 0); }
      return li;
    }
    const open = el("button", "aib-hist-open", c.title || "(untitled)"); open.type = "button"; open.title = c.title || "";
    open.onclick = () => { C.menu = null; C.hist = false; openConv(c.id); };
    const more = el("button", "aib-hist-more", "…"); more.type = "button"; more.setAttribute("aria-label", "Conversation options"); more.setAttribute("aria-expanded", String(C.menu === c.id));
    more.onclick = () => { C.menu = C.menu === c.id ? null : c.id; renderConvSelect(); };
    li.append(open, more);
    if (C.menu === c.id) more.dataset.menu = "1";                                // the menu itself is placed outside the scrolling list (placeMenu)
    if (C.confirmDel === c.id) {
      const box = el("div", "aib-hist-confirm");
      const n = C.delInfo ? C.delInfo.pending : 0;
      box.appendChild(el("p", "", "Delete this conversation permanently? Its Claude session and working copy are removed. Published Labs are never deleted."));
      if (n > 0) box.appendChild(el("p", "aib-hist-warn", `Warning: ${n} unpublished change${n === 1 ? "" : "s"} in its working copy will be lost.`));
      const yes = el("button", "small danger", "Delete"); yes.type = "button"; yes.onclick = () => deleteConv(c.id);
      const no = el("button", "small", "Cancel"); no.type = "button"; no.onclick = () => { C.confirmDel = null; C.delInfo = null; renderConvSelect(); };
      box.append(yes, no); li.appendChild(box);
    }
    return li;
  }
  function renderConvSelect() {
    const title = C.conv ? (C.conv.title || "(untitled)") : "Select or start a conversation";
    $("aib-conv-title").textContent = title; $("aib-conv-title").title = title;
    $("aib-hist-toggle").setAttribute("aria-expanded", String(C.hist)); show($("aib-hist"), C.hist);
    $("aib-chat-pane").classList.toggle("hist-open", C.hist);
    if (!C.hist) return;
    const q = C.query.trim().toLowerCase();
    const rows = C.list.filter(c => (C.showArchived || !c.archived) && (!q || (c.title || "(untitled)").toLowerCase().includes(q)));
    const nodes = rows.map(histRow);
    $("aib-hist-list").replaceChildren(...(nodes.length ? nodes : [el("li", "aib-hint", q ? "No conversation matches." : "No conversations yet.")]));
    placeMenu(rows);
  }
  // The "…" menu lives in #aib-hist-pop, a sibling of the list: the list scrolls (overflow: auto), which clipped a menu placed inside a row.
  // It is positioned from the button's geometry: right-aligned to it, inside the panel, above the button when there is no room below.
  function placeMenu(rows) {
    const pop = $("aib-hist-pop"), c = C.menu && rows.find(r => r.id === C.menu);
    if (!c) { pop.replaceChildren(); return; }
    const menu = el("div", "aib-hist-menu"), item = (text, fn, cls) => { const b = el("button", cls || "", text); b.type = "button"; b.onclick = fn; return b; };
    menu.append(item("Rename", () => { C.renaming = c.id; C.renameError = ""; C.renameFocused = false; C.menu = null; renderConvSelect(); }),
      item(c.archived ? "Restore" : "Archive", () => archiveConv(c.id, !c.archived)),
      item("Delete…", () => askDelete(c.id), "danger"));
    pop.replaceChildren(menu);
    const btn = $("aib-hist-list").children.map(li => li.children && li.children[1]).find(b => b && b.dataset && b.dataset.menu);
    if (!btn || !btn.getBoundingClientRect) return;
    const hist = $("aib-hist").getBoundingClientRect(), b = btn.getBoundingClientRect(), pane = $("aib-chat-pane").getBoundingClientRect();
    const w = menu.offsetWidth || 130, h = menu.offsetHeight || 104;
    const below = (pane.bottom || 1e9) - b.bottom, top = below >= h + 6 || b.top - (pane.top || 0) < h + 6 ? b.bottom - hist.top + 2 : b.top - hist.top - h - 2;
    menu.style.setProperty("top", Math.max(0, top) + "px"); menu.style.setProperty("left", Math.max(0, Math.min(b.right - hist.left - w, (hist.width || w + 8) - w - 4)) + "px");
  }
  async function renameConv(id, title) {
    title = (title || "").trim();
    const cur = C.list.find(c => c.id === id);
    if (!title || (cur && cur.title === title)) { C.renaming = null; renderConvSelect(); return; }
    try {
      const r = await call("POST", `/conversations/${encodeURIComponent(id)}/meta`, { title }, 20000);
      if (!r.ok) { C.renameError = `Not renamed: ${AIBCore.formatError(r)}`; renderConvSelect(); return; }   // stay in the editor: Enter retries, Escape cancels
      C.renaming = null; C.renameError = ""; if (cur) cur.title = r.data.title; if (C.conv && C.conv.id === id) C.conv.title = r.data.title;
    } catch (_) { C.renameError = "Not renamed: the request did not complete."; renderConvSelect(); return; }
    renderConvSelect();
  }
  async function archiveConv(id, archived) {
    C.menu = null;
    try {
      const r = await call("POST", `/conversations/${encodeURIComponent(id)}/meta`, { archived }, 20000);
      if (!r.ok) convError(AIBCore.formatError(r)); else { convError(""); const cur = C.list.find(c => c.id === id); if (cur) cur.archived = archived; }
    } catch (_) { convError("The request did not complete. Check the conversation list, then try again."); }
    renderConvSelect();
  }
  async function askDelete(id) {                                                // confirmation first; the warning needs the workspace state
    C.menu = null; C.confirmDel = id; C.delInfo = null; renderConvSelect();
    try {
      const r = await call("GET", `/conversations/${encodeURIComponent(id)}`, undefined, 20000);
      const all = r.ok ? (r.data.workspaces && r.data.workspaces.length ? r.data.workspaces : [r.data.workspace]) : [];
      const pending = all.reduce((sum, w) => sum + (w && w.exists && w.changes ? w.changes.total : 0), 0);
      if (C.confirmDel === id) { C.delInfo = { pending }; renderConvSelect(); }
    } catch (_) { /* the confirmation is shown without the count */ }
  }
  // --- pending changes of a Lab conversation: review, undo, reset, start over, publish ---------------------------------
  const anyOp = () => Object.values(C.ops).some(Boolean);
  function closeChangeReview() { C.reviewOpen = false; C.review = null; C.revFile = null; $("aib-cr-confirm").checked = false; }
  // Several Labs can each have a working copy (P3.2b): the bar shows one at a time, chosen in a small selector; one Lab only: nothing changes.
  const wsList = conv => (conv && Array.isArray(conv.workspaces) ? conv.workspaces : []);
  const multiWs = () => wsList(C.conv).length > 1;
  const curWs = conv => { const l = wsList(conv); return l.length < 2 ? (conv && conv.workspace) : (l.find(w => w.lab === C.revLab) || l.find(w => w.changes.total > 0) || l[0]); };
  // Review, undo, reset, discard, publish: the usual routes for one Lab, the per-Lab route when there are several.
  const labPath = (op, ws) => (multiWs() ? { path: `/conversations/${encodeURIComponent(C.conv.id)}/lab`, method: "POST", body: { lab: ws.lab, action: op } }
    : { path: `/conversations/${encodeURIComponent(C.conv.id)}/${op}`, method: op === "review" ? "GET" : "POST", body: undefined });
  function renderChanges() {
    const ws = curWs(C.conv), d = AIBCore.describeChanges(ws);
    const lsel = $("aib-changes-lab"), many = multiWs();
    show(lsel, many && d.show);
    if (many) { lsel.replaceChildren(...wsList(C.conv).map(w => new Option(`${w.lab} (${w.changes.total})`, w.lab))); lsel.value = ws.lab; C.revLab = ws.lab; }
    show($("aib-changes"), d.show);
    if (!d.show) {                                                             // nothing pending: also reset what the bar contains
      if (C.reviewOpen) closeChangeReview();
      show($("aib-cr"), false); show($("aib-changes-conflict"), false);
      return;
    }
    const busy = AIBCore.convBusy(C.conv) || anyOp();
    $("aib-changes-text").textContent = d.text;
    $("aib-changes-review").disabled = busy || !ws.changes.total;
    $("aib-changes-review").textContent = C.reviewOpen ? "Hide changes" : "Review changes";
    $("aib-changes-review").setAttribute("aria-expanded", String(C.reviewOpen));
    $("aib-changes-undo").disabled = busy || !ws.can_undo;
    $("aib-changes-reset").disabled = busy; $("aib-changes-reset").textContent = C.confirm.reset ? "Confirm reset?" : "Reset";
    show($("aib-changes-conflict"), d.conflict);
    $("aib-changes-discard").disabled = busy; $("aib-changes-discard").textContent = C.confirm.discard ? "Confirm: start over" : "Start over from the published Lab";
    renderChangeReview();
  }
  // The diff of one file: a colored line per diff line, the content of added/removed/context lines highlighted by the file's language.
  function diffNodes(file) {
    if (!file) return [];
    const lang = typeof AIBHighlight !== "undefined" ? AIBHighlight.langFor(file.path) : "text";
    const span = (cls, text) => { const s = document.createElement("span"); if (cls) s.className = cls; s.textContent = text; return s; };
    const nodes = AIBCore.diffLines(file.diff).map(l => {
      const row = span("aib-dl" + (l.cls ? " " + l.cls : ""), "");
      if (l.cls === "add" || l.cls === "del") {
        row.appendChild(span("mk", l.text[0]));
        for (const t of lang === "text" ? [{ cls: "", text: l.text.slice(1) }] : AIBHighlight.line(lang, l.text.slice(1))) row.appendChild(t.cls ? span("tk-" + t.cls, t.text) : span("", t.text));
      } else row.appendChild(span("", l.text));
      row.appendChild(span("", "\n"));
      return row;
    });
    if (file.truncated) nodes.push(span("aib-dl meta", "… (the diff is shortened)\n"));
    return nodes;
  }
  function renderChangeReview() {
    const r = C.review, open = C.reviewOpen && !!r;
    show($("aib-cr"), open);
    if (!open) return;
    const sel = r.diff.find(f => f.path === C.revFile) || r.diff[0];
    C.revFile = sel ? sel.path : null;
    $("aib-cr-files").replaceChildren(...r.diff.map(f => {
      const li = document.createElement("li"), b = document.createElement("button");
      b.type = "button"; b.className = (f.path === C.revFile ? "active " : "") + "chg-" + f.change; b.textContent = `${AIBCore.changeTag(f.change)} ${f.path}`;
      b.onclick = () => { C.revFile = f.path; renderChangeReview(); };
      li.appendChild(b); return li;
    }));
    show($("aib-cr-files"), !C.filesCollapsed);
    $("aib-cr-files-toggle").textContent = `Files (${r.diff.length})`;
    $("aib-cr-files-toggle").setAttribute("aria-expanded", String(!C.filesCollapsed));
    $("aib-cr-diff").replaceChildren(...diffNodes(sel));
    $("aib-cr-validation").className = "aib-validation " + (r.validation.passed ? "ok" : "bad");
    $("aib-cr-validation").textContent = r.validation.passed ? "✓ Validation passed: the Lab is structurally valid." : "✕ Validation failed: fix these problems before publishing.";
    setList($("aib-cr-errors"), r.validation.passed ? [] : r.validation.errors);
    $("aib-cr-confirm-text").textContent = `I reviewed these changes and approve publishing them to usecases/${r.lab}.`;
    $("aib-cr-note").textContent = r.conflict ? "The published Lab changed: use “Start over from the published Lab”." : !r.total ? "Nothing to publish." : "";
    $("aib-cr-publish").disabled = !AIBCore.canPublishChanges({ review: r, confirmed: $("aib-cr-confirm").checked, busy: C.ops.publish });
    $("aib-cr-publish").textContent = C.ops.publish ? "Publishing…" : "Publish";
  }
  function crResult(msg, ok) { const el = $("aib-cr-result"); el.textContent = msg || ""; el.className = "aib-result " + (ok ? "ok" : "bad"); show(el, !!msg); }
  async function openChangeReview() {
    if (anyOp() || !C.conv) return;
    if (C.reviewOpen) { closeChangeReview(); renderChat(); return; }               // the same button hides the review again
    C.ops.review = true; renderChat(); crResult("");
    try {
      const lp = labPath("review", curWs(C.conv));
      const r = await call(lp.method, lp.path, lp.body, 45000);
      if (!r.ok) { convError(AIBCore.formatError(r)); return; }
      C.review = r.data; C.reviewOpen = true; C.revFile = null; $("aib-cr-confirm").checked = false; convError("");
    } catch (_) { convError("The review did not complete. Try again."); }
    finally { C.ops.review = false; renderChat(); }
  }
  async function changeAction(op) {                                            // undo | reset | discard
    if (anyOp() || !C.conv) return;
    C.ops[op] = true; renderChat(); crResult("");
    const id = C.conv.id, lp = labPath(op, curWs(C.conv));
    try {
      const r = await call("POST", lp.path, lp.body, 40000);
      if (!r.ok) { convError(AIBCore.formatError(r)); return; }
      closeChangeReview(); C.conv = r.data; convError("");
      crResult({ undo: "Undone: the working copy is back to the state before the last change.", reset: "Reset: the working copy is the original Lab again.",
        discard: "Started over: the next change begins from the published Lab." }[op], true);
      await refreshConvList();
    } catch (_) { convError("The request did not complete. Reopen the conversation to see its state."); }
    finally { C.ops[op] = false; C.confirm[op] = false; renderChat(); }
  }
  function confirmThen(op) {                                                   // the destructive actions take two clicks
    if (C.confirm[op]) { changeAction(op); return; }
    C.confirm[op] = true; renderChanges();
    setTimeout(() => { C.confirm[op] = false; renderChanges(); }, 4000);
  }
  async function publishChanges() {
    if (C.ops.publish || !C.conv || !AIBCore.canPublishChanges({ review: C.review, confirmed: $("aib-cr-confirm").checked, busy: false })) return;
    C.ops.publish = true; renderChat();                                        // synchronous lock before any await
    const id = C.conv.id, lp = labPath("publish", curWs(C.conv));
    try {
      const r = await call("POST", lp.path, { ...(lp.body || {}), approve: true, tree_hash: C.review.tree_hash }, 100000);
      if (r.ok) {
        closeChangeReview(); C.conv = r.data.conversation; convError("");
        const gone = r.data.changes && r.data.changes.deleted > 0;       // removed files change the Lab definition only: a running environment is not touched
        crResult(`Published as ${r.data.published}. Start it from the sidebar, or run: ${r.data.run}` + (gone ? " Files were removed from the Lab; an environment that is already running is not changed: stop and start it to use this version." : ""), true);
        if (typeof refreshUseCases === "function") refreshUseCases();
        if (typeof refreshTerminals === "function") refreshTerminals();
        await refreshConvList();
        return;
      }
      if (r.status === 409) await openConv(id);                                // show the real state (e.g. a conflict), then the reason
      convError(`Publish refused: ${AIBCore.formatError(r)}`);
    } catch (_) {
      await openConv(id);                                                      // the outcome is unknown: ask the server
      convError("The publish request did not complete. Check the Lab and the changes, then try again.");
    } finally { C.ops.publish = false; renderChat(); }
  }

  // --- delete the open conversation: two clicks (the second within 4 s), refused by the server while Claude is answering in it ----------
  async function deleteConv(id) {
    if (anyOp() || (C.conv && C.conv.id === id && AIBCore.convBusy(C.conv))) { convError("Wait for the reply to finish before deleting this conversation."); return; }
    C.confirmDel = null; C.delInfo = null;
    C.ops.remove = true; C.confirm.del = false; convNote(""); renderChat();    // synchronous lock before any await
    try {
      const r = await call("DELETE", `/conversations/${encodeURIComponent(id)}`, undefined, 30000);
      if (r.ok || r.status === 404) {                                          // 404: already gone (another tab): the same end state
        C.pollToken++; closeChangeReview(); crResult("");
        C.list = C.list.filter(c => c.id !== id);
        if (C.conv && C.conv.id === id) { C.conv = null; C.sig = ""; convStore.set(""); }   // the active conversation is gone: the empty state
        renderChanges();                                                       // no conversation: hide its changes bar and review as well
        convError(""); convNote("Conversation deleted."); renderConvSelect();
        await refreshConvList();
      } else {
        if (r.status === 409 && C.conv && C.conv.id === id) await openConv(id);   // e.g. it is answering: show its real state, then the reason
        convError(AIBCore.formatError(r));
      }
    } catch (_) { convError("The request did not complete. Check the conversation list, then try again."); }
    finally { C.ops.remove = false; renderChat(); }
  }
  async function openConv(id) {
    C.pollToken++; closeChangeReview(); C.confirm.del = false; convNote("");
    if (!id) { C.conv = null; convStore.set(""); renderChat(); return; }
    try {
      const r = await call("GET", `/conversations/${encodeURIComponent(id)}`, undefined, 20000);
      if (r.ok) { C.conv = r.data; convStore.set(id); convError(""); }
      else { convError(AIBCore.formatError(r)); if (r.status === 404) { C.conv = null; convStore.set(""); } }
    } catch (_) { convError("The Playground API did not answer."); }
    renderConvSelect(); renderChat();
    if (AIBCore.convBusy(C.conv)) pollConv();
  }
  async function pollConv() {
    const token = ++C.pollToken;                                               // a newer chain (or another conversation) cancels this one
    const id = C.conv && C.conv.id;
    let failures = 0;
    while (token === C.pollToken && S.panelOpen && C.conv && C.conv.id === id && AIBCore.convBusy(C.conv)) {
      await new Promise(res => setTimeout(res, Math.min(2000 * (failures + 1), 10000)));
      if (token !== C.pollToken || !S.panelOpen) return;
      try {
        const r = await call("GET", `/conversations/${encodeURIComponent(id)}`, undefined, 20000);
        if (token !== C.pollToken) return;
        if (!r.ok) throw new Error("poll");
        failures = 0; C.conv = r.data; convError("");
      } catch (_) { failures++; convError("The AI Builder cannot be reached. Retrying…"); }
      renderChat();
    }
    if (token === C.pollToken) await refreshConvList();
  }
  async function createConv() {
    if (C.creating) return;
    C.creating = true; $("aib-conv-new").disabled = true;                      // synchronous lock before any await
    try {
      const r = await call("POST", "/conversations", {}, 20000);               // no Lab: a Lab is named in the conversation itself
      if (!r.ok) { convError(AIBCore.formatError(r)); return; }
      C.conv = r.data; convStore.set(r.data.id); convError(""); C.hist = false; C.sig = "";
      await refreshConvList(); focusEl($("aib-conv-input"));
    } catch (_) { convError("The request did not complete. Check the conversation list, then try again."); }
    finally { C.creating = false; renderChat(); }
  }
  async function sendMessage(ev, override) {
    if (ev) ev.preventDefault();
    const text = override !== undefined ? override : $("aib-conv-input").value;
    if (C.sending || !AIBCore.canSend({ conv: C.conv, busy: C.sending, canGenerate: S.canGenerate, text })) return;
    C.sending = true; renderChat();                                            // synchronous lock before any await
    const id = C.conv.id;
    try {
      const r = await call("POST", `/conversations/${encodeURIComponent(id)}/messages`, { message: text.trim() }, 30000);
      if (!r.ok) {
        if (r.status === 409) await openConv(id);                              // e.g. another tab is already waiting for a reply: show the real state first
        convError(AIBCore.formatError(r));                                     // then the reason (reloading clears errors)
        return;
      }
      if (override === undefined) { $("aib-conv-input").value = ""; growComposer(); } convError(""); focusEl($("aib-conv-input"));   // cleared only once the server accepted the message; focus stays
      C.forceScroll = true;                                                    // your own message always scrolls into view
      if (C.conv && C.conv.id === id) { C.conv = r.data; pollConv(); }
    } catch (_) {
      convError("The message may not have been sent. Reopen the conversation to check.");
    } finally { C.sending = false; renderChat(); }
  }
  // A message. `markdown` renders Claude's reply as Markdown (built with DOM nodes only, see ai-markdown.js); everything else is plain text.
  // `turn` (assistant messages only) adds the compact usage line and, when the backend says this message changed files, the change card.
  function bubble(kind, text, turn, markdown) {
    const d = document.createElement("div"); d.className = "aib-msg " + kind;
    if (markdown && typeof AIBMarkdown !== "undefined") d.appendChild(AIBMarkdown.render(text, document, { copy: copyCode })); else d.textContent = text;
    if (turn && turn.edit && Array.isArray(turn.changed) && turn.changed.length) d.appendChild(changeCard(turn.changed));
    if (turn) d.appendChild(usageLine(turn));
    return d;
  }
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; };
  // "Sonnet · 15.7s · est. $0.053" and a small Details disclosure with every figure (usage tracking itself is unchanged).
  function usageLine(turn) {
    const wrap = el("span", "aib-msg-meta"), summary = AIBCore.turnSummary(turn);
    if (summary) wrap.appendChild(el("span", "aib-meta-line", summary));
    const tog = el("button", "aib-meta-toggle", "Details"), dl = el("dl", "aib-usage");
    tog.type = "button"; tog.title = AIBCore.turnMeta(turn); tog.setAttribute("aria-expanded", "false"); dl.hidden = true;
    for (const [k, v] of AIBCore.turnDetails(turn)) { const row = el("div"); row.appendChild(el("dt", "", k)); row.appendChild(el("dd", "", v)); dl.appendChild(row); }
    tog.onclick = () => { dl.hidden = !dl.hidden; tog.setAttribute("aria-expanded", String(!dl.hidden)); };
    wrap.appendChild(tog); wrap.appendChild(dl);
    return wrap;
  }
  // The files the backend recorded for THIS message (turn.changed). Their kind (added/modified/deleted) is only known for all pending changes
  // together, so it is shown in the review, not guessed here; nothing is read from Claude's text.
  // The Lab a card's files belong to: several working copies prefix the path with the Lab ("lab/README.md"); an unprefixed path is the Lab in focus.
  // The first of those Labs that still has pending changes is shown (the selector reaches the others); none left: undefined.
  function reviewTarget(files) {
    const l = wsList(C.conv);
    if (l.length < 2) return C.conv && C.conv.workspace;
    const names = new Set(l.map(w => w.lab)), labs = new Set(files.map(f => { const i = f.indexOf("/"); return i > 0 && names.has(f.slice(0, i)) ? f.slice(0, i) : C.conv.lab; }));
    const ws = l.find(w => labs.has(w.lab) && w.changes.total > 0);
    if (ws) C.revLab = ws.lab;
    return ws;
  }
  function changeCard(files) {
    const card = el("div", "aib-changecard"), head = el("div", "aib-changecard-head"), ul = el("ul");
    head.appendChild(el("span", "", `${files.length} file${files.length === 1 ? "" : "s"} changed`));
    const btn = el("button", "small", "Review changes"); btn.type = "button";
    btn.onclick = () => {
      const ws = reviewTarget(files);
      if (!ws || !ws.changes || !ws.changes.total) { crResult("These changes are no longer pending (undone, reset or published).", false); return; }
      if (C.reviewOpen) { const cr = $("aib-cr"); if (cr.scrollIntoView) cr.scrollIntoView({ block: "nearest" }); return; }
      openChangeReview();
    };
    head.appendChild(btn); card.appendChild(head);
    for (const f of files.slice(0, 6)) ul.appendChild(el("li", "", f));
    if (files.length > 6) ul.appendChild(el("li", "", `+ ${files.length - 6} more`));
    card.appendChild(ul); card.appendChild(el("p", "aib-changecard-note", "Touched by this message. The review shows all pending changes."));
    return card;
  }
  async function copyCode(text, button) {                                      // the Copy button of a code block
    let ok = false;
    try { if (typeof navigator !== "undefined" && navigator.clipboard && navigator.clipboard.writeText) { await navigator.clipboard.writeText(text); ok = true; } } catch (_) { /* fall back */ }
    if (!ok && document.body && document.execCommand) {
      const ta = document.createElement("textarea"); ta.value = text; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
      document.body.appendChild(ta); ta.select();
      try { ok = document.execCommand("copy"); } catch (_) { ok = false; }
      ta.remove();
    }
    button.textContent = ok ? "Copied" : "Copy failed"; button.classList.toggle("done", ok);
    setTimeout(() => { button.textContent = "Copy"; button.classList.toggle("done", false); }, 1800);
  }
  function growComposer() {                                                    // the textarea grows with its text, up to a limit
    const ta = $("aib-conv-input");
    if (typeof ta.scrollHeight !== "number" || !ta.style) return;
    ta.style.height = "auto"; ta.style.height = AIBCore.composerHeight(ta.scrollHeight) + "px";
  }
  function renderActivity() {
    const a = AIBCore.describeActivity({ conv: C.conv, ops: C.ops, sending: C.sending, canGenerate: S.canGenerate, reason: S.reason, now: Date.now() });
    $("aib-activity").className = "aib-activity " + a.kind;
    $("aib-activity-text").textContent = a.text;
    $("aib-conv-messages").setAttribute("aria-busy", String(a.busy));
  }
  function renderComposer() {                                                  // what depends on the text being typed (cheap: no message is rebuilt)
    const conv = C.conv, text = $("aib-conv-input").value;
    $("aib-conv-count").textContent = `${text.length} / 4000`;
    $("aib-conv-count").hidden = text.length < 3200;
    $("aib-conv-send").disabled = !AIBCore.canSend({ conv, busy: C.sending, canGenerate: S.canGenerate, text });
    const busy = AIBCore.convBusy(conv) || C.sending;
    $("aib-conv-send").textContent = C.sending ? "Sending…" : AIBCore.convBusy(conv) ? "Waiting…" : "Send";
    show($("aib-send-spinner"), busy);                                         // a compact spinner while a request or a reply is really in progress
    $("aib-conv-input").disabled = !S.canGenerate;                             // you can keep typing while Claude answers; Send stays off until it is done
    if (C.wasBusy && !busy && S.panelOpen && !$("aib-conv-input").disabled) {
      const ae = typeof document.activeElement !== "undefined" ? document.activeElement : null;
      if (!ae || ae === document.body || (dlg.contains && dlg.contains(ae))) focusEl($("aib-conv-input"));   // back to the composer, unless you went elsewhere
    }
    C.wasBusy = busy;
  }
  // The message list is rebuilt only when something in it changed, so a poll does not reset a text selection or a focused Copy button.
  function renderMessages(conv) {
    const last = conv.messages[conv.messages.length - 1];
    const sig = [conv.id, conv.messages.length, last ? last.status + (last.finished || "") : "", conv.pending ? conv.pending.user : "", conv.edit_approved ? "a" : "", conv.lab_active === false ? "i" : "", last && C.dismissed[`${conv.id}:${last.n}`] ? "d" : "", conv.delete_request ? `x:${conv.delete_request.lab}:${conv.delete_request.state}` : ""].join("|");
    const box = $("aib-conv-messages");
    if (sig === C.sig) return;
    const sameConv = C.sigConv === conv.id;
    const stick = C.forceScroll || !sameConv || C.stick, top = box.scrollTop;
    const nodes = [];
    for (const t of conv.messages) {
      nodes.push(bubble("user", t.user));
      if (t.status === "error") nodes.push(bubble("assistant error", t.error || "The reply failed.", t));
      else nodes.push(bubble("assistant", String(t.assistant || "").replace(/\s*\[\[context:[^\]]*\]\]/gi, "").trim(), t, true));   // internal context directives are never shown
    }
    if (last && !conv.pending && !C.dismissed[`${conv.id}:${last.n}`]
      && ((last.edit_request && !conv.edit_approved && conv.lab && conv.lab_active !== false) || last.create_request)) nodes.push(approvalCard(conv, last));
    if (last && !conv.pending && conv.delete_request && conv.delete_request.state === "ready") nodes.push(deleteCard(conv, conv.delete_request));
    if (conv.pending) { nodes.push(bubble("user", conv.pending.user)); nodes.push(bubble("assistant pending", conv.pending.edit ? "Working on your request…" : "Thinking…")); }
    box.replaceChildren(...nodes);
    C.sig = sig; C.sigConv = conv.id;
    if (stick) { box.scrollTop = box.scrollHeight; C.stick = true; show($("aib-scroll-bottom"), false); }
    else { box.scrollTop = top; if (nodes.length > C.shown) show($("aib-scroll-bottom"), true); }   // new content below what you are reading
    C.shown = nodes.length; C.forceScroll = false;
  }
  // --- inline approval of edits (P3.1d): shown under Claude's reply when it proposed changes; the backend enables nothing before this click ---
  async function approveEdit(labs) {                                            // `labs`: every Lab the card named (several Labs in focus), else the Lab in focus
    if (C.sending || anyOp() || !C.conv) return;
    const id = C.conv.id;
    try {
      const r = await call("POST", `/conversations/${encodeURIComponent(id)}/context`, { action: "allow_edit", ...(Array.isArray(labs) ? { labs } : {}) }, 30000);
      if (!r.ok) { convError(AIBCore.formatError(r)); return; }
      if (!C.conv || C.conv.id !== id) return;
      C.conv = r.data; convError(""); C.sig = ""; renderChat();
      await sendMessage(null, "Changes allowed: apply the changes you described.");
    } catch (_) { convError("The request did not complete. Reopen the conversation to see its state."); }
  }
  async function approveCreate(name) {                                           // the backend makes the empty working copy; Claude then writes the Lab there
    if (C.sending || anyOp() || !C.conv) return;
    const id = C.conv.id;
    try {
      const r = await call("POST", `/conversations/${encodeURIComponent(id)}/context`, { action: "create_lab", lab: name }, 30000);
      if (!r.ok) { convError(AIBCore.formatError(r)); return; }
      if (!C.conv || C.conv.id !== id) return;
      C.conv = r.data; convError(""); C.sig = ""; renderChat();
      await sendMessage(null, `Lab creation approved: create the Lab '${name}' now, based on our conversation.`);
    } catch (_) { convError("The request did not complete. Reopen the conversation to see its state."); }
  }
  function approvalCard(conv, turn) {
    const name = turn.create_request, creating = !!name;
    const card = el("div", "aib-approval"); card.setAttribute("role", "group"); card.setAttribute("aria-label", "Approval");
    const labs = Array.isArray(turn.edit_labs) ? turn.edit_labs : null;
    card.appendChild(el("span", "aib-approval-text", labs && labs.length > 1 ? `Allow Claude to change files of ${labs.join(", ")}? Each Lab gets its own working copy; the published Labs stay untouched and nothing is published without your review.` : creating ? `Create the new Lab '${name}' in an isolated working copy? Nothing is published without your review.`
      : `Allow Claude to change files in a working copy of ${conv.lab}? The published Lab stays untouched and nothing is published without your review.`));
    const yes = el("button", "primary small", creating ? "Create Lab" : "Allow changes"); yes.type = "button"; yes.onclick = creating ? () => approveCreate(name) : () => approveEdit(labs);
    const no = el("button", "small", "Cancel"); no.type = "button"; no.onclick = async () => {
      C.dismissed[`${conv.id}:${turn.n}`] = true; C.sig = ""; renderChat();             // hidden at once; the server remembers it so a reload does not bring it back
      try { const r = await call("POST", `/conversations/${encodeURIComponent(conv.id)}/context`, { action: "decline_edit" }, 20000); if (r.ok && C.conv && C.conv.id === conv.id) { C.conv = r.data; C.sig = ""; renderChat(); } } catch (_) { /* hidden locally anyway */ }
    };
    card.append(yes, no); return card;
  }

  // --- deleting a whole Lab (P4.3.2): Claude only asks; the server checks that the Lab is stopped (and says so in the conversation when it is not);
  // the card then needs the exact Lab name, and the backend verifies everything again. Editing approval has nothing to do with it. ---
  C.deleteChecked = C.deleteChecked || {};
  async function checkDelete(conv) {                                           // once per request: the verdict is recorded in the conversation
    const dr = conv.delete_request, key = `${conv.id}:${dr.lab}:${conv.messages.length}`;
    if (C.deleteChecked[key]) return;
    C.deleteChecked[key] = true;
    try {
      const r = await call("POST", `/conversations/${encodeURIComponent(conv.id)}/delete_check`, { lab: dr.lab }, 40000);
      if (!r.ok) { delete C.deleteChecked[key]; convError(AIBCore.formatError(r)); return; }
      if (C.conv && C.conv.id === conv.id) { C.conv = r.data; C.sig = ""; C.forceScroll = true; renderChat(); await refreshConvList(); }
    } catch (_) { delete C.deleteChecked[key]; convError("The check did not complete. Reopen the conversation to try again."); }
  }
  async function confirmDelete(card, dr, input, btn) {
    if (C.sending || anyOp() || !C.conv || input.value !== dr.lab) return;
    const id = C.conv.id; btn.disabled = true; input.disabled = true;
    try {
      const r = await call("POST", `/conversations/${encodeURIComponent(id)}/delete_lab`, { lab: dr.lab, confirm: input.value }, 100000);
      if (!r.ok) { convError(AIBCore.formatError(r)); input.disabled = false; btn.disabled = input.value !== dr.lab; return; }
      convError("");
      if (C.conv && C.conv.id === id) { closeChangeReview(); C.conv = r.data.conversation; C.sig = ""; C.forceScroll = true; renderChat(); }
      crResult(`The Lab ${dr.lab} was removed from the Playground. Its files are kept in ${r.data.trash}.`, true);
      if (typeof refreshUseCases === "function") refreshUseCases();
      await refreshConvList();
    } catch (_) { convError("The deletion did not complete. Reopen the conversation to see its state."); input.disabled = false; btn.disabled = input.value !== dr.lab; }
  }
  function deleteCard(conv, dr) {
    const card = el("div", "aib-approval aib-delete"); card.setAttribute("role", "group"); card.setAttribute("aria-label", "Delete a Lab");
    card.appendChild(el("strong", "aib-approval-text", `Delete the Lab ${dr.lab}${dr.title ? ` (${dr.title})` : ""}?`));
    card.appendChild(el("span", "aib-approval-text", `${dr.files} file${dr.files === 1 ? "" : "s"} will be removed from the active Playground. Nothing is emptied: the whole Lab directory is moved to usecases/.trash/ and can be restored by hand, but it will no longer be available here. Other conversations that mention this Lab will not be able to publish changes to it.`));
    const label = el("label", "aib-approval-text", `Type the Lab name (${dr.lab}) to confirm`), input = el("input"); input.type = "text"; input.autocomplete = "off"; input.spellcheck = false; input.maxLength = 60;
    input.setAttribute("aria-label", `Type ${dr.lab} to confirm the deletion`); label.appendChild(input);
    const yes = el("button", "small danger", "Delete Lab"); yes.type = "button"; yes.disabled = true;
    input.oninput = () => { yes.disabled = input.value !== dr.lab; };
    yes.onclick = () => confirmDelete(card, dr, input, yes);
    const no = el("button", "small", "Cancel"); no.type = "button"; no.onclick = async () => {
      try { const r = await call("POST", `/conversations/${encodeURIComponent(conv.id)}/context`, { action: "decline_delete" }, 20000); if (r.ok && C.conv && C.conv.id === conv.id) { C.conv = r.data; C.sig = ""; renderChat(); } else if (!r.ok) convError(AIBCore.formatError(r)); }
      catch (_) { convError("The request did not complete."); }
    };
    card.append(label, yes, no); return card;
  }

  function renderChat() {
    const conv = C.conv;
    show($("aib-conv"), !!conv);
    $("aib-conv-new").disabled = C.creating;
    if (!conv) return;
    const ls = AIBCore.describeLabState(conv), st = $("aib-conv-state");
    st.textContent = ls ? ls.text : ""; st.title = ls ? ls.title : ""; st.className = "aib-state" + (ls ? " " + ls.kind : ""); show(st, !!ls);
    const ctx = AIBCore.describeContext(conv.context);
    $("aib-conv-meta").textContent = [conv.lab ? "" : "No Lab", conv.model, `${conv.messages.length} message${conv.messages.length === 1 ? "" : "s"}`, ctx.text].filter(Boolean).join(" · ");
    const b = AIBCore.describeBudget(conv.budget);
    $("aib-conv-bar").value = b.percent; $("aib-conv-budget").textContent = b.text;
    $("aib-budget").className = "aib-budget " + b.level;
    const warning = [b.warning, ctx.warning].filter(Boolean).join(" ");
    $("aib-conv-warn").textContent = warning; show($("aib-conv-warn"), !!warning);
    $("aib-conv-input").placeholder = conv.can_edit ? "Ask a question, or ask for a change to the Lab…" : "Ask about a Lab, a scenario or the Playground…";
    renderChanges();
    renderMessages(conv);
    renderActivity();
    renderComposer();
    if (conv.delete_request && conv.delete_request.state == null && !conv.pending && conv.messages.length) checkDelete(conv);
  }

  // --- open / close / resume ------------------------------------------------------------------------------------------------------
  const focusEl = el => { if (el && typeof el.focus === "function") el.focus(); };
  async function open() {
    if (S.panelOpen) { focusEl($("aib-conv-input")); return; }
    setPanel(true);
    renderAll(); S.authAt = 0; refreshHealth();
    clearInterval(S.healthTimer); S.healthTimer = setInterval(() => S.panelOpen && refreshHealth(), 10000);
    clearInterval(S.tick); S.tick = setInterval(() => {                         // elapsed times of what is really running
      if (!S.panelOpen) return;
      if (C.conv && AIBCore.convBusy(C.conv)) renderActivity();
    }, 1000);
    await enterChat();                                                          // the conversation is the whole panel
    focusEl($("aib-conv-input").disabled ? $("aib-conv-new") : $("aib-conv-input"));
  }
  function closePanel() {                                                       // stops every poll of the panel; a conversation keeps running on the server
    S.authPollToken++; C.pollToken++; clearInterval(S.healthTimer); clearInterval(S.tick); $("aib-auth-code").value = "";
    if (panelState.drag) endDrag();
    setPanel(false); focusEl($("aib-open"));
  }
  $("aib-open").onclick = () => (S.panelOpen ? closePanel() : open());
  $("aib-connect").onclick = () => { S.authOpen = true; S.authNote = ""; renderAuth(); };
  $("aib-disconnect").onclick = disconnect;
  $("aib-auth-begin").onclick = beginSignIn;
  $("aib-auth-submit").onclick = submitCode;
  $("aib-auth-code").onkeydown = e => { if (e.key === "Enter") { e.preventDefault(); submitCode(); } };
  $("aib-auth-cancel").onclick = cancelSignIn;
  $("aib-auth-copy").onclick = copyLink;
  $("aib-auth-dismiss").onclick = () => { S.authOpen = false; S.authNote = ""; if (S.auth) S.auth = { ...S.auth, session: null }; renderAuth(); S.authAt = 0; refreshHealth(); };
  $("aib-close").onclick = closePanel;
  $("aib-conv-new").onclick = () => { convNote(""); createConv(); };
  // Outside click (capture phase: it runs before the click handlers re-render the list) and Escape close the layers one at a time.
  const closeHist = () => { C.hist = false; C.menu = null; C.renaming = null; C.confirmDel = null; C.renameError = ""; renderConvSelect(); };
  if (typeof document.addEventListener === "function") {
    document.addEventListener("click", e => {
      if (!C.hist) return;
      const t = e.target, within = sel => !!(t && typeof t.closest === "function" && t.closest(sel));
      if (within("#aib-hist-toggle")) return;                                   // the toggle has its own handler
      if (!within("#aib-hist")) { closeHist(); return; }
      if (C.menu && !within(".aib-hist-menu") && !within(".aib-hist-more")) { C.menu = null; renderConvSelect(); }
    }, true);
    document.addEventListener("keydown", e => {
      if (e.key !== "Escape" || !C.hist) return;
      if (C.renaming) { C.renaming = null; C.renameError = ""; renderConvSelect(); }
      else if (C.confirmDel) { C.confirmDel = null; C.delInfo = null; renderConvSelect(); }
      else if (C.menu) { C.menu = null; renderConvSelect(); }
      else { closeHist(); focusEl($("aib-hist-toggle")); }
    });
  }
  $("aib-changes-lab").onchange = () => { C.revLab = $("aib-changes-lab").value; closeChangeReview(); renderChanges(); };
  $("aib-hist-toggle").onclick = () => { C.hist = !C.hist; C.menu = null; C.renaming = null; C.confirmDel = null; renderConvSelect(); if (C.hist) focusEl($("aib-hist-search")); };
  $("aib-hist-search").oninput = () => { C.query = $("aib-hist-search").value; renderConvSelect(); };
  $("aib-hist-archived").onchange = () => { C.showArchived = $("aib-hist-archived").checked; renderConvSelect(); };
  $("aib-conv-send-form").onsubmit = sendMessage;
  $("aib-conv-input").oninput = () => { growComposer(); renderComposer(); };
  $("aib-conv-messages").onscroll = () => { const box = $("aib-conv-messages"); C.stick = AIBCore.isNearBottom(box); if (C.stick) show($("aib-scroll-bottom"), false); };
  $("aib-scroll-bottom").onclick = () => { const box = $("aib-conv-messages"); box.scrollTop = box.scrollHeight; C.stick = true; show($("aib-scroll-bottom"), false); focusEl($("aib-conv-input")); };
  $("aib-cr-files-toggle").onclick = () => { C.filesCollapsed = !C.filesCollapsed; renderChangeReview(); };
  $("aib-changes-review").onclick = openChangeReview;
  $("aib-changes-undo").onclick = () => changeAction("undo");
  $("aib-changes-reset").onclick = () => confirmThen("reset");
  $("aib-changes-discard").onclick = () => confirmThen("discard");
  $("aib-cr-confirm").onchange = renderChangeReview;
  $("aib-cr-publish").onclick = publishChanges;
  $("aib-conv-input").onkeydown = e => {                                          // Enter sends, Shift+Enter is a new line (never while an IME is composing)
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); sendMessage(e); }
  };
})();
