# Duet Diff Viewer Investigation

Notes on improving the `Minuet duet` next-edit preview renderer. The immediate
problem is intraline focus highlighting for virtual-line diffs; the broader
problem is how to turn one predicted before/after edit into useful visual spans
and, eventually, smaller independently acceptable chunks.

## Current Design

- Outer line changes use Neovim's built-in diff API:
  `vim.text.diff` or `vim.diff`.
- The current options are:
  - `result_type = "indices"`
  - `algorithm = "histogram"`
  - `linematch = true`
- The virtual-lines viewer renders:
  - old buffer lines with `MinuetDuetDelete`
  - proposed lines as `virt_lines` with `MinuetDuetAdd`
  - intraline changed old spans with `MinuetDuetDeleteText`
  - intraline changed new spans with `MinuetDuetAddText`
- Intraline focus regions are currently found with a local token LCS:
  - whitespace runs are tokens
  - `[%w_]` runs are tokens
  - punctuation is one token per character
  - unchanged LCS matches become anchors
  - everything between anchors becomes an add/delete focus span

This is intentionally small and editor-native, but it has known limitations:
line pairing inside multi-line hunks is naive, and tokenization is not very
code-aware.

The local visualization page for these failure cases lives at
`experiments/duet-nes/diff-viewer-failures/index.html`.

## Goal

Keep Neovim rendering custom. Look for structured edit spans, not pre-rendered
diff text.

For this plugin, a useful diff result shape is:

```lua
{
    { side = "old", line = 12, start_byte = 40, end_byte = 42, kind = "delete" },
    { side = "new", line = 12, start_byte = 40, end_byte = 42, kind = "add" },
}
```

That maps directly to extmark ranges and virtual-line chunks.

## Go Diff Engine Candidates

For future work, a small Go helper could compute structured intraline spans and
return JSON. The renderer would still live in Lua.

| Candidate | Fit | Notes |
| --- | --- | --- |
| `znkr.io/diff` | Best structured token diff candidate | Diffs arbitrary slices and returns `Match`, `Delete`, and `Insert` edits. Fits token spans well. API is described as stable, while textual output is not, which is fine for us. |
| `github.com/sergi/go-diff/diffmatchpatch` | Mature char/string diff | Battle-tested diff-match-patch port. Good semantic cleanup, better for string/rune spans than explicit token spans. |
| `github.com/njchilds90/go-difflib` | Promising structured opcodes | Provides `GetOpCodes`, matching blocks, unified diffs, patching. Newer; should be vendor-tested before relying on it. |
| `github.com/pmezard/go-difflib/difflib` | Avoid as new core | Has `SequenceMatcher` and opcodes, but is no longer maintained. |
| `github.com/hexops/gotextdiff` | Good line/unified diff | More oriented toward unified text diffs than intraline span extraction. |
| `github.com/pkg/diff` | Lower-level framework | Useful pieces, but API is not v1/stable. |

Recommended future path if Lua becomes limiting:

```text
Neovim / Lua:
  vim.text.diff(... result_type = "indices", algorithm = "histogram", linematch = true)
  -> line hunks / candidate paired replacements

Go helper:
  tokenize paired old/new lines
  run structured token diff
  return JSON spans with byte offsets

Neovim / Lua:
  apply extmarks / virt_text / virt_lines
```

Avoid using `git diff --word-diff` for live editor rendering. It can be useful as
an oracle while testing, but spawning Git and parsing porcelain output is not a
good low-latency editor path.

## Better Tokenization

The current tokenization is intentionally simple. A more professional token model
would be more code-aware and still preserve byte offsets:

1. whitespace run
2. identifier run: Unicode letters, digits, underscore
3. number literal-ish run
4. operator run: `==`, `!=`, `<=`, `>=`, `:=`, `->`, `=>`, `::`, `&&`, `||`, etc.
5. quote/string chunk, optionally one token
6. punctuation fallback

Every token must carry 0-based byte offsets because Neovim extmark columns are
byte positions.

## Known Failure Cases

