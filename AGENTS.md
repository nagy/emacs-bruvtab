# AGENTS.md — emacs-bruvtab

## Purpose

Glue between EXWM X11 windows and the `bruvtab`/`brotab` `--json` commands.
Goal: given an EXWM buffer that is a Firefox window, return the URL of its
active tab. One source file, `bruvtab.el`. `flake.nix` configures `nagy.emacs`
from `github:nagy/common`. `LICENSE` holds the AGPLv3
text. License: AGPL-3.0-or-later. Emacs 31.1 or newer.

## Layout

- `bruvtab.el` — the whole package: queries, window mapping, snapshot, native HTTP
  client, CLI fallback, commands.
- `test/bruvtab-test.el` — ERT suite, 33 tests, no mediator and no X11 display.
- `flake.nix` — `nagy.emacs` config of `github:nagy/common`, which supplies
  `melpaBuild`, the ERT run, the lint gate, the devShell and treefmt.

## Build and test

- `nix flake check` — the gate: `checks.bruvtab` (the package, whose `doCheck`
  runs `test/*-test.el`), `checks.lint` and `checks.treefmt`. Run before a
  commit.
- `nix build` — the package only; `melpaBuild` still runs the ERT suite.
- `nix fmt` — nixfmt through treefmt. Never format `flake.nix` by hand.
- `nix develop` — Emacs and the `bruvtab` CLI. The CLI sits on `PATH` because
  `nagy.emacs.devShell.extraPackages` carries it.
- Direct run: `emacs --batch -L . -L test -l bruvtab.el test/bruvtab-test.el -f
  ert-run-tests-batch-and-exit`.
- `M-x bruvtab-diagnose` — prints per-stage timings when a stall shows up.
- Manual check against a live mediator on `127.0.0.1:4625`:
  `bruvtab--native-clients`, `bruvtab-tabs`, `bruvtab-active`,
  `bruvtab-windows`, `bruvtab-url-for-buffer`.

### Flake

- `flake-parts` with `nixpkgs`, `treefmt-nix`, `common` (`github:nagy/common`)
  and `bruvtab` (`github:pschmitt/bruvtab`, with `nixpkgs` following ours) as
  inputs. `nixpkgs` stays pinned to `nixos-unstable` in `flake.lock`. Only
  `x86_64-linux` is evaluated.
- `common.flakeModules.emacs` does the build, the ERT run, the lint check and
  the devShell; `common.flakeModules.treefmt` supplies `treefmt` with
  `nixfmt`, `rustfmt` and `taplo` enabled, so a `.rs` or `.toml` file added
  here is formatted by the house settings rather than this repo's. The flake
  itself states nothing about the package: keep it a `nagy.emacs` block, so
  version, description, licence, homepage and maintainer exist once, in the
  header of `bruvtab.el`.
- `nagy.emacs.name` is `bruvtab` and must match the file name and the
  `;;; bruvtab.el --- ...` header, or `require` breaks after installation.
- The header owns `Version:` (plus `-unstable-<YYYY-MM-DD>` from the consumer's
  last commit), the summary line as the description, `URL:` as the homepage,
  `SPDX-License-Identifier: AGPL-3.0-or-later` and `Maintainer:` as the
  maintainer, resolved through its email. A field that is missing or wrong
  stops evaluation rather than shipping a package without it.
- `packages.bruvtab` is overridable at its `melpaBuild` leaf only:
  `inputs.<this>.packages.${system}.bruvtab.override { emacs = pkgs.emacs-nox; }`.
  `src`, `version`, `meta` and the patches are read from `cfg.src` at evaluation
  time, so they are options here, not override arguments.
- `bruvtab-program` gets no `;; NIX-EMACS-PROGRAM:` annotation, because that
  annotation names a nixpkgs attribute and `bruvtab` is not in nixpkgs.
  `nagy.emacs.postPatch` rewrites the defcustom default to
  `lib.getExe' bruvtab.packages.${system}.bruvtab "bruvtab"` instead; the
  upstream flake carries no `meta.mainProgram`, so the binary is named
  explicitly, and `--replace-fail` stops the build when the defcustom moves.
- The ERT suite runs from `test/`, which the part copies back from the source
  tree: MELPA `files` specs never descend into subdirectories, so the tests stay
  out of the installed package without a `files` list.

## Architecture

### Core insight: there is no direct id mapping

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

### JSON schema

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

### Firefox identification under X11

- WM_CLASS is `instance="Navigator"`, `class="firefox"` (older/variant
  builds use `Firefox`). EXWM exposes these as buffer-local
  `exwm-instance-name` and `exwm-class-name`.
- EXWM buffer-local vars to read (declared in `bruvtab.el` to silence the
  byte-compiler): `exwm--id` (X11 id), `exwm--id-buffer-alist`,
  `exwm-class-name`, `exwm-instance-name`, `exwm-title`.
- A buffer is a Firefox window iff `exwm--id` is truthy and either
  `exwm-class-name` or `exwm-instance-name` matches
  `bruvtab-firefox-class-regexp`.
