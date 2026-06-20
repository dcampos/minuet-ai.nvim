# Duet NES Demo

Standalone, deterministic demo for the duet NES (next-edit-suggestion) UI.

It loads this checkout into a minimal Neovim 0.12 config, installs tokyonight
with native `vim.pack`, and mocks only `minuet.duet.chat.request`. The preview,
diff rendering, treesitter coloring, and `<Tab>` accept/jump flow are the real
plugin code. No API key is needed and no model request is made.

## Run

```bash
cd experiments/duet-nes/demo
nix run path:$PWD#demo
```

Start with the cursor on a specific example:

```bash
nix run path:$PWD#demo -- 3
```

Direct launch also works if `nvim >= 0.12` and `git` are on `PATH`:

```bash
nvim -u init.lua
```

The demo isolates Neovim state under `./.state/` so it does not touch the user's
real config or plugin installs. The flake wrapper sets the same paths before
launch; direct `nvim -u init.lua` launch gets the same isolation from `init.lua`.

## Controls

All examples live in one buffer. Move with normal Vim motions; the example under
the cursor is the active one. The demo does not manage example-to-example
navigation with keymaps.

| Key | Action |
| --- | --- |
| `<Tab>` | If a suggestion is visible, jump to or accept the current change. If nothing is visible, request the next deterministic suggestion for the example under the cursor. |
| `<CR>` | Accept the visible suggestion as a whole, then show that example's next scripted step. Bound only for this demo. |
| `<BS>` | Restart the example under the cursor. |
| `:DemoGoto N` | Jump the cursor to example `N`. |
| `:DemoList` | List examples. |

## Scenarios

1. Finish an inline edit at the cursor.
2. Propagate a rename across multiple hunks.
3. Insert a collapsed guard block, then reveal it.
4. Rewrite a stub with mixed inline/body changes.
5. Step through string and numeric literal edits.
6. Delete a line, then trim inline arguments.

## Screenshots

The screenshot path uses the same headless wlroots approach as the visual
harness: `cage` + `foot` + `grim`, using software rendering and the real terminal
font path.

```bash
nix shell nixpkgs#cage nixpkgs#foot nixpkgs#grim nixpkgs#git \
  -c bash shot_demo.sh 3 tt s3_revealed
```

Arguments are `<scenario> [keys] [tag]`. Replay keys are:

- `t`: `<Tab>`
- `n`: `<CR>`
- `b`: `<BS>`

Screenshots are written to `out/<tag>.png`.