These are simple cases where the current token LCS is not as good as a polished
diff viewer.

### Subword Identifier Changes

```lua
getUserId()
getUserName()
```

The current tokenizer highlights the whole identifier instead of just `Id` to
`Name`.

### Snake Case Partial Changes

```lua
user_id = row.user_id
user_name = row.user_name
```

Because `_` is part of the word token, `user_id` and `user_name` become whole
tokens.

### Inserted Line Inside a Replacement Block

```lua
foo(1)
bar(2)
```

to:

```lua
log()
foo(1)
bar(3)
```

The current virtual-lines renderer may coalesce adjacent hunks and pair old/new
lines by position. A professional viewer would likely recognize `log()` as an
inserted line and `bar(2)` to `bar(3)` as the actual replacement.

### Reordered Arguments

```lua
plot(x, y, color)
plot(color, y, x)
```

The token LCS can show local replacements, but it does not communicate that
arguments moved.

### Repeated Tokens

```lua
value = item.value + old.value
value = old.value + item.value
```

Repeated tokens can cause technically valid but visually unintuitive anchors.

### Whitespace Formatting

```lua
foo(a,b,c)
foo(a, b, c)
```

Whitespace tokens can create noisy tiny highlights. Sometimes that is useful;
often it should be gated by a whitespace-aware mode.

## Tree-sitter Role

Tree-sitter is useful as a structure oracle, not as the whole differencer.

Good uses:

- partition changed spans into syntax islands
- validate whether a candidate chunk is syntactically safe
- identify injected languages and owning language tree
- derive semantic highlight colors for hypothetical proposed text
- inspect/debug with `:Inspect`, `:InspectTree`, and `vim.show_pos()`

Not good as the only solution:

- It does not provide a canonical mapping between old and new nodes.
- `TSNode:id()` is unique only inside one tree, not stable across snapshots.
- Exact tree edit distance is expensive; practical syntax-aware differencers use
  heuristics.

The practical design is:

```text
text diff -> changed byte ranges
Tree-sitter -> smallest meaningful syntax islands
temporary parse -> validate independent chunk safety
custom extmark renderer -> show chunks/spans
```

## Syntax Island Chunking

A robust chunking pipeline would look like this:

1. Compute a normal before/after text diff.
2. For each old-side changed span, ask Tree-sitter for the smallest enclosing
   named node.
3. Use injections when relevant, so embedded SQL, JSX, Markdown fences, regexes,
   etc. are assigned to the correct language tree.
4. Normalize islands:
   - merge edits inside the same meaningful expression/call/object/string
   - keep disjoint nodes separate when accepting one independently is plausible
   - merge sibling edits when accepting one without the other would be invalid
5. Map old-side islands to proposed replacements using textual anchors plus
   syntax metadata, not node IDs.
6. Validate each candidate island by applying it to a temporary snapshot and
   reparsing.
7. Expose only chunks that pass the acceptance policy.

Possible metadata for old/new correspondence:

```text
language
node type
field path / ancestor path
sibling ordinal among similar named siblings
old-side context anchors
subtree text hash
```

If correspondence confidence is low, fall back to a coarser text-range chunk.

## Parse Validation

`LanguageTree:is_valid()` is not a grammar-validity check. It only means the
parse tree reflects the latest source state.

For syntax validity, parse the candidate snapshot and check:

- `root:has_error()`
- `(ERROR)` query captures
- `(MISSING)` query captures

Minimal shape:

```lua
local function parse_ok(text, lang)
    local parser = vim.treesitter.get_string_parser(text, lang)
    local trees = parser:parse(true)
    local tree = trees and trees[1]
    if not tree then
        return false, "parse_failed"
    end

    local root = tree:root()
    if root:has_error() then
        return false, "has_error"
    end

    local query = vim.treesitter.query.parse(lang, [[
        [(ERROR) (MISSING)] @err
    ]])

    for _id, _node in query:iter_captures(root, text, 0, -1) do
        return false, "error_or_missing"
    end

    return true, tree
end
```

