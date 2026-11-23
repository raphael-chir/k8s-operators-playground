// Host resource findings as compact cards, for the dashboard dialog (preflight confirmation and the read-only view behind the warning marker).
// The data is what engine/lib/hostcheck.sh produced (served by the backend): nothing about a platform is written here. A fix / restore step is
// {text, command}: a command goes in a copyable block, anything else is an explanation. Text is only ever added with textContent.
const ResourceCards = (() => {
  const el = (doc, tag, cls, text) => {
    const e = doc.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  };

  // navigator.clipboard needs a secure context (localhost is one, a LAN address over http is not): then the classic textarea + execCommand.
  function copyText(text, env) {
    env = env || { navigator: typeof navigator !== "undefined" ? navigator : null, document: typeof document !== "undefined" ? document : null };
    if (env.navigator && env.navigator.clipboard && env.navigator.clipboard.writeText) return env.navigator.clipboard.writeText(text);
    return new Promise((resolve, reject) => {
      const d = env.document, ta = d.createElement("textarea");
      ta.value = text; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
      d.body.appendChild(ta); ta.select();
      let ok = false;
      try { ok = d.execCommand("copy"); } catch (e) { ok = false; }
      d.body.removeChild(ta);
      ok ? resolve() : reject(new Error("copy not available"));
    });
  }

  // consecutive commands form one block with one Copy button; explanations stay paragraphs
  function steps(doc, list, copy) {
    const out = [];
    let run = [];
    const flush = () => {
      if (!run.length) return;
      const lines = run.map(s => s.text), box = el(doc, "div", "rc-cmd");
      const btn = el(doc, "button", "rc-copy", "Copy");
      btn.type = "button";
      btn.setAttribute("aria-label", "Copy the commands");
      btn.onclick = e => {
        if (e && e.stopPropagation) e.stopPropagation();
        Promise.resolve(copy(lines.join("\n"))).then(() => "Copied", () => "Copy failed").then(label => {
          btn.textContent = label;
          setTimeout(() => { btn.textContent = "Copy"; }, 1500);
        });
      };
      box.append(el(doc, "pre", "", lines.join("\n")), btn);
      out.push(box);
      run = [];
    };
    for (const s of list || []) {
      if (s.command) run.push(s);
      else { flush(); out.push(el(doc, "p", "rc-text", s.text)); }
    }
    flush();
    return out;
  }

  function row(doc, label, ...content) {
    const r = el(doc, "div", "rc-row");
    r.append(el(doc, "div", "rc-lbl", label), ...content);
    return r;
  }

  // Compact by default: severity, resource, current / recommended, one impact sentence and a toggle. The fix (action, commands, restore) is hidden
  // until "Show fix".
  let seq = 0;
  function card(doc, issue, copy) {
    const critical = issue.status === "CRITICAL";
    const c = el(doc, "section", "rc-card " + (critical ? "rc-critical" : "rc-warning"));
    const head = el(doc, "div", "rc-head");
    head.append(el(doc, "span", "rc-badge", critical ? "CRITICAL" : "WARNING"), el(doc, "strong", "rc-title", issue.title));
    c.append(head);
    const cur = issue.current_lines && issue.current_lines.length ? issue.current_lines : [issue.current];
    const rec = issue.recommended_lines && issue.recommended_lines.length ? issue.recommended_lines : (issue.recommended ? [issue.recommended] : []);
    const sum = el(doc, "div", "rc-sum");
    sum.append(el(doc, "span", "rc-cur", "Current: " + cur.join(" · ")));
    if (rec.length) sum.append(el(doc, "span", "rc-rec", "Recommended: " + rec.join(" · ")));
    c.append(sum);
    if (issue.impact) c.append(el(doc, "p", "rc-text", issue.impact));
    const hasFix = (issue.fix && issue.fix.length) || (issue.restore && issue.restore.length);
    if (hasFix) {
      const fix = el(doc, "div", "rc-fix"), id = "rc-fix-" + (++seq);
      fix.id = id; fix.hidden = true;
      if (issue.fix && issue.fix.length) fix.append(row(doc, "Recommended action", ...steps(doc, issue.fix, copy)));
      if (issue.restore && issue.restore.length) fix.append(row(doc, "To restore the previous values", ...steps(doc, issue.restore, copy)));
      const toggle = el(doc, "button", "rc-toggle", "Show fix");
      toggle.type = "button"; toggle.setAttribute("aria-expanded", "false"); toggle.setAttribute("aria-controls", id);
      toggle.onclick = e => {
        if (e && e.stopPropagation) e.stopPropagation();
        fix.hidden = !fix.hidden;
        toggle.textContent = fix.hidden ? "Show fix" : "Hide fix";
        toggle.setAttribute("aria-expanded", fix.hidden ? "false" : "true");
      };
      c.append(toggle, fix);
    }
    return c;
  }

  // Fills `container` with one card per issue (replacing its content).
  function render(doc, container, issues, copy) {
    container.replaceChildren(...issues.map(i => card(doc, i, copy || copyText)));
  }

  return { render, copyText, card };
})();
if (typeof module !== "undefined" && module.exports) module.exports = ResourceCards;
