# SPEC-006.8.1 — EDB / Dark UI Themes

| | |
|---|---|
| Status | Implemented |
| Document type | Reconstructed specification |
| Source | Current implementation and available project history |
| Original specification | Not available as a formal document. The request was made in chat; the messages are quoted verbatim below. |

## Summary

The UI follows the EDB "Blue Coal" palette and a header button switches between a light (EDB) theme and a dark theme. Context: the first message asked which EDB template to use; the answer was the org-provisioned `edb-bento-lite` skill (the Blue Coal palette, defined for slides), which was then adapted to CSS. The two messages below are separated by a rule; the answer is not part of the original request.

## Implemented behavior

- Themes: **light** (EDB Blue Coal on white and Frost, default) and **dark** (Abyss and Deep backgrounds, Frost text). "EDB theme" in the project's wording is the light theme; the dark theme uses the same palette family.
- Switch: the `☾ Dark` / `☀ Light` button at the right of the header (`#theme-toggle`); tooltip "Switch to dark mode" / "Switch to light mode"; `aria-pressed` reflects the state. Switching is immediate and only sets a `data-theme` attribute on `<html>`.
- Mechanism: CSS custom properties at the top of `web/static/style.css` (`:root` for light, `:root[data-theme="dark"]` for dark); no component has hard-coded theme colors except the terminal frame (black), the always-dark log panel and white overlays on the header.
- Persistence: `localStorage` key `theme` (`"dark"` or `"light"`), confirmed in `web/static/app.js`; a small inline script in `index.html` applies it before the first paint. If storage is unavailable the page works with the default.
- Default: light.
- Affected: header, sidebar, tab bar, status and resource bars, buttons, dialog, links, status colors. Unaffected: the terminals (ttyd renders black) and the operation log panel (dark in both themes).
- Typography: Roboto / Roboto Condensed when installed on the viewer's machine, system fonts otherwise (nothing is downloaded).
- Contrast: the real text/background pairs were computed (WCAG); all pass 4.5:1 in both themes after three shades were deepened.

## Implementation

- `web/static/style.css`, `web/static/index.html`, `web/static/app.js`, `README.md`.

## Later corrections and follow-ups

None recorded beyond the general ones in `docs/specs/README.md`.

## Verification

Toggle logic tested against the real `app.js` in a fake DOM (default, switching, persistence after reload, iframes untouched). Contrast computed numerically. Visual review pending.

## Known limitations

- ttyd terminals do not follow the theme (a light terminal needs a ttyd theme option and a container restart).
- The visual result was not reviewed in a real browser by the implementer.

## Original request (verbatim chat messages)

~~~~~text
Which is the EDB template to use for css style ?

---

Yes can you do it and place a button to swith to dark mode as well ?
~~~~~