This is a grammar check, not a semantic check. LSP/compiler feedback would be
needed for undefined variables, type errors, missing imports, etc.

Acceptance policies:

- Strict: the whole file must parse cleanly.
- Local: the candidate chunk must not introduce new parse errors outside its own
  syntactic envelope.

For editor AI workflows, the local policy may feel better because users often
accept a sequence of edits before the final file is clean.

## Highlighting Hypothetical Text

Two useful strategies:

1. Scratch preview buffer:
   - put proposed content into a scratch/floating buffer
   - call `vim.treesitter.start(buf, lang)`
   - let Neovim render normal Tree-sitter highlights

2. String parser plus custom rendering:
   - parse proposed text with `vim.treesitter.get_string_parser()`
   - fetch highlight query with `vim.treesitter.query.get(lang, "highlights")`
   - iterate captures over the string
   - render captures as extmarks/virt text/virt lines in the real buffer

The second route gives finer control but requires enough surrounding synthetic
context for query patterns and injections to behave like the real file.

## Derived Highlight Groups

Tree-sitter captures can be used as highlight group names, such as `@string` or
`@variable.parameter`. A renderer can fetch the effective style with
`nvim_get_hl()` and derive a suggestion-specific group with `nvim_set_hl()`.

Example pattern:

```lua
local function derive_dimmed(ns, new_name, base_name)
    local base = vim.api.nvim_get_hl(0, { name = base_name, link = false })
    base.dim = true
    base.blend = math.max(base.blend or 0, 15)
    vim.api.nvim_set_hl(ns, new_name, base)
end
```

Notes:

- `hl_mode` currently affects `virt_text` highlights, not normal range
  `hl_group` highlights.
- For actual buffer text ranges, use real derived highlight groups.
- Use a private namespace and possibly per-window highlight namespaces.
- Decoration providers with ephemeral extmarks can be useful for transient
  suggestion rendering.

## Recommended Architecture

Near-term, keep the model interface text-based and keep Neovim's line diff as
the canonical edit source.

Recommended pipeline:

1. Model returns a proposed text state or direct replacement.
2. Compute text diff between current snapshot and proposed snapshot.
3. Pair likely old/new lines in replacement hunks.
4. Run intraline token diff to produce byte spans.
5. Render with extmarks and virtual lines.
6. Optionally use Tree-sitter to cluster spans into syntax islands.
7. Validate candidate islands by reparsing hypothetical snapshots.
8. Apply accepted chunks with `nvim_buf_set_text()` where possible, then recompute
   remaining chunks from the new buffer state.

The most valuable next improvement is better line pairing inside multi-line
replacement hunks. That should come before replacing the token LCS.

## Open Questions

- Should the Lua implementation grow a better line-pairing heuristic first, or
  should a Go helper own both pairing and intraline spans?
- How much should whitespace-only focus spans be shown by default?
- Should identifiers get subword splitting for camelCase and snake_case?
- Should syntax-island chunking be a viewer-only grouping first, before it
  becomes an accept-one-chunk feature?
- What is the minimum parse-validation policy that feels useful without blocking
  too many legitimate partial edits?

## Source Links From Investigation

- `znkr.io/diff`: https://github.com/znkr/diff
- Neovim Lua docs: https://neovim.io/doc/user/lua/
- Neovim diff docs: https://neovim.io/doc/user/diff/
- `sergi/go-diff/diffmatchpatch`: https://pkg.go.dev/github.com/sergi/go-diff/diffmatchpatch
- `njchilds90/go-difflib`: https://pkg.go.dev/github.com/njchilds90/go-difflib
- `pmezard/go-difflib/difflib`: https://pkg.go.dev/github.com/pmezard/Go-difflib/difflib
- `hexops/gotextdiff`: https://github.com/hexops/gotextdiff
- `pkg/diff`: https://pkg.go.dev/github.com/pkg/diff
- Neovim API docs: https://neovim.io/doc/user/api/
- Git diff docs: https://git-scm.com/docs/git-diff
