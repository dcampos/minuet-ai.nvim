-- referenced from copilot.lua https://github.com/zbirenbaum/copilot.lua
local M = {}
local utils = require 'minuet.utils'
local api = vim.api

M.ns_id = api.nvim_create_namespace 'minuet.virtualtext'
M.augroup = api.nvim_create_augroup('MinuetVirtualText', { clear = true })

if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'MinuetVirtualText' })) then
    api.nvim_set_hl(0, 'MinuetVirtualText', { link = 'Comment' })
end

local internal = {
    augroup = M.augroup,
    ns_id = M.ns_id,
    extmark_id = 1,

    timer = nil,
    context = {},
    is_on_throttle = false,
    trigger_generation = 0,
}

local function should_auto_trigger()
    return vim.b.minuet_virtual_text_auto_trigger
end

local function completion_menu_visible()
    local has_cmp = pcall(require, 'cmp')
    local cmp_visible = false

    local has_blink = pcall(require, 'blink-cmp')
    local blink_visible = false

    if has_cmp then
        local ok, _cmp_visible = pcall(function()
            return require('cmp').core.view:visible()
        end)

        if ok then
            cmp_visible = _cmp_visible
        end
    end

    if has_blink then
        local ok, _blink_visible = pcall(function()
            return require('blink-cmp').is_visible()
        end)

        if ok then
            blink_visible = _blink_visible
        end
    end

    return vim.fn.pumvisible() == 1 or cmp_visible or blink_visible
end