- Every regexp in `bruvtab.el` uses `rx` syntax, not hand-written
  backslash strings. The Firefox brand and private-window fragments
  (`bruvtab--firefox-brand`, `bruvtab--firefox-private-suffix`) are
  `rx` values embedded into other `rx` forms with `(regexp FRAGMENT)`.
  The header requires Emacs 31.1, because package-lint only accepts the
  `rx` `any` set operator from that version on.

### API

Queries: `bruvtab-windows`, `bruvtab-tabs`, `bruvtab-active`,
`bruvtab-active-tab-for-window`, `bruvtab-url-for-window`.

Mapping: `bruvtab-firefox-buffer-p`, `bruvtab-window-id-for-buffer`,
`bruvtab-tab-for-buffer`, `bruvtab-url-for-buffer`.

Fallback tracker: `bruvtab-update-window-id-map`,
`bruvtab-window-id-alist`, `bruvtab-start-window-tracking`,
`bruvtab-stop-window-tracking`.

Commands: `bruvtab-show-url`, `bruvtab-debug`, `bruvtab-diagnose`,
`bruvtab-start-window-tracking`, `bruvtab-stop-window-tracking`. Each
carries a `;;;###autoload` cookie, so `melpaBuild` emits them into
`bruvtab-autoloads.el` and `M-x` finds them without a `require`. Keep
the cookie when adding a command; a command without one stays invisible
after installation.

Resolution order in `bruvtab-window-id-for-buffer`: title match first
(authoritative), then `bruvtab-window-id-map` fallback.

Snapshot threading: `bruvtab--snapshot` fetches `tabs` + `active` exactly
once and probes the mediator ports a single time; buffer/window helpers
take an optional SNAPSHOT plist (`:tabs`, `:active`, `:tabs-by-id`,
`:title->id`). In native mode it uses `bruvtab--native-snapshot` (one probe
pass + two raw HTTP GETs); in cli mode it uses `bruvtab-tabs` +
`bruvtab-active` (two subprocess calls).

`bruvtab-url-for-buffer` takes SNAPSHOT too, and `bruvtab-show-url` builds
one snapshot after the Firefox check, then reuses it for both the match
test and the URL. Do not add a helper that silently fetches its own
snapshot on a path that already has one: one probe pass costs up to
`bruvtab-probe-timeout` plus two HTTP GETs per client.

### Fallback tracker

`bruvtab-update-window-id-map` rebuilds `bruvtab-window-id-map`
(`x11-id -> "a.N"`):

1. retain mappings whose X11 id and bruvtab id are both still present;
2. title-match any unmapped X11 window;
3. only when exactly **one** X11 window and **one** bruvtab window remain
   unassigned, pair them — otherwise leave unassigned (the two-windows-
   opened-at-once ambiguity).

### Transport

The Python CLI is not talking to a "native host socket". Two hops:

1. **Firefox ↔ mediator** (native messaging): stdio, not a network socket.
   Framing is a 4-byte native-endian (`struct 'I'`) length prefix followed
   by UTF-8 JSON. Commands are JSON objects such as `{"name":"list_tabs"}`,
   `{"name":"get_active_tabs"}`, `{"name":"query_tabs","query_info":{...}}`.
2. **Mediator ↔ bruvtab CLI**: plain HTTP on `127.0.0.1:4625..4635`
   (`DEFAULT_MIN_HTTP_PORT=4625`, `max=min+10`). The mediator is a Flask
   app. Relevant GET endpoints:
   - `/list_tabs` → newline-joined `window_id.tab_id\tTitle\tURL` lines
     (no prefix; the CLI prepends `a.`).
   - `/get_active_tabs` → comma-separated `window_id.tab_id` (e.g.
     `1.2,259.42`), CLI splits and prefixes.
   - `/query_tabs/{urlencoded-json}` → same line format, filtered by
     `browser.tabs.query`; used for `{"audible":true}` and `{"muted":true}`.

So each CLI `--json` command costs HTTP GETs, not just one:

- `windows --json` = 1 GET (`/list_tabs`, grouped by window id).
- `active --json`  = 1 GET (`/get_active_tabs`).
- `tabs --json`    = 3 GETs (`/list_tabs` + audible + muted queries) — the
  `playing`/`muted` fields are the extra two.

Implemented here as `bruvtab-backend` = `native` (default): a raw
HTTP/1.0 client (`bruvtab--native-fetch`) that GETs `/list_tabs` +
`/get_active_tabs` and skips `playing`/`muted`. `cli` shells out to
`bruvtab-program` as fallback.

## Rules

- `json-parse-string` returns `:false` (truthy!) unless `:false-object nil`
  is passed; also pass `:null-object nil`, `:object-type 'alist`,
  `:array-type 'list`.
- `string-match-p` returns the match index (e.g. `0`), not `t`; a predicate
  built on it must append a final `t` to return boolean truth.
