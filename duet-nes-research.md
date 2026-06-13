# Duet / NES research notes

Research toward improving the `Minuet duet` next-edit-prediction (NES) feature in
the `sergioahp/minuet-ai.nvim` fork. Comparing duet's current design against
real NES systems (Zed Zeta, Cursor Tab, Copilot NES) and against what `gpt-oss`
was actually trained on.

## Constraint: no access to real NES models

Like minuet's author, **we don't have the hardware** to self-host the
specialized open NES models (Zeta / Zeta2 / Zeta2.1, and the others named in
minuet's README). And **none of those NES models are available on OpenRouter**
— they were built to run inside their own editors, not as hosted inference. 😔

So Zeta-family is a **design reference only**, not a model we can call. Our
realistic target is a **general-purpose LLM behind an OpenAI-compatible API**:
specifically **gpt-oss-120B** served by **Cerebras or Groq via OpenRouter**
(chosen for low latency, which NES demands). This means:

- We inherit the author's core limitation — a general model doing NES, not a
  finetuned one — so prompt/format engineering does the heavy lifting.
- gpt-oss's native editing pathway (`apply_patch`, see below) becomes directly
  relevant since gpt-oss-120B is the actual target, not a hypothetical.
- The Zeta findings (up-to-6 coalesced edit diffs, region-rewrite output) are
  the *blueprint to reimplement in prompt form*, since we can't run Zeta itself.

## How duet works today (current fork code)

- **No edit history is sent. Zero prior edits.** `duet/context.build()` is the
  entire payload: one `nvim_buf_get_lines` snapshot sliced into
  non-editable-before / editable-region / non-editable-after, with a single
  `<cursor_position/>` marker. No diff, no undo history, no "recently typed".
- The `TextChanged*` autocmd uses edits only as a **cache-invalidation signal**
  (`clear_state`), never records them. README TODO confirms: *"Implement a
  proper diff mechanism to include recent edit changes in prompts."* — unbuilt.
- Output format: **whole-editable-region rewrite** wrapped in
  `<editable_region>…</editable_region>` with exactly one `<cursor_position/>`.
  Not a diff. Plugin diffs the rewrite against the original locally for preview.
- Recommended model: `gemini-3-flash-preview` (thinking minimal). Author notes
  `claude-haiku-4.5` and `gpt-5.4-mini` "perform poorly".
- **Implication:** without an edit trajectory the model can only answer "what
  completes/fixes this code" — fancy FIM, not true NES. The missing edit-history
  input is a bigger gap than the prompt format.

## Zed Zeta / Zeta2 — the real NES baseline

Open model + open dataset (`zed-industries/zeta` on HF) + open editor source.

- **Edit-history count: up to 6 recent edit events.** Enforced by
  `max_edit_event_count_for_format` returning `6` for all Zeta/Zeta2/Zeta2.1
  formats. Formatter does `events.iter().rev().take(6)`, newest-first until the
  token budget is exhausted, then emits chronologically. Also **budget-gated** —
  drops events (or the whole edit-history section) if they don't fit.
- Editor tracks more than it sends: project deque `EVENT_COUNT_MAX = 10`, but
  the prompt caps model-visible history at 6.
- **Events are coalesced**, not keystrokes: a change merges into the last event
  if it's the next snapshot of the same buffer, same source type, and within
  `CHANGE_GROUPING_LINE_SPAN = 8` lines. A pause of
  `LAST_CHANGE_GROUPING_TIME = 1s` drives `split_by_pause`, which splits the
  active `last_event` into before/after chunks when events are collected. The
  `events()` accessor returns stored events + a finalized view of the active
  `last_event`. Each event diff uses `CONTEXT_LINES = 3`; edits whose old/new
  region exceeds `EDIT_HISTORY_DIFF_SIZE_LIMIT = 2048*3` bytes aren't recorded.
- **Representation: unified diffs** in a pseudo-file `<filename>edit_history`,
  produced by `language::unified_diff_with_offsets(...)` with `---`/`+++`
  headers (written by `write_event`). Accepted predictions prefixed
  `// User accepted prediction:`. The formatter takes events newest-first up to
  `max_edit_event_count`, stops on budget, then reverses back to chronological.

### Zeta2 input format (Seed-Coder SPM order: suffix, prefix, middle)

```
<[fim-suffix]>
code after editable region
<[fim-prefix]><filename>related/file.py
related file content

<filename>edit_history
--- a/some_file.py
+++ b/some_file.py
-old
+new

<filename>path/to/target_file.py
code before editable region
<<<<<<< CURRENT
code that
needs to<|user_cursor|>
be rewritten
=======
<[fim-middle]>
```

Output = replacement text for the editable region, ending `>>>>>>> UPDATED`.
(Not a diff, not search/replace — a region rewrite.)

### Context / region sizing (Zeta)

- Cursor excerpt: largest symmetric linewise region fitting an **8192-token**
  budget (`bytes/3` estimate), syntax-node-boundary aware.
- Per-format region limits: editable `350` tokens / context `150` tokens for
  the SeedCoder/multi-region formats.
- Prompt budget by format: 4096 (most), 8192 (diagnostics), 16384 (single-file),
  with a 90% margin.

### Zeta vs Zeta2 vs Zeta2.1

- Edit-history cap is **6 across all of them**.
- Zeta1 (public dataset): human-readable `events`/`input`/`output` with markers
  `<|editable_region_start|>`, `<|user_cursor_is_here|>`, `<|editable_region_end|>`.
- Zeta2: Seed-Coder SPM tokens + `edit_history` pseudo-file + git-merge markers.
- Zeta2.1 (`V0318SeedMultiRegions`): same edit_history/6-cap, but numbered
  multi-region markers `<|marker_1|> … <|marker_2|>`; output repeats only the
  changed span.
- HF has model repos `zeta`, `zeta-2`, `zeta-2.1` but only **one** public
  dataset (`zeta`, the older format).

## Cursor Tab / Copilot NES — early-era history

- **Cursor Tab was never GPT-4 serving live.** Since Mar 2024 it's a custom
  sparse edit-prediction model (~475ms p50, 5.5k ctx), later "Fusion". Wire
  format not publicly disclosed (ghost text / diff popups at UX level only).
- Cursor *did* use GPT-4 in **Fast Apply / Instant Apply** (different pipeline):
  frontier model says what changes, custom apply model (fine-tuned Llama-3-70B)
  rewrites. They **preferred full-file rewrites over diffs** because models
  struggled with diff output. (Claude Opus was the exception that did diffs well.)
- **Copilot NES**: custom low-latency Copilot model, not a frontier model;
  trained on editor-session data, not PR diffs. Format undisclosed.
- **Windsurf Supercomplete**: UX-level info only, no model/format disclosed.

### Recurring pattern across all systems

```
old completion:    prefix + suffix            -> inserted text at cursor
next edit pred.:    recent edit history +
                    current file/editor state +
                    cursor                     -> next location + code change
```

Edit formats clustered into:
1. **rewrite-region / rewrite-file** — most reliable in production
   (Zed Zeta, Cursor Fast Apply). Input has cursor/editable markers + edit log.
2. compact patch / diff / search-replace — tried in evals, generally not
   favored (except strong models like Claude Opus).
3. two-stage location + edit — later Copilot-style long-distance NES.

**Takeaway: region/full-rewrite is the documented-reliable production format.**
Duet's whole-region-rewrite output choice is therefore *correct*; its missing
piece is the **recent-edit-history input** (Zeta sends up to 6 coalesced diffs).

## gpt-oss — what's actually native

- Trained with the **Harmony response format** (channels: analysis / commentary
  / final; roles; special tokens). OpenAI's `gpt-oss` repo documents
  **`apply_patch`** as a native-ish tool (create/update/delete files); terminal
  chat has `--apply-patch`.
- gpt-oss is **harness-sensitive**: with generic bash/diff scaffolds it looks
  mediocre; with native Harmony + `apply_patch` it lands near official numbers.
  arXiv "In harmony with gpt-oss" (Apr 2026): gpt-oss-120b called *undefined*
  `apply_patch` 860× in SWE-bench logs; adding a Codex-style `apply_patch` tool
  fixed it. HarmonyAgent reproduced gpt-oss-20b: 60.4% SWE Verified High (vs
  official 60.7%), 53.3% Medium (vs 53.2%).
- Model card: gpt-oss-120b 62.4% / gpt-oss-20b 60.7% SWE-Bench Verified (high);
  Aider Polyglot 44.4% / 34.2%. Aider leaderboard: 120b-high 41.8% on Polyglot
  via `diff` format, 79.1% well-formed.
- **Implication for duet:** if ever targeting gpt-oss, its trained-in editing
  pathway is `apply_patch` (a patch tool call), *not* free-text XML region
  markers. But Gemini/most chat models have no native edit format, so duet's
  custom-marker rewrite is as "native" as anything for them.

## Implementing an edit format (apply_patch & alternatives)

Research into actually wiring an edit format for gpt-oss-120B. Headline finding:
**there is no drop-in Lua implementation of Codex's `apply_patch` protocol** — a
port would be required.

### Two diff *directions* — don't conflate them

A real NES system has two distinct diff channels that want different formats:

| Direction | Purpose | Consensus format |
|---|---|---|
| **Input** (edit history / local changes → model) | context: "here's what just changed" | **unified diff** |
| **Output** (model → buffer) | the predicted edit to apply | **contested** (see below) |

- Input side is settled: Zeta's `edit_history` pseudo-file = unified diffs;
  Codex's `TurnDiffTracker.get_unified_diff()` emits git-style `diff --git`
  hunks (context radius 3, via `similar::TextDiff`), tracking only
  *agent-applied* deltas — never raw user keystrokes.
- **We already have the primitive.** Duet's preview uses
  `vim.text.diff or vim.diff` with `result_type = "indices"`, histogram,
  linematch. Serialize those hunks to unified diff and the edit-history input is
  nearly free. Apply is already just `nvim_buf_set_lines(range)` + `changedtick`
  guard.

### Output-format options for gpt-oss-120B

| Format | Pro | Con | Evidence |
|---|---|---|---|
| **region-rewrite** (duet today; Zeta; Cursor Fast Apply) | always applies; no parse failures | re-emits whole region = more output tokens / latency | production-reliable |
| **SEARCH/REPLACE** (Avante `replace_in_file`; aider `diff`) | per-hunk = fewer tokens; per-region, not whole-file | models malform ~21% | aider: gpt-oss-120b-high 41.8%, **79.1% well-formed** |
| **apply_patch text** (`*** Begin Patch …`) | gpt-oss-native (Harmony/Codex-trained; called it unprompted 860×) | **file-granular, heavyweight** for single-region NES; no Lua impl | arXiv "In harmony" |
| **apply_patch_call / V4A object** (Responses API tool) | JSON per-file; smallest to port (Python `apply_diff.py`) | object protocol, couples to OpenAI API shape | OpenAI docs |

**Granularity mismatch (key insight):** `apply_patch` is a *multi-file,
whole-repo* protocol (`*** Add/Update/Delete File: path`). Duet/NES edits a
*single region in one already-open buffer*. The apply_patch ceremony is overkill
there — its gpt-oss nativeness is the *only* reason to consider it.
**SEARCH/REPLACE is the natural middle ground**: per-region like NES wants,
diff-sized output (latency win over re-emitting the region), and gpt-oss emits it
~79% well-formed.

Caveat to the latency argument: duet's region is small (8 lines before / 15
after), so region-rewrite's extra output tokens aren't huge here — the
always-applies reliability of region-rewrite may still win at this scale. Eval
both on gpt-oss-120B before committing.

