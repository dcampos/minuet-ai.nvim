---
name: duet-visual-harness
description: >-
  Use when you need to SEE how the duet (NES) preview renderer draws highlights
  in Neovim — to iterate on the diff chunking or the treesitter foreground
  coloring of proposed virtual text. Renders a before/after fixture to a
  true-color PNG with no model or API call, then you read the image back.
  Triggers: "screenshot the duet preview", "what does this highlight look like",
  "visual evidence for the NES viewer", "show the virtual text coloring".
---

# Duet Visual Harness

Get **visual evidence** of the duet preview renderer: feed a synthetic
before/after edit straight into `minuet.duet.preview.render` (no LLM, no
network), render it in a real Neovim with tokyonight + treesitter, and capture a
true-color PNG you can read back.

Harness dir: `experiments/duet-nes/visual-harness/` (call it `$H`).

## Quick start

```bash
cd experiments/duet-nes/visual-harness
nix develop -c bash shot_cage.sh word_swap   # -> out/word_swap.cage.png
```

Then **read the PNG** (`out/<fixture>.cage.png`) to see the result. The first run
fetches tools via the flake and installs tokyonight via nvim's `vim.pack`
(network); later runs are fast and offline.

## Three capture backends — pick by need

| Script | Output | Use when |
| --- | --- | --- |
| `shot_cage.sh`  | `out/<fx>.cage.png` | **Default / highest fidelity.** Headless wlroots (cage) + foot + grim — real terminal + the system DejaVu font, no GPU. |
| `shot_vhs.sh`   | `out/<fx>.png`      | Portable / self-contained (bundles its own renderer). Good off a wlroots box. |
| `shot_tmux.sh`  | `out/<fx>.tmux.png` | Lightest — tmux `capture-pane` + charm-freeze, no compositor/GPU/browser. Truecolor faithful, but renders in freeze's bundled font (not DejaVu). |

All three take a fixture name as `$1` (default `word_swap`). `shot_cage.sh` and
`shot_tmux.sh` use the flake devShell for their tools (`nix develop -c bash
...`). `shot_vhs.sh` is self-contained (it invokes vhs via `nix shell
nixpkgs#vhs`) and is the fragile, lowest-priority backend.

## Fixtures

Defined in `$H/fixtures.lua` — each is `{ filetype, original[], proposed[],
cursor?, opts?, select?, focus? }`. To test a new case, add an entry and run a
shot with its name. `select = true` reveals a hidden multi-line block chunk
(calls `select_next_chunk`). `opts` is merged into `config.duet.preview`
(e.g. `inline_max_groups`, `block_chunk_size`).

## How it works (so you can extend it)

- `$H/init.lua` is a model-free nvim driver: it puts the repo on `runtimepath`,
  stands up `config.duet` the way the test suite does (`package.loaded.minuet`),
  loads the chosen fixture, builds a `state`, and calls `preview.render`.
- It uses the **system nvim** on purpose (its bundled treesitter parser set +
  highlight queries) and pulls tokyonight via `vim.pack`. nvim state is isolated
  under `$H/.state/` (gitignored) — it never touches your real `~/.config/nvim`.
- `flake.nix` provides the capture toolchain only (no neovim), plus
  `nix run .#shot -- <vhs|cage> <fixture>`.

## Notes

- Colors are truecolor (24-bit); confirmed surviving tmux via `terminal-features
  RGB`. The duet highlight bgs are exact (`MinuetDuetAddText` = rgb 47,111,84).
- To crop whitespace: `magick out/<fx>.cage.png -trim +repage out/<fx>.trim.png`.
- No API keys needed — this renders the viewer, not a real prediction.