- `call-process` stdout+stderr into a temp buffer: destination `(list t t)`.
- `hash-table-values`/`hash-table-keys` need `(require 'subr-x)`.
- checkdoc runs with `checkdoc-arguments-in-order-flag`, so a docstring must
  name its arguments in the order of the parameter list, each as the
  upper-case symbol (`PATH`, `BODY`), and its first line must be a full
  sentence ending in a period. A macro's `&rest body` still has to be named
  `BODY`.
- Pure helpers carry `(declare (pure t) (side-effect-free t))`:
  `bruvtab--window-id-of` and `bruvtab--window-ids-from-tabs`. A
  function that calls `string-match` does not qualify, because that sets
  the global match data. `bruvtab--window-id-of` therefore splits on
  `cl-position` instead of a regexp. Keep new pure helpers match-data
  free before you annotate them.
- `bruvtab` writes `--json` **after** the subcommand
  (`bruvtab windows --json`), not before. The switch lives in
  `bruvtab-json-argument`; the name must not end in `-flag`, because
  checkdoc then demands a `Non-nil means` docstring, which suits a
  boolean, not a string.
- Raw network process: use `:filter` + `:sentinel`, never the process
  buffer — the default buffer gets "connection broken by remote peer" text
  inserted at EOF. Prefer reading a declared `Content-Length` byte count
  (data-driven) over waiting for the EOF/sentinel, which can lag seconds in
  an interactive session.
- `make-network-process` with `:nowait nil` (blocking connect) has **no
  timeout**; a port that drops SYNs stalls Emacs for the OS connect timeout.
  Probes therefore use `:nowait t` + a bounded wait (`bruvtab-probe-timeout`),
  fired concurrently for all ports. `M-x bruvtab-diagnose` prints per-stage
  timings when a stall is suspected.

## Conventions

- Use `rx` syntax for every regexp, never a hand-written backslash string. Embed
  the fragments `bruvtab--firefox-brand` and `bruvtab--firefox-private-suffix`
  with `(regexp FRAGMENT)`.
- Prefix public names with `bruvtab-` and private names with `bruvtab--`.
- Give every command a `;;;###autoload` cookie. `melpaBuild` emits it into
  `bruvtab-autoloads.el`, and a command without one stays invisible after
  installation.
- Keep `;; Keywords:` to standard keywords from `finder-known-keywords`. `web`,
  `tools` and `unix` qualify. `exwm` does not, and package-lint fails on it.
- Test file naming: `test/<unit>-test.el`, shared helpers in
  `<name>-test-helper.el`, so the `test/*-test.el` glob stays test-only.
- Mock `bruvtab--native-clients`, `bruvtab--native-fetch`, `bruvtab-tabs`,
  `bruvtab--json`, `bruvtab--firefox-x11-windows` and `bruvtab--snapshot` in a
  test, and build a fake EXWM buffer from buffer-local `exwm--id`,
  `exwm-class-name` and `exwm-title`.

## Testing

`test/bruvtab-test.el` holds the ERT suite (33 tests). The test tree is
`test/` (singular), one file per source file, named `<unit>-test.el`.
Shared helpers go in `<name>-test-helper.el`, so the `test/*-test.el`
glob stays a test-only list. Run the suite with `nix flake check` (it
builds `checks.<system>.bruvtab`, the package whose `doCheck` runs it) or
directly:

```sh
emacs --batch -L . -L test -l bruvtab.el test/bruvtab-test.el \
  -f ert-run-tests-batch-and-exit
```

The suite needs no mediator and no X11 display. It mocks
`bruvtab--native-clients`, `bruvtab--native-fetch`, `bruvtab-tabs`,
`bruvtab--json`, `bruvtab--firefox-x11-windows` and `bruvtab--snapshot`,
and builds fake EXWM buffers with buffer-local `exwm--id`,
`exwm-class-name` and `exwm-title`. Covered: title normalization, window
id splitting, native line and active-id parsing, snapshot lookups, window
tab counts, Firefox detection, buffer-to-window mapping including the
fallback map, all three tracker rules, CLI JSON parsing (`false`/`null`
to nil) and the sorted alist view.

Manual verification against the live mediator on `127.0.0.1:4625` still
applies: `bruvtab--native-clients`, `bruvtab-tabs`, `bruvtab-active`,
`bruvtab-windows` and `bruvtab-url-for-buffer` are checked against real
tab data.

## Dependencies

| Dependency | Required? | Why |
|---|---|---|
| Emacs 31.1 | required | package-lint accepts the `rx` `any` set operator from that version on. |
| `bruvtab` CLI (`github:pschmitt/bruvtab`) | required | The `cli` backend shells out to `bruvtab-program`. `nagy.emacs.postPatch` patches the default path. |
| EXWM | required at runtime | Reads the buffer-local `exwm--*` variables. |
| `subr-x` | required | `hash-table-values` and `hash-table-keys`. |

## Workflow

- Keep `flake.lock` committed. The lock pins each input revision, so two
  machines build one tree.
