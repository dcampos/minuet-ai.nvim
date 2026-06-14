-- Duet NES session: local edit-history tracking (no undotree) and the
-- KV-cache-aware message assembly for a long-lived "code session".
--
-- Edits are captured uncoalesced (one record per change burst) and rendered in
-- apply_patch dialect WITH expanded context, so the model tracks real buffer
-- state. See duet-nes-spec.md.

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

--- Render a single edit as conventional unidiff for Mercury Edit history.
---@param before string[]
---@param after string[]
---@param path string
---@param ctx_lines? integer
---@return string?
function M.render_edit_diff(before, after, path, ctx_lines)
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

    local out = { '--- ' .. path, '+++ ' .. path }
    vim.list_extend(out, clean_diff_lines(unified))
    return table.concat(out, '\n')
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
            edit_diffs = {},
            seed = {},
            seed_diffs = {},
            started_ms = vim.uv.now(),
            last_ms = vim.uv.now(),
        }
        M.states[bufnr] = state
    end
    state.edit_diffs = state.edit_diffs or {}
    state.seed_diffs = state.seed_diffs or {}
    return state
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
        local diff_block = M.render_edit_diff(state.baseline, cur, buf_path(bufnr), ctx_lines)
        table.insert(state.edits, block)
        if diff_block then
            table.insert(state.edit_diffs, diff_block)
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
---@return string[] unidiff blocks since session start / last reset
function M.edit_diffs(bufnr)
    return M.get_state(bufnr).edit_diffs
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
    local seed_diffs = {}
    for i = math.max(1, n - seed_count + 1), n do
        table.insert(seed, state.edits[i])
        if state.edit_diffs[i] then
            table.insert(seed_diffs, state.edit_diffs[i])
        end
    end
    state.seed = seed
    state.seed_diffs = seed_diffs
    state.edits = {}
    state.edit_diffs = {}
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

--- Build the Mercury Edit 2 tagged prompt and describe the editable region it
--- should return. This follows Inception's Next Edit format: empty recently
--- viewed snippets, full current file with a cursor-centered code_to_edit
--- region, and chronological unidiff edit history.
---@param bufnr integer
---@param opts? { lines_before?: integer, lines_after?: integer }
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
    local start_row = math.max(1, row - before)
    local end_row = math.min(#cur, row + after)

    local pre = slice_lines(cur, 1, start_row - 1)
    local editable = slice_lines(cur, start_row, end_row)
    local post = slice_lines(cur, end_row + 1, #cur)
    editable[row - start_row + 1] = insert_cursor_marker(editable[row - start_row + 1] or '', col0)

    local all_diffs = {}
    vim.list_extend(all_diffs, state.seed_diffs or {})
    vim.list_extend(all_diffs, state.edit_diffs or {})

    local parts = {
        '<|recently_viewed_code_snippets|>',
        '',
        '<|/recently_viewed_code_snippets|>',
        '',
        '<|current_file_content|>',
        'current_file_path: ' .. path,
    }
    vim.list_extend(parts, pre)
    table.insert(parts, '<|code_to_edit|>')
    vim.list_extend(parts, editable)
    table.insert(parts, '<|/code_to_edit|>')
    vim.list_extend(parts, post)
    table.insert(parts, '<|/current_file_content|>')
    table.insert(parts, '')
    table.insert(parts, '<|edit_diff_history|>')
    if #all_diffs > 0 then
        table.insert(parts, table.concat(all_diffs, '\n\n'))
    end
    table.insert(parts, '<|/edit_diff_history|>')

    return table.concat(parts, '\n'),
        {
            path = path,
            start_row = start_row,
            end_row = end_row,
            original_lines = slice_lines(cur, start_row, end_row),
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