### Codex `apply_patch` grammar (reference if we port it)

```ebnf
start:        begin_patch hunk+ end_patch
begin_patch:  "*** Begin Patch" LF
end_patch:    "*** End Patch" LF?
hunk:         add_hunk | delete_hunk | update_hunk
add_hunk:     "*** Add File: " filename LF add_line+
delete_hunk:  "*** Delete File: " filename LF
update_hunk:  "*** Update File: " filename LF change_move? change?
change_move:  "*** Move to: " filename LF
change_context: ("@@" | "@@ " /(.+)/) LF
change_line:  ("+" | "-" | " ") /(.+)/ LF
eof_line:     "*** End of File" LF
```

Context matching is fuzzy: exact → `rstrip` → `strip` with fuzz scores (Python);
Rust seeks anchors/context and errors if expected old lines aren't found.

### Reference implementations

- **Codex Rust** `openai/codex/codex-rs/apply-patch` — canonical parser/applicator.
- **OpenAI Agents Python** `apply_diff.py` — compact V4A per-file core, easiest port.
- **Avante** (`replace_in_file`) — **Neovim UX only**, not Codex-compatible:
  SEARCH/REPLACE blocks (`------- SEARCH` / `=======` / `+++++++ REPLACE`),
  fuzzy match, `vim.diff` histogram/indices, streaming extmark preview,
  accept/reject. (Its `enabled()` returns false in the checked rev.) We run an
  avante fork, so this codebase is already familiar — good UX donor.

