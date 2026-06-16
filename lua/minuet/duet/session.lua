-- Duet NES session: local edit-history tracking (no undotree) and the
-- KV-cache-aware message assembly for a long-lived "code session".
--
-- Edits are captured uncoalesced (one record per change burst) and rendered in
-- apply_patch dialect WITH expanded context, so the model tracks real buffer
-- state. See duet-nes-spec.md.

local nes = require 'minuet.duet.nes_context'

local M = {}

local function get_diff(a, b, ctxlen)
    local diff = (vim.text and vim.text.diff) or vim.diff
    return diff(a, b, {
        result_type = 'unified',
        algorithm = 'histogram',
        ctxlen = ctxlen,
    })
end

local function clean_diff_lines(unified)
    local lines = vim.split(unified, '\n', { plain = true })
    if lines[#lines] == '' then
        table.remove(lines)
    end
    local out = {}
    for _, line in ipairs(lines) do
        if line:sub(1, 1) == '\\' then
            -- drop git's "\ No newline at end of file" marker
        else
            table.insert(out, line)
        end
    end
    return out
end

--- Render a single edit (before -> after) as an apply_patch update block with
--- `ctx_lines` of surrounding context. Reuses nvim's diff and rewrites the
--- `@@ -a,b +c,d @@` headers into bare `@@` (apply_patch dialect). Returns nil
--- when there is no change.
---@param before string[]
---@param after string[]
---@param path string
---@param ctx_lines? integer
---@return string?
function M.render_edit(before, after, path, ctx_lines)
    ctx_lines = ctx_lines or 8
    local a = table.concat(before, '\n')
    local b = table.concat(after, '\n')
    if a == b then
        return nil
    end

    local unified = get_diff(a, b, ctx_lines)
    if not unified or unified == '' then
        return nil
    end

    local out = { '*** Begin Patch', '*** Update File: ' .. path }
    for _, line in ipairs(clean_diff_lines(unified)) do
        if line:sub(1, 2) == '@@' then
            table.insert(out, '@@')
        else
            table.insert(out, line)
        end
    end
    table.insert(out, '*** End Patch')
    return table.concat(out, '\n')
end

--- Extract the single bounding changed region between two line arrays as the
--- before/after blocks of one edit. Spans across hunks (so several edits in the
--- same area read as one block before -> block after), matching the range-based
--- representation Mercury Edit's `edit_diff_history` was trained on. Returns nil
--- when nothing changed.
---@param before string[]
---@param after string[]
---@return string[]? original, string[]? updated, integer? start_line
function M.diff_region(before, after)
    local a = table.concat(before, '\n')
    local b = table.concat(after, '\n')
    if a == b then
        return nil
    end
    local hunks = vim.diff(a, b, { result_type = 'indices', algorithm = 'histogram' })
    if not hunks or #hunks == 0 then
        return nil
    end
    local a_lo, a_hi, b_lo, b_hi
    for _, h in ipairs(hunks) do
        local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
        if ca > 0 then
            a_lo = a_lo or sa
            a_hi = sa + ca - 1
        end
        if cb > 0 then
            b_lo = b_lo or sb
            b_hi = sb + cb - 1
        end
    end
    local original = a_lo and vim.list_slice(before, a_lo, a_hi) or {}
    local updated = b_lo and vim.list_slice(after, b_lo, b_hi) or {}
    return original, updated, (b_lo or a_lo or 1)
end

local function count_nonempty(lines)
    local n = 0
    for _, l in ipairs(lines) do
        if l ~= '' then
            n = n + 1
        end
    end
    return n
end

--- Render one edit-history entry in Mercury Edit's `edit_diff_history` dialect:
--- per-entry `--- / +++` headers, a synthetic `@@ -1,N +1,M @@` hunk (N/M count
--- the non-empty lines), then every non-empty original line as `-` and every
--- non-empty updated line as `+`. Blank lines are dropped, exactly as the
--- reference implementation does. `original`/`updated` are newline-joined blocks.
---@param entry { original: string, updated: string }
---@param path string
---@return string
function M.render_diff_entry(entry, path)
    local original = vim.split(entry.original, '\n', { plain = true })
    local updated = vim.split(entry.updated, '\n', { plain = true })
    local out = {
        '--- ' .. path,
        '+++ ' .. path,
        ('@@ -1,%d +1,%d @@'):format(count_nonempty(original), count_nonempty(updated)),
    }
    for _, l in ipairs(original) do
        if l ~= '' then
            out[#out + 1] = '-' .. l
        end
    end
    for _, l in ipairs(updated) do
        if l ~= '' then
            out[#out + 1] = '+' .. l
        end
    end
    return table.concat(out, '\n')
end

--- Render a single before -> after edit straight to the `edit_diff_history`
--- block (convenience over diff_region + render_diff_entry). Returns nil when
--- nothing changed.
---@param before string[]
---@param after string[]
---@param path string
---@return string?
function M.render_edit_diff(before, after, path)
    local original, updated = M.diff_region(before, after)
    if not original then
        return nil
    end
    return M.render_diff_entry({ original = table.concat(original, '\n'), updated = table.concat(updated, '\n') }, path)
end

-- ---------------------------------------------------------------------------
-- Per-buffer edit tracker
-- ---------------------------------------------------------------------------

M.states = {}

local function buf_path(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == '' then
        return '[No Name]'
    end
    return vim.fn.fnamemodify(name, ':.')
end

local function get_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---@param bufnr integer
---@return table state
function M.get_state(bufnr)
    local state = M.states[bufnr]
    if not state then
        state = {
            baseline = get_lines(bufnr),
            edits = {},
            diff_entries = {},
            seed = {},
            seed_diff_entries = {},
            started_ms = vim.uv.now(),
            last_ms = vim.uv.now(),
        }
        M.states[bufnr] = state
    end
    state.diff_entries = state.diff_entries or {}
    state.seed_diff_entries = state.seed_diff_entries or {}
    return state
end

-- Edit-history coalescing/decay thresholds (mirrors cursortab.nvim).
local DIFF_PROXIMITY_LINES = 8
local DIFF_PAUSE_MS = 1000
local DIFF_MAX_ENTRIES = 5
local DIFF_IDLE_MS = 5 * 60 * 1000

local function join_nonempty(a, b)
    if a == '' then
        return b
    end
    if b == '' then
        return a
    end
    return a .. '\n' .. b
end

--- Re-snapshot the baseline (call on attach or after a prediction is applied so
--- the next captured edit is measured from the new state).
function M.rebase(bufnr)
    local state = M.get_state(bufnr)
    state.baseline = get_lines(bufnr)
end

--- Capture one edit: diff the current buffer against the stored baseline, record
--- it (uncoalesced), and advance the baseline. Returns the rendered block, if any.
---@param bufnr integer
---@param ctx_lines? integer
---@return string?
function M.capture(bufnr, ctx_lines)
    local state = M.get_state(bufnr)
    local cur = get_lines(bufnr)
    local block = M.render_edit(state.baseline, cur, buf_path(bufnr), ctx_lines)
    if block then
        table.insert(state.edits, block)

        -- Structured edit_diff_history entry, coalesced with the previous one when
        -- this edit is close in time and line proximity (so rapid same-area edits
        -- read as a single range-based block).
        local original, updated, start_line = M.diff_region(state.baseline, cur)
        if original then
            local now = vim.uv.now()
            local entry = {
                original = table.concat(original, '\n'),
                updated = table.concat(updated, '\n'),
                start_line = start_line,
                ts_ms = now,
            }
            local last = state.diff_entries[#state.diff_entries]
            if
                last
                and (now - last.ts_ms) < DIFF_PAUSE_MS
                and math.abs(last.start_line - entry.start_line) <= DIFF_PROXIMITY_LINES
            then
                last.original = join_nonempty(last.original, entry.original)
                last.updated = join_nonempty(last.updated, entry.updated)
                last.start_line = math.min(last.start_line, entry.start_line)
                last.ts_ms = now
            else
                table.insert(state.diff_entries, entry)
            end
            while #state.diff_entries > DIFF_MAX_ENTRIES do
                table.remove(state.diff_entries, 1)
            end
        end

        state.baseline = cur
        state.last_ms = vim.uv.now()
    end
    return block
end

---@param bufnr integer
---@return string[] blocks since session start / last reset
function M.edits(bufnr)
    return M.get_state(bufnr).edits
end

---@param bufnr integer
---@return { original: string, updated: string, start_line: integer, ts_ms: integer }[]
function M.diff_entries(bufnr)
    return M.get_state(bufnr).diff_entries
end

--- Whether the session should roll over to a fresh context.
---@param bufnr integer
---@param max_edits integer
---@param idle_minutes integer
---@return boolean
function M.should_reset(bufnr, max_edits, idle_minutes)
    local state = M.get_state(bufnr)
    if #state.edits >= max_edits then
        return true
    end
    local idle_ms = vim.uv.now() - state.last_ms
    return idle_ms >= idle_minutes * 60 * 1000
end

--- Roll the session: keep the last `seed_count` edits as seed for the fresh
--- context, clear the running log, and re-snapshot the baseline.
---@param bufnr integer
---@param seed_count integer
function M.reset(bufnr, seed_count)
    local state = M.get_state(bufnr)
    local n = #state.edits
    local seed = {}
    for i = math.max(1, n - seed_count + 1), n do
        table.insert(seed, state.edits[i])
    end
    -- Carry the last seed_count diff-history entries into the fresh context.
    local de = state.diff_entries
    local seed_diff_entries = {}
    for i = math.max(1, #de - seed_count + 1), #de do
        table.insert(seed_diff_entries, de[i])
    end
    state.seed = seed
    state.seed_diff_entries = seed_diff_entries
    state.edits = {}
    state.diff_entries = {}
    state.baseline = get_lines(bufnr)
    state.started_ms = vim.uv.now()
    state.last_ms = vim.uv.now()
end

function M.clear(bufnr)
    M.states[bufnr] = nil
end

local function slice_lines(lines, first, last)
    local out = {}
    for i = first, last do
        table.insert(out, lines[i] or '')
    end
    return out
end

local function insert_cursor_marker(line, col0)
    col0 = math.max(0, math.min(col0 or 0, #line))
    return line:sub(1, col0) .. '<|cursor|>' .. line:sub(col0 + 1)
end

-- ---------------------------------------------------------------------------
-- recently_viewed_code_snippets: recent-buffer ring + send-time history cleanup
-- ---------------------------------------------------------------------------

-- Most-recently-visited buffers (across files), newest last. Drives the
-- cross-file snippets Mercury Edit expects in recently_viewed_code_snippets.
M.recent = {}
local RECENT_MAX = 16

--- Record that the cursor is in `bufnr` at its current row. Call on buffer enter
--- / cursor hold so snippets can be centered on the user's recent locations.
--- Snippets are always rendered from the latest buffer content at send time, so
--- only the position is stored here (a stale snapshot would invite reverts).
---@param bufnr integer
function M.note_cursor(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_name(bufnr) == '' then
        return
    end
    local row = 1
    if vim.api.nvim_get_current_buf() == bufnr then
        row = vim.api.nvim_win_get_cursor(0)[1]
    else
        local mark = vim.api.nvim_buf_get_mark(bufnr, '"')[1]
        row = mark > 0 and mark or 1
    end
    for i = #M.recent, 1, -1 do
        if M.recent[i].bufnr == bufnr then
            table.remove(M.recent, i)
        end
    end
    table.insert(M.recent, { bufnr = bufnr, row = row, ts = vim.uv.now() })
    while #M.recent > RECENT_MAX do
        table.remove(M.recent, 1)
    end
end

--- Up to `count` cross-file snippets of ~`radius`*2 lines centered on the user's
--- recent cursor rows, newest first, read from current (latest) buffer content.
---@param current_bufnr integer
---@param count integer
---@param radius integer
---@return { path: string, lines: string[] }[]
local function recent_snippets(current_bufnr, count, radius)
    local out = {}
    for i = #M.recent, 1, -1 do
        if #out >= count then
            break
        end
        local r = M.recent[i]
        if r.bufnr ~= current_bufnr and vim.api.nvim_buf_is_valid(r.bufnr) and vim.api.nvim_buf_is_loaded(r.bufnr) then
            local lines = get_lines(r.bufnr)
            if #lines > 0 then
                local row = math.max(1, math.min(r.row, #lines))
                out[#out + 1] = {
                    path = buf_path(r.bufnr),
                    lines = slice_lines(lines, math.max(1, row - radius), math.min(#lines, row + radius)),
                }
            end
        end
    end
    return out
end

--- Expand [start_row, end_row] outward to enclosing syntax-node boundaries while
--- the result stays within `max_lines`. Ranges are innermost to outermost.
local function snap_region(start_row, end_row, syntax_ranges, max_lines)
    if not syntax_ranges then
        return start_row, end_row
    end
    for _, sr in ipairs(syntax_ranges) do
        local ns = math.min(start_row, sr.start_line)
        local ne = math.max(end_row, sr.end_line)
        if (ne - ns + 1) <= max_lines then
            start_row, end_row = ns, ne
        else
            break
        end
    end
    return start_row, end_row
end

--- Mercury Edit's send-time edit-history cleanup: drop stale entries, cancel out
--- inverse pairs (A->B then B->A), de-duplicate identical edits. Preserves
--- chronological order (most recent last).
---@param entries { original: string, updated: string, ts_ms: integer }[]
---@param now integer
local function process_diff_entries(entries, now)
    local kept = {}
    for _, e in ipairs(entries) do
        if not e.ts_ms or (now - e.ts_ms) < DIFF_IDLE_MS then
            kept[#kept + 1] = e
        end
    end

    local removed = {}
    for i = 1, #kept do
        if not removed[i] then
            for j = i + 1, #kept do
                if
                    not removed[j]
                    and vim.trim(kept[i].updated) == vim.trim(kept[j].original)
                    and vim.trim(kept[j].updated) == vim.trim(kept[i].original)
                then
                    removed[i] = true
                    removed[j] = true
                    break
                end
            end
        end
    end

    local last_at = {}
    for i, e in ipairs(kept) do
        last_at[vim.trim(e.original) .. '\0' .. vim.trim(e.updated)] = i
    end

    local out = {}
    for i, e in ipairs(kept) do
        local key = vim.trim(e.original) .. '\0' .. vim.trim(e.updated)
        if not removed[i] and last_at[key] == i then
            out[#out + 1] = e
        end
    end
    return out
end

--- Build the Mercury Edit 2 tagged prompt and describe the editable region it
--- should return, following Inception's Next Edit format: cross-file snippets +
--- diagnostics + treesitter scope in recently_viewed_code_snippets, the full
--- current file with a cursor-centered (syntax-snapped) code_to_edit region, and
--- the chronological range-based edit_diff_history.
---@param bufnr integer
---@param opts? { lines_before?: integer, lines_after?: integer, max_editable_lines?: integer, snippet_count?: integer, snippet_radius?: integer, max_siblings?: integer, git_diff_max_bytes?: integer }
---@return string prompt
---@return { path: string, start_row: integer, end_row: integer, original_lines: string[] } region
function M.build_inception_edit_turn(bufnr, opts)
    opts = opts or {}
    local state = M.get_state(bufnr)
    local path = buf_path(bufnr)
    local cur = get_lines(bufnr)
    if #cur == 0 then
        cur = { '' }
    end

    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col0 = pos[1], pos[2]
    row = math.max(1, math.min(row, #cur))

    local before = opts.lines_before or 5
    local after = opts.lines_after or 10
    local max_editable_lines = opts.max_editable_lines or 25

    -- Treesitter scope: snaps the editable region to syntax boundaries and feeds
    -- the treesitter_context snippet.
    local ts = nes.treesitter(bufnr, row, col0, opts.max_siblings or 4)

    local start_row = math.max(1, row - before)
    local end_row = math.min(#cur, row + after)
    start_row, end_row = snap_region(start_row, end_row, ts and ts.syntax_ranges, max_editable_lines)
    start_row = math.max(1, start_row)
    end_row = math.min(#cur, end_row)

    local pre = slice_lines(cur, 1, start_row - 1)
    local original_lines = slice_lines(cur, start_row, end_row)
    local editable = slice_lines(cur, start_row, end_row)
    local post = slice_lines(cur, end_row + 1, #cur)
    local cursor_idx = row - start_row + 1
    editable[cursor_idx] = insert_cursor_marker(editable[cursor_idx] or '', col0)

    local snippets = recent_snippets(bufnr, opts.snippet_count or 3, opts.snippet_radius or 10)
    local diag_text = nes.diagnostics_text(bufnr)
    local ts_text = nes.treesitter_text(ts)
    local git_diff = nes.git_staged_diff(path, opts.git_diff_max_bytes or 8000)

    local entries = {}
    vim.list_extend(entries, state.seed_diff_entries or {})
    vim.list_extend(entries, state.diff_entries or {})
    entries = process_diff_entries(entries, vim.uv.now())

    local buf = {}
    local function w(s)
        buf[#buf + 1] = s
    end

    w '<|recently_viewed_code_snippets|>\n'
    for _, snip in ipairs(snippets) do
        w '<|recently_viewed_code_snippet|>\n'
        w('code_snippet_file_path: ' .. snip.path .. '\n')
        w(table.concat(snip.lines, '\n') .. '\n')
        w '<|/recently_viewed_code_snippet|>\n'
    end
    if diag_text ~= '' then
        w '<|recently_viewed_code_snippet|>\n'
        w 'code_snippet_file_path: diagnostics\n'
        w(diag_text)
        w '<|/recently_viewed_code_snippet|>\n'
    end
    if ts_text ~= '' then
        w '<|recently_viewed_code_snippet|>\n'
        w 'code_snippet_file_path: treesitter_context\n'
        w(ts_text)
        w '<|/recently_viewed_code_snippet|>\n'
    end
    if git_diff then
        w '<|recently_viewed_code_snippet|>\n'
        w 'code_snippet_file_path: staged_git_diff\n'
        w(git_diff)
        if git_diff:sub(-1) ~= '\n' then
            w '\n'
        end
        w '<|/recently_viewed_code_snippet|>\n'
    end
    w '<|/recently_viewed_code_snippets|>\n'
    w '\n'

    w '<|current_file_content|>\n'
    w('current_file_path: ' .. path .. '\n')
    for _, l in ipairs(pre) do
        w(l .. '\n')
    end
    w '<|code_to_edit|>\n'
    for _, l in ipairs(editable) do
        w(l .. '\n')
    end
    w '<|/code_to_edit|>\n'
    for _, l in ipairs(post) do
        w(l .. '\n')
    end
    w '<|/current_file_content|>\n'
    w '\n'

    w '<|edit_diff_history|>\n'
    for _, e in ipairs(entries) do
        w(M.render_diff_entry(e, path) .. '\n')
        w '\n'
    end
    w '<|/edit_diff_history|>\n'

    return table.concat(buf, ''),
        {
            path = path,
            start_row = start_row,
            end_row = end_row,
            original_lines = original_lines,
        }
end

--- Build the user turn for a prediction: a cursor note, the recent edits (seed +
--- running log), then the clean current file. The cursor is fed as a SEPARATE
--- note (not an inline marker) so the file/patch text stays in-distribution for
--- the apply_patch-trained model. The system prompt and tool definitions live in
--- config.lua / the backend.
---@param bufnr integer
---@param opts? { ctx_lines?: integer }
---@return string
function M.build_user_turn(bufnr, opts)
    opts = opts or {}
    local state = M.get_state(bufnr)
    local path = buf_path(bufnr)
    local cur = get_lines(bufnr)

    local parts = {}

    -- Cursor as a separate channel: a note kept OUT of the file/patch text. An
    -- inline marker measurably increased reverts and got copied into patches.
    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col = pos[1], pos[2]
    table.insert(
        parts,
        ('Editor cursor: line %d, column %d (1-based). That line currently reads: `%s`'):format(
            row,
            col + 1,
            cur[row] or ''
        )
    )
    table.insert(parts, '')

    local all_edits = {}
    vim.list_extend(all_edits, state.seed)
    vim.list_extend(all_edits, state.edits)
    if #all_edits > 0 then
        table.insert(parts, 'Recent edits (oldest to newest):')
        table.insert(parts, '')
        table.insert(parts, table.concat(all_edits, '\n\n'))
        table.insert(parts, '')
    end

    table.insert(parts, ('Current file `%s`:'):format(path))
    table.insert(parts, '')
    table.insert(parts, table.concat(cur, '\n'))

    return table.concat(parts, '\n')
end

return M
