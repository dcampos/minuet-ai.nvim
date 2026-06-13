# Duet NES — apply_patch spec (v1)

NES for `Minuet duet`. One model (`gpt-oss-120b` via OpenRouter), **no separate
apply model**. **Normal mode only, single buffer.** Treated as a long-lived
**code session** (KV-cache aware): the model sees the running stream of user
edits, the file state, its own past proposals + reasoning, and user results. It
emits one small Codex-style `apply_patch` (or calls `read`); we **validate by
applying before preview**. Rationale: `duet-nes-research.md`.

## UX (mirrors minuet completion, but normal mode)

- **Toggle** auto, **manual trigger**, **cycle**, **accept**, **dismiss** —
  `<C-…>` normal-mode maps (placeholders; user rebinds). e.g. `<C-f>` trigger,
  `<C-n>` cycle, `<C-o>` accept, `<C-a>` dismiss, `<C-e>` toggle.
- **One suggestion at a time.** Cycle = regenerate **on the fly** (no prefetch pool).
- **Manual**: accumulated edits are flushed **one-by-one into a single request**,
  then a prediction is asked. **Auto**: each edit is appended **as it happens**
  (and may trigger).
- **Auto only**: model may decline via the **no-edit token** (`*** No Edit`).

## Session layout (KV-cache aware, append-only between resets)

Stable cached **prefix** (built at session start / reset):
```
1 general instructions     (system)
2 examples                 (few-shots)
3 caveats                  (partial apply_patch tool; single small edit; no-op token)
4 other helpful details    (filename, filetype, indent, "this is NES")
5 seed prev edits          (on reset: last `reset_seed_edits`; first start: none)
6 full file state          (ENTIRE buffer at start/reset)
```
Then the appended **running log**, per round:
```
7  prev edits              (since last prediction; apply_patch-with-context, UNcoalesced)
8  file state after edits  (affected region; full buffer only at start/reset)
9  model response          (apply_patch patch + reasoning, OR read() call, OR no-op)
10 user result             (accepted / ignored / rejected-cycled / dismissed)
   … repeat 7–10 …
```

- **Edit history = the prev-edit turns**, no separate block. **Local
  change-tracking structure** (autocmd-driven; **no undotree**).
- **Not unified diffs** — each edit is an `apply_patch`-dialect `*** Update File`
  hunk **with expanded context** (`history_context_lines`, default 8). The
  explicit "file state after edits" snapshot additionally anchors ground truth.
- **Rolling reset** → fresh session when **edits ≥ `session_max_edits`
  (default 20)** or **idle ≥ `idle_reset_minutes` (20)**. The new session
  re-seeds the full buffer + last `reset_seed_edits` edits.
- **Capability reminder** every `capability_reminder_every` edits: only
  **Update File, one small hunk; no Add/Delete/Move**.

## Tools

- **`apply_patch`** — Codex format, **Update File only**, **exact (non-fuzzy)
  context match**.
- **`read(range?)`** — returns current buffer content (single buffer). On apply
  failure the model is instructed to `read` then retry (Codex re-anchor).

## Output

One **minimal** apply_patch edit — on a multi-site rename emit only the **next**
occurrence, not all. Or `read(...)`. Or `*** No Edit` (auto).
```
*** Begin Patch
*** Update File: <relpath>
@@ <context>
 ctx
-old
+new
*** End Patch
```

## Apply + validate loop — at suggestion time, before accept

```
predict(mode):
  flush pending edits   (manual: batch one-by-one in this single request; auto: already live)
  append predict turn (+ periodic capability reminder)
  for attempt = 1..MAX_ATTEMPTS (=3):              -- read() replies don't spend an attempt (cap max_reads=2)
    resp = model(session)
    if resp is read(range): append tool-result(buffer); continue
    if mode==auto and resp == NO_EDIT: record; return
    ok, new_lines, err = apply_patch(buf_lines, resp)          -- exact, in-memory
    if ok: append assistant(resp+reasoning); preview(buf -> new_lines); return
    append assistant(resp) + user("apply_patch failed: " .. err .. "; you may read() then retry")
  notify("duet: no valid patch in N attempts")

cycle():  append user("rejected; give a different next edit") → rerun loop on the fly
accept(): nvim_buf_set_lines(new_lines) + changedtick guard; append user("accepted")
dismiss(): append user("dismissed / ignored")
```

