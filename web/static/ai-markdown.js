// Markdown rendering and syntax highlighting for the AI Lab Assistant panel. No library.
// Everything is built with createElement / textContent: a reply from Claude is never parsed as markup, links are limited to
// http(s) and mailto, and nothing here runs a script. Pure functions (parse, tokens) are unit-tested with Node
// (tests/ai_builder_ui_test.js); render() only needs an object with createElement.

const AIB_MD_MAX = 30000;
const AIB_LINK_RE = /^(https?:\/\/|mailto:)/i;
const AIB_ITEM_RE = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
const AIB_FENCE_RE = /^\s{0,3}(`{3,}|~{3,})\s*([\w+#.-]*)[^\n]*$/;
const AIB_HR_RE = /^\s{0,3}([-*_])(\s*\1){2,}\s*$/;
const AIB_TABLE_SEP_RE = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;                   // GFM: a cell of the delimiter row needs one hyphen at least

const AIBHighlight = {
  // Language names as people and models write them -> the few we highlight.
  langFor(name) {
    const n = String(name || "").toLowerCase().replace(/^.*\./, "");
    if (["sh", "bash", "zsh", "shell", "console", "shellscript"].includes(n)) return "bash";
    if (["yaml", "yml"].includes(n)) return "yaml";
    if (n === "json") return "json";
    if (["sql", "psql", "pgsql", "postgresql"].includes(n)) return "sql";
    if (["diff", "patch"].includes(n)) return "diff";
    return "text";
  },
  // One line -> [{cls, text}] covering the whole line. cls is "" for plain text.
  line(lang, text) {
    text = String(text);
    if (lang === "diff") {
      const cls = text.startsWith("+++") || text.startsWith("---") ? "meta" : text.startsWith("@@") ? "hunk" : text.startsWith("+") ? "add" : text.startsWith("-") ? "del" : "";
      return [{ cls, text }];
    }
    const rules = AIB_RULES[lang];
    if (!rules) return [{ cls: "", text }];
    const out = [];
    let plain = "", i = 0;
    const flush = () => { if (plain) { out.push({ cls: "", text: plain }); plain = ""; } };
    outer: while (i < text.length) {
      const prev = i ? text[i - 1] : " ";
      for (const [cls, re, needsSpaceBefore] of rules) {
        if (needsSpaceBefore && !/\s/.test(prev)) continue;
        re.lastIndex = i;
        const m = re.exec(text);
        if (m && m[0].length) { flush(); out.push({ cls, text: m[0] }); i += m[0].length; continue outer; }
      }
      plain += text[i++];
    }
    flush();
    return out;
  },
};
const AIB_SQL_WORDS = "select|from|where|insert|into|values|update|set|delete|create|table|alter|drop|join|left|right|inner|outer|on|group|by|order|limit|offset|and|or|not|null|as|in|is|primary|key|default|index|database|schema|grant|revoke|to|with|union|distinct|count|begin|commit|rollback|explain|analyze|vacuum|role|user|login|password|replication|extension|if|exists|true|false|case|when|then|else|end|having|asc|desc|returning|references|foreign|unique|check|constraint|view|function|trigger|replace";
const AIB_STR = String.raw`"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?`;
const AIB_RULES = {
  bash: [
    ["com", /#.*/y, true],
    ["str", new RegExp(AIB_STR, "y")],
    ["var", /\$(?:\{[^}]*\}|\(|[A-Za-z_]\w*|[0-9@#?$!*-])/y],
    ["flag", /--?[A-Za-z][\w-]*/y, true],
    ["op", /&&|\|\||[|;<>&]+/y],
    ["kw", /(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|return|export|local|readonly|set|unset|exit|source|cd|echo|trap|shift|read)\b/y, true],
    ["num", /\d+(?:\.\d+)?\b/y, true],
  ],
  yaml: [
    ["com", /#.*/y, true],
    ["key", new RegExp(String.raw`(?:"[^"]*"|'[^']*'|[A-Za-z_][\w.\-/]*)(?=\s*:(?:\s|$))`, "y")],
    ["str", new RegExp(AIB_STR, "y")],
    ["kw", /(?:true|false|null|yes|no|on|off)\b/y, true],
    ["var", /[&*][\w-]+/y, true],
    ["num", /-?\d+(?:\.\d+)?(?![\w.])/y, true],
  ],
  json: [
    ["key", /"(?:\\.|[^"\\])*"(?=\s*:)/y],
    ["str", /"(?:\\.|[^"\\])*"?/y],
    ["kw", /(?:true|false|null)\b/y],
    ["num", /-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/y],
  ],
  sql: [
    ["com", /--.*/y],
    ["str", /'(?:''|[^'])*'?/y],
    ["kw", new RegExp(`(?:${AIB_SQL_WORDS})\\b`, "iy"), true],
    ["num", /\d+(?:\.\d+)?\b/y, true],
  ],
};

// ---------------------------------------------------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------------------------------------------------
const AIBMarkdown = {
  parse(text) {
    const lines = String(text == null ? "" : text).slice(0, AIB_MD_MAX).replace(/\r\n?/g, "\n").split("\n");
    return aibBlocks(lines);
  },
  inline: aibInline,
  isSafeLink: href => AIB_LINK_RE.test(String(href || "")),
  // The rendered reply: a div.aib-md. opts.copy(text, button) is called by the Copy button of a code block.
  render(text, doc, opts = {}) {
    const root = doc.createElement("div");
    root.className = "aib-md";
    for (const b of AIBMarkdown.parse(text)) root.appendChild(aibRenderBlock(b, doc, opts));
    return root;
  },
  // A code block on its own (also used by the diff viewer's callers and tests).
  codeBlock(code, lang, doc, opts = {}) { return aibCodeBlock(code, lang, doc, opts); },
};

function aibInline(src) {
  src = String(src);
  const out = [];
  let buf = "", i = 0;
  const flush = () => { if (buf) { out.push({ t: "text", v: buf }); buf = ""; } };
  while (i < src.length) {
    const ch = src[i], rest = () => src.slice(i);
    if (ch === "\\" && i + 1 < src.length && /[\\`*_{}[\]()#+\-.!|~>]/.test(src[i + 1])) { buf += src[i + 1]; i += 2; continue; }
    if (ch === "`") {
      const m = /^(`+)([\s\S]*?[^`])\1(?!`)/.exec(rest());
      if (m) { flush(); out.push({ t: "code", v: m[2].replace(/^ ([\s\S]*) $/, "$1") }); i += m[0].length; continue; }
    }
    if (ch === "[") {
      const m = /^\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/.exec(rest());
      if (m) { flush(); out.push({ t: "a", href: m[2], c: aibInline(m[1]) }); i += m[0].length; continue; }
    }
    if (src.startsWith("**", i) || src.startsWith("__", i) || src.startsWith("~~", i)) {
      const d = src.substr(i, 2), end = src.indexOf(d, i + 2);
      const intraword = d === "__" && (/\w/.test(i ? src[i - 1] : " ") || /\w/.test(src[end + 2] || " "));      // like _single_: not inside a word (window.__xss, a__b__c)
      if (end > i + 2 && !intraword && !/^\s|\s$/.test(src.slice(i + 2, end))) {
        flush(); out.push({ t: d === "~~" ? "del" : "strong", c: aibInline(src.slice(i + 2, end)) }); i = end + 2; continue;
      }
    }
    if (ch === "*" || ch === "_") {
      const end = src.indexOf(ch, i + 1), inner = end > i + 1 ? src.slice(i + 1, end) : "";
      const wordBefore = /\w/.test(i ? src[i - 1] : " "), wordAfter = /\w/.test(src[end + 1] || " ");
      if (end > i + 1 && !/^\s|\s$/.test(inner) && src[end + 1] !== ch && (ch === "*" || (!wordBefore && !wordAfter))) {
        flush(); out.push({ t: "em", c: aibInline(inner) }); i = end + 1; continue;
      }
    }
    if (ch === " " && src.startsWith("  \n", i)) { flush(); out.push({ t: "br" }); i += 3; continue; }
    if (ch === "\n") { buf += " "; i++; continue; }
    buf += ch; i++;
  }
  flush();
  return out;
}

function aibBlocks(lines) {
  const out = [];
  let i = 0;
  const startsBlock = l => AIB_FENCE_RE.test(l) || /^\s{0,3}#{1,6}\s/.test(l) || AIB_HR_RE.test(l) || /^\s{0,3}>/.test(l) || AIB_ITEM_RE.test(l);
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    let m = AIB_FENCE_RE.exec(line);
    if (m) {
      const fence = m[1], body = [];
      i++;
      while (i < lines.length && !(lines[i].trim().startsWith(fence[0].repeat(fence.length)) && /^[`~]+\s*$/.test(lines[i].trim()))) body.push(lines[i++]);
      i++;                                                                          // the closing fence (or the end of the text)
      out.push({ t: "code", lang: m[2], text: body.join("\n") });
      continue;
    }
    if ((m = /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line))) { out.push({ t: "h", level: m[1].length, c: aibInline(m[2]) }); i++; continue; }
    if (AIB_HR_RE.test(line)) { out.push({ t: "hr" }); i++; continue; }
    if (/^\s{0,3}>/.test(line)) {
      const q = [];
      while (i < lines.length && /^\s{0,3}>/.test(lines[i])) q.push(lines[i++].replace(/^\s{0,3}>\s?/, ""));
      out.push({ t: "quote", c: aibBlocks(q) });
      continue;
    }
    if (line.includes("|") && i + 1 < lines.length && AIB_TABLE_SEP_RE.test(lines[i + 1]) && lines[i + 1].includes("-")) {
      const cells = l => l.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map(c => c.trim());
      const head = cells(line), align = cells(lines[i + 1]).map(c => (c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : ""));
      const rows = [];
      i += 2;
      while (i < lines.length && lines[i].trim() && lines[i].includes("|")) rows.push(cells(lines[i++]));
      out.push({ t: "table", align, head: head.map(aibInline), rows: rows.map(r => r.map(aibInline)) });
      continue;
    }
    if (AIB_ITEM_RE.test(line)) {
      const first = AIB_ITEM_RE.exec(line), base = first[1].length, ordered = /\d/.test(first[2]), items = [];
      let cur = null;
      while (i < lines.length) {
        const l = lines[i];
        if (!l.trim()) {
          let j = i + 1;
          while (j < lines.length && !lines[j].trim()) j++;
          if (j >= lines.length) break;
          const ind = lines[j].match(/^\s*/)[0].length;
          if (ind > base || (ind === base && AIB_ITEM_RE.test(lines[j]))) { if (cur) cur.push(""); i = j; continue; }
          break;
        }
        const im = AIB_ITEM_RE.exec(l), ind = l.match(/^\s*/)[0].length;
        if (im && ind === base) {
          if (ordered !== /\d/.test(im[2])) break;
          cur = [im[3]]; items.push(cur); i++; continue;
        }
        if (ind > base && cur) { cur.push(l.slice(Math.min(ind, base + 2))); i++; continue; }
        break;
      }
      out.push({ t: ordered ? "ol" : "ul", start: ordered ? Number(first[2].replace(/\D/g, "")) : 1, items: items.map(it => aibBlocks(it)) });
      continue;
    }
    const para = [];                                                                // a paragraph runs until a blank line or another block
    while (i < lines.length && lines[i].trim() && !(para.length && startsBlock(lines[i]))) para.push(lines[i++]);
    out.push({ t: "p", c: aibInline(para.join("\n")) });                         // a soft line break reads as a space, two trailing spaces as <br>

  }
  return out;
}

