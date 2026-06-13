-- Floating-window introspection for the last `Minuet duet` prediction: the exact
-- inputs we sent (system prompt + user turn), each model turn (reasoning, patch,
-- read calls) and the final outcome. Toggled via `:Minuet duet inspect`.

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

---@param last table
---@return string[]
local function render(last)
    local L = {}
    local function add(s)
        table.insert(L, s)
    end
    local function block(text)
        for _, line in ipairs(vim.split(text or '', '\n', { plain = true })) do
            add(line)
        end
    end

    add('# Minuet duet · last prediction')
    add('')
    add(('- time `%s`   buffer `%s`   mode `%s`'):format(last.time or '?', last.path or '?', last.mode or '?'))
    add(('- model `%s`   effort `%s`'):format(tostring(last.model), tostring(last.effort)))
    add(('- outcome **%s**'):format(tostring(last.outcome)))

    add('')
    add('## System prompt')
    add('')
    block(last.system)

    add('')
    add('## Inputs (user turn)')
    add('')
    block(last.user)

    add('')
    add(('## Model turns (%d)'):format(#(last.turns or {})))
    for i, t in ipairs(last.turns or {}) do
        add('')
        if t.kind == 'apply_patch' or t.kind == 'content_patch' then
            local status = (t.applied == true and 'applied ✓')
                or (t.applied == false and 'did NOT apply ✗')
                or 'discarded'
            add(('### %d · %s — %s'):format(i, t.kind, status))
            if t.error then
                add('')
                add('error: ' .. tostring(t.error))
            end
        elseif t.kind == 'read' then
            local tail = t.refused and ' — refused (read budget)' or ''
            add(('### %d · read %s%s'):format(i, fmt_args(t.args), tail))
        elseif t.kind == 'no_edit' then
            add(('### %d · no edit'):format(i))
        else
            add(('### %d · %s'):format(i, t.kind or 'response'))
        end

        if t.reasoning then
            add('')
            add('reasoning:')
            block(t.reasoning)
        end
        if t.patch then
            add('')
            add('patch:')
            block(t.patch)
        elseif t.content and t.kind ~= 'apply_patch' then
            add('')
            add('content:')
            block(t.content)
        end
    end

    add('')
    add('---')
    add('press `q` / `<Esc>` to close · `<leader>M` toggles')
    return L
end

--- Open (or, if already open, close) the introspection float for `last`.
---@param last table? the duet `M.last` transcript
function M.toggle(last)
    if is_open() then
        M.close()
        return
    end
    if not last then
        vim.notify('Minuet duet: no prediction captured yet. Trigger a prediction first.', vim.log.levels.INFO)
        return
    end

    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, render(last))
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