- Only a cleanly-applied patch is ever previewed. Accept never re-runs the model.

## Components

- `duet/session.lua` — local change-tracking + running message list; prefix build
  (full buffer); manual-batch vs auto-live flush; proposals + reasoning; user
  results; capability reminders; rolling reset with seed edits.
- `duet/apply_patch.lua` — parse + apply Codex patch (exact) → `ok, new_lines, err`.
- `duet/tools.lua` — `read` handler + `apply_patch` dispatch.
- `duet/init.lua` — predict / cycle / accept / dismiss + loop; normal-mode maps;
  auto-trigger autocmd + toggle.
- `duet/config.lua` — prompts, few-shots, knobs.

## Config (defaults)

```
provider = openai_compatible → openai/gpt-oss-120b, OpenRouter,
           reasoning.effort = low, route {cerebras, groq}
auto_trigger              = false
session_max_edits         = 20      -- rolling reset
idle_reset_minutes        = 20
reset_seed_edits          = 3       -- prev edits carried into a fresh session
history_context_lines     = 8       -- context per past edit
capability_reminder_every = 5
max_attempts              = 3
max_reads                 = 2
no_edit_token             = "*** No Edit"
```

## Out of scope (v1)

Multi-buffer, Add/Delete/Move-File hunks, streaming preview, undotree integration.

## Validated tool schema (live gpt-oss-120b probe, 2026-06-12)

Confirmed against `openai/gpt-oss-120b` on OpenRouter (`reasoning.effort=low`,
`provider.sort=throughput`): the model **calls `apply_patch` natively** and
returns a clean minimal Update-File patch. ~1.1 s round trip. Request shape:

```
tools = [
  { type=function, function={ name="apply_patch",
      parameters={ type=object, properties={ input={type=string} }, required=[input] } },
  { type=function, function={ name="read",
      parameters={ type=object, properties={ start_line=int, end_line=int } } } },
]
tool_choice="auto", reasoning={effort="low"}, provider={sort="throughput"}
```

Response: `choices[1].message.tool_calls[1].function` = `{name="apply_patch",
arguments="{\"input\":\"*** Begin Patch ...\"}"}`. Reasoning surfaced in
`message.reasoning`. (Also accept a `*** Begin Patch` in `message.content` as a
fallback.) NES behaviour confirmed: given one recent rename + cursor, it emitted
*only the next* occurrence's edit, not the whole batch.

## Build status (v1)

Dev: `~/code/lua/minuet-ai.nvim` branch `duet-nes`. Tests: `make test` (headless).

- [x] `duet/apply_patch.lua` — faithful Codex port (Update-File subset; exact→
      rstrip→trim matching). 16 specs, Codex test vectors ported. **green**
- [x] `duet/session.lua` — uncoalesced edit capture, apply_patch-with-context
      rendering (reuses `vim.diff`, round-trips through the applier), rolling
      reset, user-turn builder. 7 specs. **green**
- [x] tmux + `vim.pack`-style harness (`tests/harness/`) — drives real nvim by
      keystroke, applies a patch live. **green**
- [x] Live model premise validated (probe). **pass**
- [x] `duet/tools.lua` (apply_patch + read schemas, read handler) + `duet/chat.lua`
      (non-streaming tool-calling request). Transport spec drives the real
      curl→JSON→tool_call→apply path with a mock that guards body encoding.
- [x] `duet/config.lua` — NES system prompt, tool/session knobs, gpt-oss default.
- [x] `duet/init.lua` — predict/cycle/accept/dismiss session loop + read
      re-anchor + failure-retry + edit-capture autocmds + auto-trigger toggle.
      `:Minuet duet {predict,apply,dismiss,cycle,toggle}`.
- [x] repoint lazy `dir` → dev checkout (+ normal-mode `<C-*>` keymaps in
      `lua/plugins/minuet-ai.lua`).
- [x] **Live in-editor E2E (tmux + gpt-oss-120b): PASSED** — rename captured as
      history, `:Minuet duet predict` → preview → apply propagated the rename to
      the usage site. `tests/harness/e2e_duet.sh`.

**Status: v1 working end-to-end. `make test` = 69 green.** Follow-ups (not v1):
append-only session log with model turns for KV-cache reuse (currently the user
turn is rebuilt per predict from session state); few-shots; capability-reminder
cadence; streaming. Run `make format` (stylua) before pushing.
