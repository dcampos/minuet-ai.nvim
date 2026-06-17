# Virtual-text completion lock across partial accepts

Notes on the per-state "lock" that keeps already-seen ghost text stable, the
mid-accept rug pull it had, the fix shipped on `duet-nes`, and the parts we
agreed to revisit later.

All code references are in `lua/minuet/virtualtext.lua`.

## What the lock is for

The design goal: **once the user has seen some virtual text, it must not change
on its own.** A completion shown for a given buffer state becomes "locked" to
that state and stays priority #1 on the virtual-text candidate list, regardless
of fresher completions arriving later. Only the user moving the choice (a
**cycle**, `advance`) or dismissing drops/replaces the lock. This is what makes
background top-ups, retries, and one-off requests (other models, longer
`stop = "\n\n"` responses fired by reaching into the plugin) safe: they refill
the cache without yanking the text out from under the user.

Implementation:

- `ctx.locks` is a small ring (`MAX_LOCKS = 8`). Each entry is
  `{ completion, params, lines_before, lines_after }` — the completion shown at
  a state, keyed by request params plus the before/after-cursor context.
- `compatible_lock` finds the most-recent lock whose `lines_before` still
  prefix-matches the current windowed before-cursor text (via
  `prefix_typed_since`) and whose head equals what the user has typed since. It
  returns the **untyped remainder** to display.
- `derive_suggestions` consults `compatible_lock`: if a lock is pinned, that
  completion is forced to the active choice (appended past the hard band if
  needed) instead of the natural longest-prefix ranking.
- `set_lock` records / updates a lock. A **cycle** (`advance`) calls it to
  re-lock the state to the newly chosen completion.

The before-cursor context is a fixed-size **window** (`context_before_chars`).
Once the text before the cursor is longer than the window, the window
left-truncates and `is_incomplete_before` becomes true.

## The bug: rug pull during step-by-step multiline accept

Workflow that triggered it: accepting a long / multiline completion in pieces —
a few lines, then a few words (`accept_line`, `accept_word`), expecting the
ghost text to stay put between accepts.

On a **partial accept**, `accept_n_chars` slid only the **cache** forward:

- `slide_cache_after_accept(ctx, accepted)` extends each cache entry's
  `lines_before` by the accepted text and strips that head off its completions,
  so cache entries keep tracking the cursor (priority #1 across long
  accept-word sessions — this is intentional and documented in its comment).

…but it left the **locks** anchored at the *pre-accept* state. As the user kept
accepting, the before-cursor window grew and eventually slid **past** the lock's
original `lines_before`. At that point `prefix_typed_since` returns `nil`,
`compatible_lock` stops matching, and the family is no longer pinned. The next
background top-up (or one-off request) that landed then re-derived by the
natural ranking and **repainted different ghost text** — the rug pull.

It is intermittent because short accepts never cross the window boundary; only
longer multiline step-by-step accepts do.

## The fix

`slide_locks_after_accept` — the lock-ring analogue of
`slide_cache_after_accept`, called in the `has_remaining` branch of
`accept_n_chars` (right beside the cache slide):

```lua
local function slide_locks_after_accept(ctx, accepted)
    if not ctx.locks or #accepted == 0 then
        return
    end
    for _, lock in ipairs(ctx.locks) do
        if #lock.completion > #accepted and lock.completion:sub(1, #accepted) == accepted then
            lock.completion = lock.completion:sub(#accepted + 1)
            lock.lines_before = lock.lines_before .. accepted
        end
    end
end
```

It re-anchors the just-accepted family's lock at the new post-accept state with
the accepted head stripped, so the remainder stays priority #1. It uses the same
forward-anchoring trick as the cache slide: a growing `lines_before` stays
matchable through the `is_incomplete_before` branch of `prefix_typed_since`.
`lines_after` is untouched (an insert at the cursor leaves the suffix). This is
the same "re-lock to the new state" the cycle path already does, applied to the
accept path.

Scoping decisions:

- **Only in the `has_remaining` branch.** A full accept resets context; sliding
  a lock to an empty remainder would paint an empty ghost-with-counter glitch.
  The `#lock.completion > #accepted` guard also skips fully-consumed siblings.
- **Deliberately not added to the plain-typing / `derive_suggestions` path.**
  There the cache is *not* slid (it stays anchored at request state), so locks
  staying anchored is consistent — and re-anchoring forward on every keystroke
  would regress the backspace-realign recovery path (a lock anchored ahead of
  the cursor cannot be matched after a backspace). Accept is a committed forward
  motion that already slides the cache, so sliding the lock alongside it is the
  matching behavior; plain typing is left as-is.

### Verification

A standalone simulation replicating the real matching functions
(`prefix_typed_since`, `suffix_compatible`, `compatible_lock`) confirmed:

- **Without the slide:** the lock breaks (`match=false`) the moment the window
  truncates, on every subsequent accept step.
- **With the slide:** the lock resolves to the exact remaining completion
  (`match=true`) at every step.

The file also parses under LuaJIT (Neovim's runtime; plain `lua5.1` rejects the
pre-existing `goto`).

## To revisit later

- **Plain forward-typing through a completion** has the same window-boundary
  class of bug as the old accept path: typing the completion's text char by char
  (rather than accepting) grows the window and can eventually slide past the
  lock's anchor. Not fixed here because re-anchoring on every keystroke trades
  off against backspace recovery (see scoping above). Worth a dedicated decision:
  is there a re-anchor rule that keeps both forward-type stability *and*
  backspace recovery (e.g. re-anchor only once `is_incomplete_before` is about
  to drop the anchor, or carry the original anchor separately from a moving
  display anchor)?
- **Lock-ring churn / dead `changedtick`.** Worth confirming the ring stays
  healthy across long sessions. Separately, `entry.changedtick` is written by
  `slide_cache_after_accept` but appears to no longer be read by
  `pool_suggestions` — its comment references a "typed_since==0 stale guard" that
  is not present in the current code. Likely dead after a refactor; verify and
  remove if so.
- **One-off requests interplay.** The lock keys on `params`, so a one-off with
  different model / `stop` tokens forms its own family. Confirm that mixing a
  default-stop multiline completion with a `stop = "\n\n"` one-off at the same
  state behaves as intended (each pins independently; neither overwrites the
  other's locked view).