function aibText(doc, s) {
  if (typeof doc.createTextNode === "function") return doc.createTextNode(s);
  const el = doc.createElement("span");
  el.textContent = s;
  return el;
}
function aibEl(doc, tag, cls, text) {
  const el = doc.createElement(tag);
  if (cls) el.className = cls;
  if (text != null) el.textContent = text;
  return el;
}
function aibRenderInline(nodes, doc, parent) {
  for (const n of nodes) {
    if (n.t === "text") parent.appendChild(aibText(doc, n.v));
    else if (n.t === "br") parent.appendChild(doc.createElement("br"));
    else if (n.t === "code") parent.appendChild(aibEl(doc, "code", "aib-ic", n.v));
    else if (n.t === "a") {
      const safe = AIBMarkdown.isSafeLink(n.href), el = doc.createElement(safe ? "a" : "span");     // an unsafe link keeps its text, loses its address
      if (safe) { el.href = n.href; el.target = "_blank"; el.rel = "noopener noreferrer"; }
      aibRenderInline(n.c, doc, el);
      parent.appendChild(el);
    } else {
      const el = doc.createElement(n.t === "strong" ? "strong" : n.t === "em" ? "em" : "del");
      aibRenderInline(n.c, doc, el);
      parent.appendChild(el);
    }
  }
}
function aibCodeBlock(code, lang, doc, opts) {
  const language = AIBHighlight.langFor(lang);
  const box = aibEl(doc, "div", "aib-codeblock");
  const head = aibEl(doc, "div", "aib-code-head");
  head.appendChild(aibEl(doc, "span", "aib-code-lang", lang ? String(lang).slice(0, 20) : "code"));
  const copy = aibEl(doc, "button", "aib-copy", "Copy");
  copy.type = "button";
  if (copy.setAttribute) copy.setAttribute("aria-label", "Copy code to the clipboard");
  copy.onclick = () => { if (opts.copy) opts.copy(code, copy); };
  head.appendChild(copy);
  const pre = doc.createElement("pre");
  const body = doc.createElement("code");
  String(code).split("\n").forEach((line, idx, all) => {
    for (const tk of AIBHighlight.line(language, line)) {
      if (tk.cls) body.appendChild(aibEl(doc, "span", "tk-" + tk.cls, tk.text)); else body.appendChild(aibText(doc, tk.text));
    }
    if (idx < all.length - 1) body.appendChild(aibText(doc, "\n"));
  });
  pre.appendChild(body);
  if (pre.setAttribute) pre.setAttribute("tabindex", "0");
  box.appendChild(head); box.appendChild(pre);
  return box;
}
function aibRenderBlock(b, doc, opts) {
  switch (b.t) {
    case "h": { const el = doc.createElement("h" + Math.min(6, b.level + 2)); el.className = "aib-h"; aibRenderInline(b.c, doc, el); return el; }
    case "p": { const el = doc.createElement("p"); aibRenderInline(b.c, doc, el); return el; }
    case "hr": return doc.createElement("hr");
    case "code": return aibCodeBlock(b.text, b.lang, doc, opts);
    case "quote": { const el = doc.createElement("blockquote"); for (const c of b.c) el.appendChild(aibRenderBlock(c, doc, opts)); return el; }
    case "ul": case "ol": {
      const el = doc.createElement(b.t);
      if (b.t === "ol" && b.start > 1) el.start = b.start;
      for (const item of b.items) { const li = doc.createElement("li"); for (const c of item) li.appendChild(aibRenderBlock(c, doc, opts)); el.appendChild(li); }
      return el;
    }
    case "table": {
      const wrap = aibEl(doc, "div", "aib-table"), table = doc.createElement("table"), thead = doc.createElement("thead"), tbody = doc.createElement("tbody");
      const row = (cells, tag, parent) => {
        const tr = doc.createElement("tr");
        cells.forEach((c, k) => { const td = doc.createElement(tag); if (b.align[k]) td.className = "al-" + b.align[k]; aibRenderInline(c, doc, td); tr.appendChild(td); });
        parent.appendChild(tr);
      };
      row(b.head, "th", thead); for (const r of b.rows) row(r, "td", tbody);
      table.appendChild(thead); table.appendChild(tbody); wrap.appendChild(table);
      return wrap;
    }
    default: return doc.createElement("div");
  }
}

if (typeof module !== "undefined" && module.exports) module.exports = { AIBMarkdown, AIBHighlight };