## Open design questions for the fork

- [ ] Add recent-edit-history to the duet prompt (the core missing input).
      Mirror Zeta: coalesced edits as unified diffs, cap ~6, budget-gated.
      Serialize duet's existing `vim.diff` indices → unified diff (cheap).
- [ ] Decide event coalescing rules (line-span grouping, pause splitting).
- [ ] Token-budget the edit-history section like Zeta (newest-first, drop on
      overflow).
- [ ] **Output format for gpt-oss-120B: eval SEARCH/REPLACE (per-region,
      diff-sized, ~79% well-formed) vs region-rewrite (always-applies).**
      SEARCH/REPLACE is the leading candidate; apply_patch is whole-file
      granularity = likely wrong fit for single-region NES.
- [ ] If apply_patch is chosen anyway: port from Codex Rust or Python
      `apply_diff.py` — no Lua impl exists.
- [ ] Reuse the avante fork's UX (streaming extmark preview, accept/reject,
      fuzzy SEARCH/REPLACE matching) regardless of chosen format.

## Sources

- gpt-oss: github.com/openai/gpt-oss; arXiv 2604.00362 ("In harmony with
  gpt-oss"); arXiv 2508.10925 (model card); aider.chat/docs/leaderboards
- Zeta: huggingface.co/zed-industries (`zeta`, `zeta-2`, `zeta-2.1` + `zeta`
  dataset); github.com/zed-industries/zed (edit-prediction/zeta crates);
  zed.dev/blog/edit-prediction
- Cursor: cursor.com/blog/tab-update; cursor.com/blog/instant-apply
- Copilot: githubnext.com/projects/copilot-next-edit-suggestions
- apply_patch: openai/codex `codex-rs/apply-patch` (Rust); OpenAI Agents Python
  `apply_diff.py`; developers.openai.com/api/docs/guides/tools-apply-patch
- Avante UX: `replace_in_file` tool (SEARCH/REPLACE blocks, `vim.diff` histogram)
