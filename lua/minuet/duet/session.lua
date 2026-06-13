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
    local lines = vim.split(unified, '\n', { plain = true })
    if lines[#lines] == '' then
        table.remove(lines)
    end
    for _, line in ipairs(lines) do
        if line:sub(1, 1) == '\\' then
            -- drop git's "\ No newline at end of file" marker; apply_patch has no such line
        elseif line:sub(1, 2) == '@@' then
            table.insert(out, '@@')
        else
            table.insert(out, line)
        end
    end
    table.insert(out, '*** End Patch')
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
        state = { baseline = get_lines(bufnr), edits = {}, seed = {}, started_ms = vim.uv.now(), last_ms = vim.uv.now() }
        M.states[bufnr] = state
    end
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
        table.insert(state.edits, block)
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
    state.seed = seed
    state.edits = {}
    state.baseline = get_lines(bufnr)
    state.started_ms = vim.uv.now()
    state.last_ms = vim.uv.now()
end

function M.clear(bufnr)
    M.states[bufnr] = nil
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
