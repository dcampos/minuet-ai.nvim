# duet NES tuning experiments

Exploratory scripts and result logs from tuning the `Minuet duet` NES
(next-edit-suggestion) loop against `openai/gpt-oss-120b` on OpenRouter. This is
iteration/WIP material kept on the `duet-nes` branch for provenance - it is not
production code and is not wired into the plugin or `make test`.

## Running

Most scripts drive the real model and need `OPENROUTER_API_KEY` in the env:

```
OPENROUTER_API_KEY=... nvim --headless -u NONE -i NONE -n \
  -c "luafile experiments/duet-nes/scripts/<name>.lua" -c "qa!"
```

They prepend the dev checkout (`~/code/lua/minuet-ai.nvim`) to the runtimepath
and call into `minuet.duet.*` directly. Some accept env knobs: `BENCH_N`,
`BENCH_STAGES`, `BENCH_PROMPTS`, `BENCH_STRATS`, `MINUET_EFFORT`. Fresh runtime
logs are written to `./tmp/` (gitignored); the files under `logs/` here are
committed snapshots from the runs that drove the decisions below.

## Scripts

| script | what it does |
| --- | --- |
| `nes_repro.lua` | Replays the Typst `x -> y` session step by step, logging request/response/reasoning per step to a JSONL. First exposed the failure modes. |
| `nes_experiment.lua` | Sweep prompt x effort x cursor-marker on the cross-line scenario. |
| `nes_medium.lua` | Confirms `effort=medium` eliminates the reverts seen at `low`. |
| `nes_bench.lua` | apply-success bench running the real read/retry loop: structure (current +/- marker, proposed +/- plan) x prompt (baseline/improved/terse) x stages. |
| `nes_bench2.lua` | Generality: rename vs local finish-at-cursor, improved vs balanced prompt, cursor as a separate note. |
| `nes_sooner.lua` | First-turn responsiveness: shipped vs "eager" prompt at k=1/k=2 (acted vs read vs forward). |
| `verify_prompt.lua` | Sanity check of the shipped config prompt on rename@k=1 and a local edit (no regression). |
| `stab_check.lua`, `stab_check2.lua` | Headless check of the `<S-Tab>` duet+virtualtext toggle (the out-of-phase bug and the synced fix). |
| `inspect_smoke.lua` | Float render/toggle + single-prediction transcript capture. |
| `inspect_session_smoke.lua` | Multi-prediction session history + result tracking (accepted/dismissed/ignored). |

## Findings (these drove the commits on this branch)

- `reasoning.effort=low` makes gpt-oss-120b revert the user's own edits; `medium`
  fixes it. (`nes_repro`, `nes_medium`)
- The **prompt is the dominant lever** for apply-patch success, not the message
  structure. The "consolidated big-context diff" idea is a wash for accuracy (a
  KV-cache/cost optimization at best). (`nes_bench`)
- An inline `<|cursor|>` marker is out-of-distribution for an apply_patch-trained
  model: it gets copied into patches and biases reverts. Feeding the cursor as a
  separate note is best (>= none > inline). (`nes_bench` cursor sweep)
- A balanced prompt (finish-at-cursor OR continue a multi-site change) generalises
  without regressing local edits. (`nes_bench2`)
- "Sooner": telling the model to act on a single edit and to skip the redundant
  `read` (the whole file is already provided) takes first-turn action from ~5/8 to
  8/8 with 0 reads and 0 bad patches. (`nes_sooner`, `verify_prompt`)
