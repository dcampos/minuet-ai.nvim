# Duet NES — apply_patch spec (v1, tuned; v2 direction noted)

NES for `Minuet duet`. One model (`gpt-oss-120b` via OpenRouter, Cerebras/Groq),
**no separate apply model**. **Normal mode only, single buffer; modifiable real
file buffers only** (`buftype == ''` and `modifiable` — the inspect float,
read-only views, and other scratch/special buffers are skipped, so an auto-trigger
never leaks onto non-file content). Each prediction
the model sees the recent user edits (apply_patch dialect), the current file, and
the **cursor as a separate note** (kept out of the file/patch text); it emits one
small Codex-style `apply_patch` (or calls `read`); we **validate by applying
before preview**. Rationale: `duet-nes-research.md`.

> Status: v1 shipped and then tuned on branch `duet-nes` (decisive prompt,
> cursor-as-note, `effort=low` re-validated, Cerebras/Groq pin, post-accept
> burst, `:Minuet duet inspect` introspection). The “bigger edits per request”
> idea is aspirational — see **Direction (v2)**. `make test` = 69 green.

## UX (mirrors minuet completion, but normal mode)

- Commands: `:Minuet duet {predict, apply, dismiss, cycle, toggle, inspect}`.
  Normal-mode maps are the **user's** (the dev config uses `<Tab>` = accept the
  shown suggestion else predict, `<S-Tab>` = toggle duet + virtualtext
  auto-trigger together, `<leader>M` = toggle the inspect float).
- **One suggestion at a time.** Cycle = regenerate **on the fly** (no prefetch
  pool). *(v1; revisited in “Direction (v2)” below — batch the model, queue locally.)*
- Edits are captured (uncoalesced) by autocmd. **Manual trigger** (`predict`) is
  immediate (no debounce). **Auto-trigger** fires on `TextChanged`/`InsertLeave`
  after `debounce_ms` (150). After an **accept**, when auto is on, the next
  prediction is fired **immediately** (no debounce) so bursts feel instant.
- **Auto only**: model may decline via the **no-edit token** (`*** No Edit`). A
  **manual** trigger must produce an edit — a `*** No Edit` reply there is pushed
  back to the model as invalid and it is asked to retry (spends an attempt).
- **Inspect**: `:Minuet duet inspect` toggles a floating window with the session
  history (newest first): per prediction the model **reasoning**, emitted
  **patch**, `read()` calls, **outcome**, and **result**
  (accepted / dismissed / rejected-cycled / ignored). Full inputs shown for the
  latest only.

## Message assembly (as built)

