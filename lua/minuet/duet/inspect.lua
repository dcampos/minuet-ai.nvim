-- Floating-window introspection for the `Minuet duet` session: for each
-- prediction, what the model inferred (reasoning), the patch it proposed, any
-- read() calls, the outcome, and the user's result (accepted / ignored /
-- dismissed / rejected). Newest first; the full inputs (system prompt + user
-- turn) are shown for the most recent prediction only. Toggled via
-- `:Minuet duet inspect`.

local api = vim.api
local M = {}

M.win = nil

local function is_open()
    return M.win ~= nil and api.nvim_win_is_valid(M.win)
end

function M.close()
    if is_open() then
        pcall(api.nvim_win_close, M.win, true)
    end
    M.win = nil
end

local function fmt_args(args)
    local keys = {}
    for k in pairs(args or {}) do
        table.insert(keys, k)
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, ('%s=%s'):format(k, tostring(args[k])))
    end
    return '{' .. table.concat(parts, ', ') .. '}'
end

---@param L string[]
---@param rec table
local function render_turns(L, rec)
    local function add(s)
        table.insert(L, s)
    end
    local function block(text)
        for _, line in ipairs(vim.split(text or '', '\n', { plain = true })) do
            add('    ' .. line)
        end
    end

    if #(rec.turns or {}) == 0 then
        add('_(no model turn recorded)_')
        return
    end
    for i, t in ipairs(rec.turns) do
        add('')
        if t.kind == 'apply_patch' or t.kind == 'content_patch' then
            local status = (t.applied == true and 'applied ✓')
                or (t.applied == false and 'did NOT apply ✗')
                or 'discarded'
            add(('- turn %d · %s — %s'):format(i, t.kind, status))
            if t.error then
                add('  error: ' .. tostring(t.error))
            end
        elseif t.kind == 'read' then
            local tail = t.refused and ' — refused (read budget)' or ''
            add(('- turn %d · read %s%s'):format(i, fmt_args(t.args), tail))
        elseif t.kind == 'no_edit' then
            add(('- turn %d · no edit'):format(i))
        else
            add(('- turn %d · %s'):format(i, t.kind or 'response'))
        end

        if t.reasoning then
            add('  reasoning:')
            block(t.reasoning)
        end
        if t.patch then
            add('  patch:')
            block(t.patch)
        elseif t.content and t.kind ~= 'apply_patch' then
            add('  content:')
            block(t.content)
        end
    end
end

---@param history table[]
---@return string[]
local function render(history)
    local L = {}
    local function add(s)
        table.insert(L, s)
    end
    local n = #history

    add(('# Minuet duet · session (%d prediction%s)'):format(n, n == 1 and '' or 's'))
    add('')
    add('newest first · `q` / `<Esc>` to close · `<leader>M` toggles')

    for i = n, 1, -1 do
        local rec = history[i]
        add('')
        add('---')
        add(('## #%d · %s · %s'):format(i, rec.time or '?', rec.mode or '?'))
        add(('outcome: **%s**  ·  result: **%s**'):format(tostring(rec.outcome), tostring(rec.result or '—')))
        render_turns(L, rec)

        -- Full inputs only for the most recent prediction (avoid repeating the
        -- whole file for every entry).
        if i == n then
            add('')
            add('### inputs · system prompt')
            add('')
            for _, line in ipairs(vim.split(rec.system or '', '\n', { plain = true })) do
                add(line)
            end
            add('')
            add('### inputs · user turn (cursor note + recent edits + file)')
            add('')
            for _, line in ipairs(vim.split(rec.user or '', '\n', { plain = true })) do
                add(line)
            end
        end
    end
    return L
end

--- Open (or, if already open, close) the introspection float.
---@param history table[]? the duet `M.history` list of prediction records
function M.toggle(history)
    if is_open() then
        M.close()
        return
    end
    if not history or #history == 0 then
        vim.notify('Minuet duet: no prediction captured yet. Trigger a prediction first.', vim.log.levels.INFO)
        return
    end

    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, render(history))
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'markdown'
    vim.bo[buf].bufhidden = 'wipe'

    local width = math.min(120, math.max(60, math.floor(vim.o.columns * 0.9)))
    local height = math.min(45, math.max(10, math.floor(vim.o.lines * 0.85)))
    M.win = api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2 - 1),
        col = math.floor((vim.o.columns - width) / 2),
        style = 'minimal',
        border = 'rounded',
        title = ' Minuet duet · inspect ',
        title_pos = 'center',
    })
    vim.wo[M.win].wrap = true
    vim.wo[M.win].linebreak = true
    vim.wo[M.win].cursorline = true
    vim.wo[M.win].conceallevel = 0

    for _, key in ipairs { 'q', '<Esc>' } do
        vim.keymap.set('n', key, M.close, { buffer = buf, nowait = true, silent = true })
    end
end

return M
