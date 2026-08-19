# bruvtab.el — EXWM Firefox URL lookup

Glue between EXWM X11 windows and the `bruvtab`/`brotab` `--json` commands.
Goal: given an EXWM buffer that is a Firefox window, return the URL of its
active tab. The only source file is `bruvtab.el`.

## Core insight: there is no direct id mapping

bruvtab identifies a browser window as `<prefix>.<window_id>` (e.g. `a.1`)
and a tab as `<prefix>.<window_id>.<tab_id>` (e.g. `a.1.2`). The Firefox
extension (WebExtensions) has **no** way to see the X11 window id, so no
bruvtab command can return the X11↔window-id mapping.

The reliable join is **title matching**, not a background poller:

- Firefox sets `_NET_WM_NAME` to `<page title> — Mozilla Firefox`.
  (Separator is normally U+2014 EM DASH, but older builds used ASCII `-`;
  also `(Private Browsing)` may be appended.)
- EXWM copies `_NET_WM_NAME` into the buffer-local `exwm-title`.
- `bruvtab active --json` gives each window's active tab id; `bruvtab tabs
  --json` gives that tab's `title` (a plain document title, no suffix).
- Strip the Firefox suffix from the X11 title, then match against active
  tab titles. This is deterministic and works on demand.

A background hash-table tracker exists only as a fallback for titles that
cannot be matched (e.g. a window titled just `Mozilla Firefox`).

## bruvtab JSON schema (the `--json` extension)

```jsonc
// bruvtab windows --json
[ {"window": "a.1", "tabs": 2}, {"window": "a.259", "tabs": 1} ]

// bruvtab tabs --json
[ {"id": "a.1.2", "title": "...", "url": "https://...", "playing": false, "muted": false}, ... ]

// bruvtab active --json  (one entry per window)
[ {"id": "a.1.2", "client": "a.\tlocalhost:4625\t3512053\tfirefox"}, ... ]
```

- Window id = tab id minus the final `.N` segment, but only strip when a
  dot remains after the cut (`a.1.2` → `a.1`; plain `a.1` must stay `a.1`).
- Prefix is a single letter per client (`a` above). `client`'s last field
  names the browser (`firefox`).

## Firefox window identification under X11

- WM_CLASS is `instance="Navigator"`, `class="firefox"` (older/variant
  builds use `Firefox`). EXWM exposes these as buffer-local
  `exwm-instance-name` and `exwm-class-name`.
- EXWM buffer-local vars to read (declared in `bruvtab.el` to silence the
  byte-compiler): `exwm--id` (X11 id), `exwm--id-buffer-alist`,
  `exwm-class-name`, `exwm-instance-name`, `exwm-title`.
- A buffer is a Firefox window iff `exwm--id` is truthy and either
  `exwm-class-name` or `exwm-instance-name` matches
  `bruvtab-firefox-class-regexp`.

## bruvtab.el API

Queries: `bruvtab-windows`, `bruvtab-tabs`, `bruvtab-active`,
`bruvtab-active-tab-for-window`, `bruvtab-url-for-window`.

Mapping: `bruvtab-firefox-buffer-p`, `bruvtab-window-id-for-buffer`,
`bruvtab-tab-for-buffer`, `bruvtab-url-for-buffer`.

Fallback tracker: `bruvtab-update-window-id-map`,
`bruvtab-window-id-alist`, `bruvtab-start-window-tracking`,
`bruvtab-stop-window-tracking`.

Commands: `bruvtab-show-url`, `bruvtab-debug`.

Resolution order in `bruvtab-window-id-for-buffer`: title match first
(authoritative), then `bruvtab-window-id-map` fallback.

## Fallback tracker semantics

`bruvtab-update-window-id-map` rebuilds `bruvtab-window-id-map`
(`x11-id -> "a.N"`):

1. retain mappings whose X11 id and bruvtab id are both still present;
2. title-match any unmapped X11 window;
3. only when exactly **one** X11 window and **one** bruvtab window remain
   unassigned, pair them — otherwise leave unassigned (the two-windows-
   opened-at-once ambiguity).

## Implementation gotchas (do not regress)

- `json-parse-string` returns `:false` (truthy!) unless `:false-object nil`
  is passed; also pass `:null-object nil`, `:object-type 'alist`,
  `:array-type 'list`.
- `string-match-p` returns the match index (e.g. `0`), not `t`; a predicate
  built on it must append a final `t` to return boolean truth.
- `call-process` stdout+stderr into a temp buffer: destination `(list t t)`.
- `hash-table-values`/`hash-table-keys` need `(require 'subr-x)`.
- `bruvtab` writes `--json` **after** the subcommand
  (`bruvtab windows --json`), not before.

## Testing

This sandbox has no `$DISPLAY` and no running mediator, so `bruvtab` cannot
reach Firefox here. The pure/mapping logic is validated by mocking
`bruvtab--json` and `bruvtab--firefox-x11-windows` with the transcript's own
JSON. A real run on the target machine (`M-x bruvtab-debug`) is still the
integration check.