Each predict sends: the system message, then the **inter-diff memory** (this
session's earlier predictions replayed as interleaved turns), then the final user
turn (rebuilt from session state):

```
system : decisive NES system prompt  +  capability reminder  +  decline policy
         (decline policy: auto = may reply `*** No Edit`; manual = must emit an edit)
memory : (prediction_memory, default on) preamble user turn, then per earlier
         prediction this session: assistant = the patch it proposed,
         user = the disposition ("The user accepted it." / "…did not use it." /
         "…dismissed it." / "…rejected it and asked for a different edit").
         Capped to the last `prediction_memory_max` (8); cleared on session reset.
user   : 1 cursor note    ("Editor cursor: line L, column C; that line reads `…`")
         2 recent edits   ("Recent edits (oldest to newest):" + apply_patch blocks)
         3 current file   ("Current file `path`:" + ENTIRE buffer, clean)
         (cycle only) + "already proposed and rejected; propose a DIFFERENT edit"
```

- **Inter-diff memory is ADDITIVE** — it precedes but never replaces the full
  current file. Benchmarked on the duplicated-tableau pivot: replaying the model's
  own prior guesses + accept/ignore dispositions lifted exact-next-cell hit rate
  ~29% → ~42% at zero extra latency, while *replacing* the file with a diff log
  (the model reconstructing state) regressed it. Re-feeding the model's reasoning
  did not help (and the native `reasoning` field is dropped on history turns), so
  only the facts (patch + disposition) are carried. Harnesses:
  `experiments/duet-nes/scripts/nes_interdiff{,2,3}.lua`.

- **Cursor is a separate note**, never an inline marker — an inline `<|cursor|>`
  is out-of-distribution for an apply_patch-trained model (it got copied into
  patches and biased reverts). The file/patch text stays clean.
- **Edit history**: a **local change-tracking structure** (autocmd-driven, **no
  undotree**) captures edits **uncoalesced**; each is rendered as an
  `apply_patch`-dialect `*** Update File` hunk with expanded context
  (`history_context_lines`, default 8).
- **Rolling reset** → fresh session when **edits ≥ `max_edits` (20)** or **idle ≥
  `idle_minutes` (20)**; the new session re-seeds the last `seed_edits` (3).
- **Capability reminder** is currently appended to **every** system prompt (the
  `capability_reminder_every` cadence knob is defined but unused).

Partly realized: the **inter-diff memory** above now carries the per-round
**model response (its patch) + user result** as interleaved turns. Still
aspirational is the full **KV-cache-aware** form — a stable cached prefix (full
file at reset) with only diffs appended; today the memory is prepended but the
final user turn (full file) is still rebuilt each predict, so the prefix is not
cache-stable.

## Tools

- **`apply_patch`** — Codex format, **Update File only**, **exact (non-fuzzy)
  context match**, **biased to the cursor**: when a hunk's context matches several
  identical blocks (e.g. a duplicated table), it lands on the occurrence NEAREST
  the cursor row instead of the topmost (a unique match is unaffected). `init`
  passes the cursor row into `apply_patch.apply { cursor_row = … }`; the system
  prompt tells the model minimal hunks suffice (no line-counting / no `read` for
  line numbers).
- **`read(range?)`** — returns current buffer content (single buffer). The prompt
  tells the model it **already has the full current file**, so emit directly and
  only `read` to re-check exact text **if a patch it tried this turn failed**
  (Codex re-anchor). Reads are capped (`max_reads`, 2) and **enforced** (hitting
  the cap stops the loop rather than re-requesting forever).

## Mercury Edit 2 Provider

`duet.provider = 'inception_edit'` uses Inception's Mercury Edit 2
`/v1/edit/completions` endpoint instead of chat tool calls. The request is built
in Mercury's native Next Edit format:

```
<|recently_viewed_code_snippets|> ... <|/recently_viewed_code_snippets|>
<|current_file_content|>
current_file_path: ...
... full file, with <|code_to_edit|> around a small cursor-centered region ...
<|/current_file_content|>
<|edit_diff_history|>
--- path
+++ path
@@ -a,b +c,d @@
...
<|/edit_diff_history|>
```

Mercury returns the rewritten editable region in a Markdown fence. The transport
converts that replacement back to a normal apply_patch hunk, so the existing
preview/apply/disposition machinery stays unchanged. If Mercury returns the same
editable region unchanged, auto mode treats it as `*** No Edit`; manual mode
stops with a provider error instead of retrying the identical native prompt.
Endpoint probe result: direct Inception works; OpenRouter currently rejects
`inception/mercury-edit-2` on `/chat/completions` as an invalid model ID, and
`/api/v1/models` lists `inception/mercury-2` but not `inception/mercury-edit-2`,
so this provider uses the direct Inception API (`INCEPTION_API_KEY`).

## Output

One **minimal** apply_patch edit — on a multi-site rename emit only the **next**
occurrence, not all. Be **decisive** (act on a single recent edit if it looks
repeatable), but match the user's **edit granularity**: if recent edits are
one literal/token at a time, predict one literal/token next rather than a
whole-line or whole-block rewrite. **Never revert** a recent edit or emit a
**no-op**; never put the cursor note inside a patch. Or `read(...)`. Or
`*** No Edit` (**auto only**; rejected and retried on a manual trigger).
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
  build messages (cursor note + recent edits + current file; cycle adds a reject nudge)
  for attempt = 1..max_attempts (=3):              -- read() replies don't spend an attempt
    resp = model(session)
    if resp is read(range):
      if reads >= max_reads (=2): stop            -- enforced; no unbounded read loop
      append tool-result(buffer); continue
    if resp == NO_EDIT:
      if mode == auto: record; return                          -- declining is allowed
      append assistant(resp) + user("`*** No Edit` invalid: manual trigger must edit")
      attempt += 1; continue                                   -- manual: push back and retry
    ok, new_lines, err = apply_patch(buf_lines, resp)          -- exact, in-memory
    if ok: preview(buf -> new_lines); record turn; return
    append assistant(resp) + tool("apply_patch failed: " .. err .. "; read() then retry")
  notify("duet: no valid patch in N attempts")

cycle():   mark current result=rejected; rerun predict with "give a DIFFERENT edit"
accept():  changedtick guard; nvim_buf_set_lines(new_lines); rebase baseline;
           move cursor to the first changed line; if auto → predict('auto') NOW
           (burst — nvim_buf_set_lines does not fire TextChanged, so fire explicitly)
dismiss(): clear preview; mark result=dismissed
```

- Only a cleanly-applied patch is ever previewed.
- **Accept re-runs the model** only as the burst (auto on); the accepted edit
  itself is applied locally without a model call.
- Each predict appends a record to the session transcript (`M.history`, capped),
  and `accept/dismiss/cycle`/supersession set that record's **result**.

## Components

- `duet/session.lua` — local change-tracking; `render_edit` (apply_patch-with-
  context, reuses `vim.diff`); `build_user_turn` (cursor note + edits + file);
  rolling reset with seed edits.
- `duet/apply_patch.lua` — parse + apply Codex patch (exact) → `ok, new_lines, err`.
- `duet/tools.lua` — `read` handler + `apply_patch`/`read` schemas.
- `duet/chat.lua` — non-streaming tool-calling request (curl → JSON → message).
- `duet/init.lua` — predict / cycle / accept / dismiss + loop; edit-capture
  autocmd + auto-trigger toggle + post-accept burst; per-prediction transcript
  (`M.last` / `M.history`).
- `duet/inspect.lua` — the introspection float (session history render + toggle).
- `duet/config.lua` — prompt + knobs (provider, effort, session).

## Config (defaults)

```
provider           = openai_compatible → openai/gpt-oss-120b, OpenRouter
request_timeout    = 15
optional           = reasoning.effort = 'medium'   -- 'low' reverts/stalls on multi-step edits
                     provider = { order = { 'cerebras', 'groq' }, allow_fallbacks = false }
session = {
  history_context_lines     = 8     -- context per past edit
  max_edits                 = 20    -- rolling reset cap
  idle_minutes              = 20    -- rolling reset idle
  seed_edits                = 3     -- prev edits carried into a fresh session
  capability_reminder_every = 5     -- (defined; not yet used — reminder is every turn)
  max_attempts              = 3
  max_reads                 = 2     -- enforced
  prediction_memory         = true  -- replay prior predictions + dispositions (interleaved)
  prediction_memory_max     = 8     -- cap on replayed predictions; reset with the session
  auto_trigger              = false
  debounce_ms               = 150   -- auto-trigger only; manual + post-accept burst = no wait
  no_edit_token             = '*** No Edit'
}
```

`effort = 'low'` was re-validated against the decisive prompt (the earlier reverts
were the old vague prompt + inline cursor marker): at low, first-turn rename
k=1/k=2 and a local finish-at-cursor edit were all 10/10 forward, 0 reads, 0 bad
patches.

## Out of scope (v1)

Multi-buffer, Add/Delete/Move-File hunks, streaming preview, undotree integration.

## Direction (v2 hypothesis): bigger model edits, granular user approval

Latency is dominated by the per-request round trip (~0.4–0.5 s on Cerebras). v1
does **one small edit per request**, so an N-site change costs N round trips even
with the post-accept burst (accept → immediately re-request). Suspected better
direction: **decouple how much the model does per request from how finely the
user approves.**

- **Model: more per request.** Ask for the next *K* edits in one call (several
  ordered `*** Update File` hunks, or a short plan + hunks), not just the single
  next occurrence.
- **User: still small.** Keep cycle / accept / dismiss at one-small-edit
  granularity, but serve them from a **local queue** of the buffered hunks — no
  new request per accept. Re-request only when the queue drains or the user
  diverges.
- **Net:** amortize the round trip across several edits → snappier bursts, with
  user control unchanged. This reverses the v1 “one suggestion at a time, no
  prefetch pool” decision (UX §).

Tensions to resolve:
- **Staleness.** Later hunks may not apply after earlier accepts. Re-validate
  each queued hunk against the *current* buffer right before preview; drop or
  re-anchor (or refetch) any that no longer match exactly. Only a cleanly-applying
  hunk is ever previewed (v1 invariant holds per-hunk).
- **Divergence.** If the user makes an edit that is not the next queued hunk, the
  batch was predicated on a plan that no longer holds → invalidate the queue and
  refetch.
- **Preview granularity.** Still preview only the next hunk; accept advances the
  queue and moves the cursor to the next hunk’s site.
- **cycle semantics.** cycle = skip this site (preview the next queued hunk) vs a
  separate “reject all / regenerate” for a fresh batch.
- **Does the model batch well?** Current prompt asks for exactly one hunk; v2
  needs “emit the next K edits as separate, ordered Update File hunks”. Bench
  before committing: multi-hunk apply-success, and the **staleness rate** (how
  many queued hunks still apply after sequential accepts).

Open: K (a small fixed cap, e.g. 3–5, vs “as many as clearly follow the same
pattern”); whether to stream hunks for first-paint latency; how this interacts
with the introspection log (one record per batch, with per-hunk results).

## Validated tool schema (live gpt-oss-120b probe, 2026-06-12)

Confirmed against `openai/gpt-oss-120b` on OpenRouter: the model **calls
`apply_patch` natively** and returns a clean minimal Update-File patch. With the
Cerebras/Groq pin a cold round trip is ~0.49 s (served by Cerebras). Request
shape:

```
tools = [
  { type=function, function={ name="apply_patch",
      parameters={ type=object, properties={ input={type=string} }, required=[input] } },
  { type=function, function={ name="read",
      parameters={ type=object, properties={ start_line=int, end_line=int } } } },
]
tool_choice="auto", reasoning={effort="low"},
provider={order=["cerebras","groq"], allow_fallbacks=false}
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

- [x] **Tuning** (benched against live gpt-oss-120b, see `experiments/duet-nes/`):
      decisive prompt; cursor as a separate note (not inline marker); `effort=low`
      re-validated; Cerebras/Groq pin; `max_reads` enforced.
- [x] **Post-accept burst** — accept chains the next prediction immediately
      (auto on), since `nvim_buf_set_lines` does not fire `TextChanged`.
- [x] **Introspection** — `:Minuet duet inspect` float over `M.history`
      (reasoning / patch / outcome / per-prediction result).

**Status: working end-to-end and tuned. `make test` = 69 green.** Follow-ups:
the append-only KV-cached session log (today the user turn is rebuilt per
predict); few-shots; capability-reminder cadence; streaming; and the
**Direction (v2)** batch-the-model experiment. Run `make format` (stylua) before
merging to `main`.