---@param bufnr? integer
---@return minuet.VirtualtextSuggestionContext
local function get_ctx(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    if bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    local ctx = internal.context[bufnr]
    if not ctx then
        ctx = {}
        internal.context[bufnr] = ctx
    end
    return ctx
end

--- Collect effective suggestions from ctx.req_pool.
--- For each entry, computes text typed since trigger_pos; collects completions
--- whose raw text starts with that typed prefix, returning only the remainder.
--- Entries where the cursor has moved before trigger_pos are skipped.
--- Results are deduplicated.
---@param ctx minuet.VirtualtextSuggestionContext
---@param bufnr integer
---@return string[]
local function pool_suggestions(ctx, bufnr)
    local cur = api.nvim_win_get_cursor(0)
    local cur_row, cur_col = cur[1] - 1, cur[2]
    local seen = {}
    local results = {}

    for _, entry in ipairs(ctx.req_pool or {}) do
        local tp = entry.trigger_pos
        local s_row, s_col = tp[1] - 1, tp[2]

        if s_row > cur_row or (s_row == cur_row and s_col > cur_col) then
            goto continue
        end

        local typed = ''
        if s_row < cur_row or (s_row == cur_row and s_col < cur_col) then
            local lines = api.nvim_buf_get_text(bufnr, s_row, s_col, cur_row, cur_col, {})
            typed = table.concat(lines, '\n')
        end

        for _, comp in ipairs(entry.completions) do
            if comp:sub(1, #typed) == typed then
                local effective = comp:sub(#typed + 1)
                if #effective > 0 and not seen[effective] then
                    seen[effective] = true
                    table.insert(results, effective)
                end
            end
        end

        ::continue::
    end

    return results
end

---@class minuet.ReqPoolEntry
---@field generation integer
---@field trigger_pos integer[]
---@field completions string[]

---@class minuet.VirtualtextSuggestionContext
---@field suggestions? string[]
---@field choice? integer
---@field shown_choices? table<string, true>
---@field req_pool? minuet.ReqPoolEntry[]
---@field n_retries? integer

---@param ctx minuet.VirtualtextSuggestionContext
local function reset_ctx(ctx)
    ctx.suggestions = nil
    ctx.choice = nil
    ctx.shown_choices = nil
    ctx.req_pool = nil
    ctx.n_retries = nil
end

local function stop_timer()
    if internal.timer and not internal.timer:is_closing() then
        internal.timer:stop()
        internal.timer:close()
        internal.timer = nil
    end
end

local function clear_preview()
    api.nvim_buf_del_extmark(0, internal.ns_id, internal.extmark_id)
end

---@param ctx? minuet.VirtualtextSuggestionContext
local function get_current_suggestion(ctx)
    ctx = ctx or get_ctx()

    local ok, choice = pcall(function()
        if not vim.fn.mode():match '^[iR]' or not ctx.suggestions or #ctx.suggestions == 0 then
            return nil
        end

        local choice = ctx.suggestions[ctx.choice]

        return choice
    end)

    if ok then
        return choice
    end

    return nil
end

---@param ctx? minuet.VirtualtextSuggestionContext
local function update_preview(ctx)
    ctx = ctx or get_ctx()

    local suggestion = get_current_suggestion(ctx)
    local display_lines = suggestion and vim.split(suggestion, '\n', { plain = true }) or {}

    clear_preview()

    local show_on_completion_menu = require('minuet').config.virtualtext.show_on_completion_menu

    if not suggestion or #display_lines == 0 or (not show_on_completion_menu and completion_menu_visible()) then
        return
    end

    local annot = ''

    if ctx.suggestions and #ctx.suggestions > 1 then
        annot = '(' .. ctx.choice .. '/' .. #ctx.suggestions .. ')'
    end

    local cursor_col = vim.fn.col '.'
    local cursor_line = vim.fn.line '.'

    local extmark = {
        id = internal.extmark_id,
        virt_text = { { display_lines[1], 'MinuetVirtualText' } },
        virt_text_pos = 'inline',
    }

    if #display_lines > 1 then
        extmark.virt_lines = {}
        for i = 2, #display_lines do
            extmark.virt_lines[i - 1] = { { display_lines[i], 'MinuetVirtualText' } }
        end

        local last_line = #display_lines - 1
        extmark.virt_lines[last_line][1][1] = extmark.virt_lines[last_line][1][1] .. ' ' .. annot
    elseif #annot > 0 then
        extmark.virt_text[1][1] = extmark.virt_text[1][1] .. ' ' .. annot
    end

    extmark.hl_mode = 'replace'

    api.nvim_buf_set_extmark(0, internal.ns_id, cursor_line - 1, cursor_col - 1, extmark)

    if not ctx.shown_choices[suggestion] then
        ctx.shown_choices[suggestion] = true
    end
end

---@param ctx? minuet.VirtualtextSuggestionContext
local function cleanup(ctx)
    ctx = ctx or get_ctx()
    stop_timer()
    reset_ctx(ctx)
    clear_preview()
end


---@param bufnr integer
---@param overrides? table Optional partial config patch, deep-merged onto the
---live config for this single request (no global mutation). Use to fire with a
---different provider/model/stop tokens without `change_model`/`change_provider`.
---@param is_retry? boolean When true this is an automatic pool-fill retry;
---n_retries is not reset and the pool is not wiped.
local function trigger(bufnr, overrides, is_retry)
    if bufnr ~= api.nvim_get_current_buf() or vim.fn.mode() ~= 'i' then
        return
    end

    utils.notify('Minuet virtual text started', 'verbose')

    local cfg = require('minuet').config
    if overrides then
        cfg = vim.tbl_deep_extend('force', cfg, overrides)
    end

    local ctx = get_ctx(bufnr)
    if not is_retry then
        ctx.n_retries = 0
    end
    ctx.req_pool = ctx.req_pool or {}

    local context = utils.get_context(utils.make_cmp_context(), cfg)
    local trigger_pos = api.nvim_win_get_cursor(0)

    internal.trigger_generation = internal.trigger_generation + 1
    local generation = internal.trigger_generation

    local provider = require('minuet.backends.' .. cfg.provider)

    provider.complete(context, function(data)
        -- Skip if the user has moved to a different buffer
        if api.nvim_get_current_buf() ~= bufnr then
            return
        end

        data = utils.list_dedup(data or {})

        -- Find or create the pool entry for this generation (FIM backends call
        -- back multiple times as parallel requests finish, each with a growing
        -- accumulated list; we update in-place so the latest set is kept).
        local pool = ctx.req_pool
        local entry
        for _, e in ipairs(pool) do
            if e.generation == generation then
                entry = e
                break
            end
        end
        if not entry then
            entry = { generation = generation, trigger_pos = trigger_pos, completions = {} }
            table.insert(pool, entry)
        end
        entry.completions = data

        while #pool > (cfg.virtualtext.pool_size or 8) do
            table.remove(pool, 1)
        end

        -- Derive effective suggestions from the full pool (prefix-matching)
        local effective = pool_suggestions(ctx, bufnr)
        if #effective > 0 then
            ctx.suggestions = effective
            if not ctx.choice or ctx.choice > #effective then
                ctx.choice = 1
            end
            ctx.shown_choices = ctx.shown_choices or {}
            update_preview(ctx)
        end

        -- Fire an extra request if we still have fewer unique suggestions than
        -- desired and haven't exhausted retries for this trigger session.
        local max_retries = cfg.virtualtext.max_retries or 3
        local n_retries = ctx.n_retries or 0
        if next(data)
            and #(ctx.suggestions or {}) < (cfg.n_completions or 3)
            and n_retries < max_retries
        then
            ctx.n_retries = n_retries + 1
            trigger(bufnr, overrides, true)
        end
    end, cfg)
end

local function advance(count, ctx)
    if ctx ~= get_ctx() then
        return
    end

    ctx.choice = (ctx.choice + count) % #ctx.suggestions
    if ctx.choice < 1 then
        ctx.choice = #ctx.suggestions
    end

    update_preview(ctx)
end

local function schedule()
    if internal.is_on_throttle then
        return
    end

    stop_timer()

    local config = require('minuet').config
    local bufnr = api.nvim_get_current_buf()

    internal.timer = vim.defer_fn(function()
        local show_on_completion_menu = require('minuet').config.virtualtext.show_on_completion_menu

        if
            internal.is_on_throttle
            or (not show_on_completion_menu and completion_menu_visible())
            or (not utils.run_hooks_until_failure(config.enable_predicates))
        then
            return
        end

        internal.is_on_throttle = true
        vim.defer_fn(function()
            internal.is_on_throttle = false
        end, config.throttle)

        trigger(bufnr)
    end, config.debounce)
end

local action = {}

---@param overrides? table Partial config patch, deep-merged onto the live
---config for this single request only. No global mutation. Useful for
---one-off completions with a different provider/model/stop tokens.
---Bypasses auto-trigger gating (debounce/throttle/predicates).
function action.fire(overrides)
    trigger(api.nvim_get_current_buf(), overrides)
end

---@param overrides? table Optional config patch. Only used when no suggestion
---request has fired yet — when fresh suggestions must be requested. Once
---suggestions exist, calling next/prev cycles through them and overrides are
---ignored (the cached suggestions are reused).
action.next = function(overrides)
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf(), overrides)
        return
    end

    advance(1, ctx)
end

action.prev = function(overrides)
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf(), overrides)
        return
    end

    advance(-1, ctx)
end

-- Insert the first n_chars of the current suggestion. ctx is NOT reset when
-- there is remaining text; on the next CursorMovedI the pool will re-derive the
-- remainder from the updated cursor position and display it as virtual text.
local function accept_n_chars(n_chars)
    local ctx = get_ctx()
    local suggestion = get_current_suggestion(ctx)
    if not suggestion or #suggestion == 0 then
        return
    end

    local to_insert = n_chars and suggestion:sub(1, n_chars) or suggestion
    local has_remaining = n_chars ~= nil and #suggestion > n_chars

    if not has_remaining then
        reset_ctx(ctx)
    end

    clear_preview()

    local cursor = api.nvim_win_get_cursor(0)
    local line, col = cursor[1] - 1, cursor[2]

    if vim.fn.pumvisible() == 1 then
        api.nvim_feedkeys(api.nvim_replace_termcodes('<C-e>', true, true, true), 'n', true)
    end

    vim.schedule(function()
        local lines = vim.split(to_insert, '\n')
        api.nvim_buf_set_text(0, line, col, line, col, lines)
        local new_col = #lines[#lines]
        if #lines == 1 then
            new_col = new_col + col
        end
        api.nvim_win_set_cursor(0, { line + #lines, new_col })
    end)
end

-- Returns the byte length of the next "word unit" in s: optional leading
-- whitespace followed by either a run of word chars (\w) or a single
-- non-word char. Returns nil when s is empty.
local function next_word_end(s)
    if #s == 0 then
        return nil
    end
    local i = 1
    while i <= #s and s:sub(i, i):match '%s' do
        i = i + 1
    end
    if i > #s then
        return #s
    end
    if s:sub(i, i):match '%w' then
        while i <= #s and s:sub(i, i):match '%w' do
            i = i + 1
        end
    else
        i = i + 1
    end
    return i - 1
end

-- Returns the byte index of the end of the nth word unit in s.
local function find_nth_word_end(s, n)
    local pos = 0
    for _ = 1, n do
        local len = next_word_end(s:sub(pos + 1))
        if not len then
            return nil
        end
        pos = pos + len
    end
    return pos
end

---@param n_lines? integer Number of lines to accept. If both params are nil, accepts all.
---@param n_words? integer Number of word units to accept. Takes precedence over n_lines.
---Accepts the current suggestion by inserting it at the cursor position.
---After insertion, moves the cursor to the end of the inserted text.
function action.accept(n_lines, n_words)
    local ctx = get_ctx()

    local suggestion = get_current_suggestion(ctx)
    if not suggestion then
        return
    end

    if n_words then
        local n = find_nth_word_end(suggestion, n_words)
        if not n then
            return
        end
        accept_n_chars(n)
        return
    end

    local suggestions = vim.split(suggestion, '\n')
    local remaining_suggestions = {}

    if n_lines then
        -- NOTE: If the first line is an empty string (""), it indicates that
        -- the original suggestion began with a newline character. This
        -- typically occurs during partial completion: when the user accepts
        -- the first line, the remaining suggestion may start with '\n'. In
        -- this scenario, we increment n_lines by 1 because the user intends to
        -- accept the next visible line of text, which corresponds to the
        -- subsequent element in the suggestions list.
        if suggestions[1] == '' then
            n_lines = n_lines + 1
        end
        n_lines = math.min(n_lines, #suggestions)
        remaining_suggestions = vim.list_slice(suggestions, n_lines + 1, #suggestions)
        suggestions = vim.list_slice(suggestions, 1, n_lines)
    end

    if #remaining_suggestions <= 0 then
        reset_ctx(ctx)
    end

    clear_preview()

    local cursor = api.nvim_win_get_cursor(0)
    local line, col = cursor[1] - 1, cursor[2]

    if vim.fn.pumvisible() == 1 then
        -- Accepting Minuet completion while the pum is open is temporary; when
        -- the user closes the pum, Vim restores the buffer state and removes
        -- Minuet's completion text. Therefore we need to close the pum before
        -- accepting.
        api.nvim_feedkeys(api.nvim_replace_termcodes('<C-e>', true, true, true), 'n', true)
    end

    vim.schedule(function()
        api.nvim_buf_set_text(0, line, col, line, col, suggestions)
        local new_col = #suggestions[#suggestions]
        -- For single-line suggestions, adjust the column position by adding the
        -- current column offset
        if #suggestions == 1 then
            new_col = new_col + col
        end
        api.nvim_win_set_cursor(0, { line + #suggestions, new_col })
    end)
end

function action.accept_word()
    action.accept(nil, 1)
end

-- Like vim's f{char}: accept the suggestion up to and including the next
-- occurrence of the prompted character.
function action.accept_until_char()
    local ctx = get_ctx()
    local suggestion = get_current_suggestion(ctx)
    if not suggestion or #suggestion == 0 then
        return
    end

    local char = vim.fn.getcharstr()
    if not char or char == '' then
        return
    end

    local idx = suggestion:find(char, 1, true)
    if not idx then
        return
    end

    accept_n_chars(idx)
end

function action.accept_n_lines()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local n = vim.fn.input 'accept n lines: '

    -- FIXME: vim.fn.input may change cursor position, we need to restore the
    -- cursor position after the user input.

    vim.api.nvim_win_set_cursor(0, cursor_pos)

    ---@diagnostic disable-next-line:cast-local-type
    n = tonumber(n)
    if not n then
        return
    end
    if n > 0 then
        action.accept(n)
    else
        vim.notify('Invalid number of lines', vim.log.levels.ERROR)
    end
end

function action.accept_line()
    action.accept(1)
end

function action.dismiss()
    local ctx = get_ctx()
    cleanup(ctx)
end

function action.is_visible()
    return not not api.nvim_buf_get_extmark_by_id(0, internal.ns_id, internal.extmark_id, { details = false })[1]
end

function action.disable_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = false
    vim.notify('Minuet Virtual Text auto trigger disabled', vim.log.levels.INFO)
end

function action.enable_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = true
    vim.notify('Minuet Virtual Text auto trigger enabled', vim.log.levels.INFO)
end

function action.toggle_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = not should_auto_trigger()
    vim.notify(
        'Minuet Virtual Text auto trigger ' .. (should_auto_trigger() and 'enabled' or 'disabled'),
        vim.log.levels.INFO
    )
end

M.action = action

local autocmd = {}

function autocmd.on_insert_leave()
    cleanup()
end

function autocmd.on_buf_leave()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_leave()
    end
end

function autocmd.on_insert_enter()
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_buf_enter()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_enter()
    end
end

function autocmd.on_cursor_moved_i()
    local bufnr = api.nvim_get_current_buf()
    local ctx = get_ctx(bufnr)

    local effective = pool_suggestions(ctx, bufnr)
    if #effective > 0 then
        ctx.suggestions = effective
        if not ctx.choice or ctx.choice > #effective then
            ctx.choice = 1
        end
        ctx.shown_choices = ctx.shown_choices or {}
        update_preview(ctx)
        stop_timer()
        return
    end

    -- Pool empty or no completions match the current position; clean up if
    -- something was in the pool or had been shown, then ask for a fresh request.
    if (ctx.req_pool and #ctx.req_pool > 0) or (ctx.shown_choices and next(ctx.shown_choices)) then
        cleanup(ctx)
    end
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_cursor_hold_i()
    update_preview()
end

function autocmd.on_text_changed_p()
    autocmd.on_cursor_moved_i()
end

---@param info { buf: integer }
function autocmd.on_buf_unload(info)
    internal.context[info.buf] = nil
end

local function create_autocmds()
    api.nvim_create_autocmd('InsertLeave', {
        group = internal.augroup,
        callback = autocmd.on_insert_leave,
        desc = '[minuet.virtualtext] insert leave',
    })

    api.nvim_create_autocmd('BufLeave', {
        group = internal.augroup,
        callback = autocmd.on_buf_leave,
        desc = '[minuet.virtualtext] buf leave',
    })

    api.nvim_create_autocmd('InsertEnter', {
        group = internal.augroup,
        callback = autocmd.on_insert_enter,
        desc = '[minuet.virtualtext] insert enter',
    })

    api.nvim_create_autocmd('BufEnter', {
        group = internal.augroup,
        callback = autocmd.on_buf_enter,
        desc = '[minuet.virtualtext] buf enter',
    })

    api.nvim_create_autocmd('CursorMovedI', {
        group = internal.augroup,
        callback = autocmd.on_cursor_moved_i,
        desc = '[minuet.virtualtext] cursor moved insert',
    })

    api.nvim_create_autocmd('TextChangedP', {
        group = internal.augroup,
        callback = autocmd.on_text_changed_p,
        desc = '[minuet.virtualtext] text changed p',
    })

    api.nvim_create_autocmd('BufUnload', {
        group = internal.augroup,
        callback = autocmd.on_buf_unload,
        desc = '[minuet.virtualtext] buf unload',
    })
end

local function set_keymaps(keymap)
    if keymap.accept then
        vim.keymap.set('i', keymap.accept, action.accept, {
            desc = '[minuet.virtualtext] accept suggestion',
            silent = true,
        })
    end

    if keymap.accept_line then
        vim.keymap.set('i', keymap.accept_line, action.accept_line, {
            desc = '[minuet.virtualtext] accept suggestion (line)',
            silent = true,
        })
    end

    if keymap.accept_n_lines then
        vim.keymap.set('i', keymap.accept_n_lines, action.accept_n_lines, {
            desc = '[minuet.virtualtext] accept suggestion (n lines)',
            silent = true,
        })
    end

    if keymap.accept_word then
        vim.keymap.set('i', keymap.accept_word, action.accept_word, {
            desc = '[minuet.virtualtext] accept next word',
            silent = true,
        })
    end

    if keymap.accept_until_char then
        vim.keymap.set('i', keymap.accept_until_char, action.accept_until_char, {
            desc = '[minuet.virtualtext] accept until char (f-like)',
            silent = true,
        })
    end

    if keymap.next then
        vim.keymap.set('i', keymap.next, action.next, {
            desc = '[minuet.virtualtext] next suggestion',
            silent = true,
        })
    end

    if keymap.prev then
        vim.keymap.set('i', keymap.prev, action.prev, {
            desc = '[minuet.virtualtext] prev suggestion',
            silent = true,
        })
    end

    if keymap.dismiss then
        vim.keymap.set('i', keymap.dismiss, action.dismiss, {
            desc = '[minuet.virtualtext] dismiss suggestion',
            silent = true,
        })
    end
end

function M.setup()
    local config = require('minuet').config
    api.nvim_clear_autocmds { group = M.augroup }

    if #config.virtualtext.auto_trigger_ft > 0 then
        api.nvim_create_autocmd('FileType', {
            pattern = config.virtualtext.auto_trigger_ft,
            callback = function()
                if not vim.tbl_contains(config.virtualtext.auto_trigger_ignore_ft, vim.bo.ft) then
                    vim.b.minuet_virtual_text_auto_trigger = true
                end
            end,
            group = M.augroup,
            desc = 'minuet virtual text filetype auto trigger',
        })
    end

    create_autocmds()
    set_keymaps(config.virtualtext.keymap)
end

return M
