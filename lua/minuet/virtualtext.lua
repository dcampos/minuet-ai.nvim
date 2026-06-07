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
}

---@return 'off' | 'unintrusive' | 'full'
local function auto_trigger_mode()
    return vim.b.minuet_virtual_text_auto_trigger_mode or 'off'
end

-- True when auto-trigger should fire at the current cursor position.
-- In 'unintrusive' mode the line text after the cursor must be whitespace-only
-- (or the cursor must be at end of line); otherwise ghost text would overlay
-- existing code.
local function should_auto_trigger()
    local mode = auto_trigger_mode()
    if mode == 'full' then
        return true
    end
    if mode == 'unintrusive' then
        local row, col = unpack(api.nvim_win_get_cursor(0))
        local line = api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
        return line:sub(col + 1):match '^%s*$' ~= nil
    end
    return false
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

---@param optional table?
---@return string[]?
local function collect_stop_tokens(optional)
    if type(optional) ~= 'table' then
        return nil
    end

    local raw = optional.stop or optional.stop_sequences
    if type(raw) == 'string' then
        return { raw }
    end
    if type(raw) == 'table' then
        return raw
    end

    return nil
end

---@param optional table?
---@return table?
local function strip_stop_tokens(optional)
    if type(optional) ~= 'table' then
        return optional
    end

    local stripped = vim.deepcopy(optional)
    stripped.stop = nil
    stripped.stop_sequences = nil
    return stripped
end

---@param text string
---@param stop_tokens string[]?
---@return string
local function truncate_at_stop_tokens(text, stop_tokens)
    if type(text) ~= 'string' or not stop_tokens or #stop_tokens == 0 then
        return text
    end

    local cutoff = nil
    for _, token in ipairs(stop_tokens) do
        if type(token) == 'string' and token ~= '' then
            local idx = text:find(token, 1, true)
            if idx and (not cutoff or idx < cutoff) then
                cutoff = idx
            end
        end
    end

    if cutoff then
        return text:sub(1, cutoff - 1)
    end

    return text
end

---@param cached string
---@param current string
---@param max_shift integer  skip entries whose shift exceeds this
---@return integer?
local function match_prefix_to_cached_suffix(cached, current, max_shift)
    if #cached == 0 then
        return 0
    end
    if #current == 0 then
        return nil
    end

    -- Bail out early when the two strings differ in length by more than
    -- max_shift — no match within the allowed shift window is possible.
    if math.abs(#current - #cached) > max_shift then
        return nil
    end

    local max_len = math.min(#cached, #current)
    -- Only scan shifts up to max_shift: typed_since length = #current - len,
    -- so len >= #current - max_shift.
    local min_len = math.max(1, #current - max_shift)
    for len = max_len, min_len, -1 do
        if cached:sub(#cached - len + 1) == current:sub(1, len) then
            return len
        end
    end

    return nil
end

--- Extract the request parameters that distinguish one cache slot from another.
--- Only fields that affect the generated completions are included (model,
--- non-stop optional fields, max_tokens, etc.). Provider endpoint and API key
--- are excluded. Stop tokens are tracked separately so cache reuse can remain
--- valid across narrower or broader stop constraints.
---@param cfg table effective config (post-override)
---@return table
local function extract_cache_params(cfg)
    local opts = cfg.provider_options[cfg.provider] or {}
    local optional = vim.deepcopy(opts.optional)
    return {
        provider = cfg.provider,
        model = opts.model,
        optional = strip_stop_tokens(optional),
        stop_tokens = collect_stop_tokens(optional),
    }
end

--- Derive effective suggestions from ctx.cache.
--- A cache entry matches when: provider/model, non-stop optional fields, and
--- stop tokens are all equal; the after-context is still compatible; and the
--- before-context suffix/prefix overlap is within the configured shift window.
--- Completions whose raw text starts with the text typed since the overlap are
--- returned with that prefix stripped. Results are deduplicated.
---
--- Returns (results, needs_refresh): needs_refresh is true when at least one
--- matched entry fell in the soft-limit zone (cursor drifted past
--- cache_soft_chars_ahead but within cache_max_chars_ahead), signalling that a
--- background re-fetch is worthwhile.
---@param ctx minuet.VirtualtextSuggestionContext
---@param params table   output of extract_cache_params for the current request
---@param cur_before string  current lines_before
---@param cur_after string   current lines_after
---@param cfg table  effective config
---@return string[], boolean
local function pool_suggestions(ctx, params, cur_before, cur_after, cfg)
    local vt_cfg = cfg.virtualtext or {}
    local hard_limit = vt_cfg.cache_max_chars_ahead or 40
    local soft_limit = vt_cfg.cache_soft_chars_ahead or 20

    local results = {}
    local seen = {}
    local needs_refresh = false

    -- Normalise a stop-token list so nil and {} compare equal.
    local function norm_stops(t)
        return (t and #t > 0) and t or nil
    end

    for _, entry in ipairs(ctx.cache or {}) do
        if entry.params.provider ~= params.provider then
            goto continue
        end
        if entry.params.model ~= params.model then
            goto continue
        end
        if not vim.deep_equal(entry.params.optional, params.optional) then
            goto continue
        end
        -- Require identical stop tokens so manual (multi-line) and auto
        -- (single-line) completions do not bleed into each other.
        if not vim.deep_equal(norm_stops(entry.params.stop_tokens), norm_stops(params.stop_tokens)) then
            goto continue
        end
        if type(entry.lines_after) ~= 'string' or type(cur_after) ~= 'string' then
            goto continue
        end
        if not (
            entry.lines_after:sub(1, #cur_after) == cur_after
            or cur_after:sub(1, #entry.lines_after) == entry.lines_after
        ) then
            goto continue
        end
        if type(entry.lines_before) ~= 'string' or type(cur_before) ~= 'string' then
            goto continue
        end

        local overlap_len = match_prefix_to_cached_suffix(entry.lines_before, cur_before, hard_limit)
        if overlap_len == nil then
            goto continue
        end

        local typed_since = cur_before:sub(overlap_len + 1)
        -- Advancing the cursor may drop old context on the left, but that
        -- dropped prefix must be balanced by newly typed text on the right.
        -- Otherwise the cache entry was requested ahead of the current cursor.
        local cache_only_prefix_len = #entry.lines_before - overlap_len
        if cache_only_prefix_len > #typed_since then
            goto continue
        end

        if #typed_since > soft_limit then
            needs_refresh = true
        end

        for _, comp in ipairs(entry.completions) do
            if comp:sub(1, #typed_since) == typed_since then
                local effective = comp:sub(#typed_since + 1)
                effective = truncate_at_stop_tokens(effective, entry.params.stop_tokens)

                if #effective > 0 and not seen[effective] then
                    seen[effective] = true
                    table.insert(results, effective)
                end
            end
        end

        ::continue::
    end

    return results, needs_refresh
end

---@class minuet.CacheEntry
---@field lines_before string
---@field lines_after string
---@field params table
---@field completions string[]

---@class minuet.VirtualtextSuggestionContext
---@field suggestions? string[]
---@field choice? integer
---@field shown_choices? table<string, true>
---@field cache? minuet.CacheEntry[]
---@field last_trigger_params? table
---@field last_trigger_was_manual? boolean
---@field n_retries? integer
---@field request_inflight? boolean
---@field request_generation? integer
---@field pending_trigger? boolean
---@field pending_overrides? table
---@field pending_is_manual? boolean

-- Provider callbacks capture this token; cleanup bumps it so in-flight
-- callbacks cannot repaint stale ghost text after dismissal or deactivation.
---@param ctx minuet.VirtualtextSuggestionContext
---@return integer
local function bump_request_generation(ctx)
    ctx.request_generation = (ctx.request_generation or 0) + 1
    return ctx.request_generation
end

-- Resets display/active state. ctx.cache and ctx.last_trigger_params are
-- intentionally preserved so cached completions remain available for the next
-- cursor movement or trigger without a round-trip.
---@param ctx minuet.VirtualtextSuggestionContext
local function reset_ctx(ctx)
    ctx.suggestions = nil
    ctx.choice = nil
    ctx.shown_choices = nil
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
    bump_request_generation(ctx)
    reset_ctx(ctx)
    ctx.request_inflight = nil
    ctx.pending_trigger = nil
    ctx.pending_overrides = nil
    ctx.pending_is_manual = nil
    ctx.last_trigger_was_manual = nil
    clear_preview()
end

---@param bufnr integer
---@param overrides? table Optional partial config patch, deep-merged onto the
---live config for this single request (no global mutation). Use to fire with a
---different provider/model/stop tokens without `change_model`/`change_provider`.
---@param is_retry? boolean When true this is an automatic cache-fill retry;
---n_retries is not reset.
---@param is_manual? boolean When true the request was user-initiated (not the
---auto-trigger debounce path). Manual completions remain visible while typing
---even when auto-trigger is off.
local function trigger(bufnr, overrides, is_retry, is_manual)
    if bufnr ~= api.nvim_get_current_buf() or vim.fn.mode() ~= 'i' then
        return
    end

    utils.notify('Minuet virtual text started', 'verbose')

    local cfg = require('minuet').config
    if overrides then
        cfg = vim.tbl_deep_extend('force', cfg, overrides)
    end

    local ctx = get_ctx(bufnr)
    if ctx.request_inflight and not is_retry then
        ctx.pending_trigger = true
        ctx.pending_overrides = overrides
        ctx.pending_is_manual = is_manual or false
        return
    end

    if not is_retry then
        ctx.n_retries = 0
        ctx.last_trigger_was_manual = is_manual or false
    end
    ctx.cache = ctx.cache or {}

    local context = utils.get_context(utils.make_cmp_context(), cfg)
    local cur_before = context.lines_before
    local cur_after = context.lines_after
    local params = extract_cache_params(cfg)

    -- Remember which params were active so on_cursor_moved_i can match them.
    ctx.last_trigger_params = params

    -- Show any already-cached suggestions immediately while the request is in
    -- flight; also skip firing if the cache already satisfies n_completions.
    local n_completions = cfg.n_completions or 3
    local cached, needs_refresh = pool_suggestions(ctx, params, cur_before, cur_after, cfg)
    if #cached > 0 then
        ctx.suggestions = cached
        ctx.choice = ctx.choice or 1
        ctx.shown_choices = ctx.shown_choices or {}
        update_preview(ctx)
        if not is_retry and #cached >= n_completions and not needs_refresh then
            return
        end
    end

    local provider = require('minuet.backends.' .. cfg.provider)

    ctx.request_inflight = true
    local request_generation = bump_request_generation(ctx)

    provider.complete(context, function(data, done)
        if api.nvim_get_current_buf() ~= bufnr then
            return
        end
        if ctx.request_generation ~= request_generation then
            return
        end

        data = utils.list_dedup(data or {})

        -- Locate or create the cache entry for this (context, params) triple.
        -- FIM backends fire the callback once per parallel request with the
        -- growing accumulated list, so we merge rather than replace.
        local cache = ctx.cache
        local entry
        for _, e in ipairs(cache) do
            if vim.deep_equal(e.params, params)
                and e.lines_before == cur_before
                and e.lines_after == cur_after
            then
                entry = e
                break
            end
        end
        if not entry then
            entry = {
                lines_before = cur_before,
                lines_after = cur_after,
                params = params,
                completions = {},
            }
            table.insert(cache, entry)
        end

        -- Merge new completions into the entry (deduplicated)
        local existing = {}
        for _, c in ipairs(entry.completions) do existing[c] = true end
        for _, c in ipairs(data) do
            if not existing[c] then
                existing[c] = true
                table.insert(entry.completions, c)
            end
        end

        local pool_size = cfg.virtualtext.pool_size or 8
        while #cache > pool_size do
            table.remove(cache, 1)
        end

        -- Re-read cursor position so we don't flash stale ghost-text when the
        -- user typed ahead while the request was in flight.
        local cmp_ctx_now = utils.make_cmp_context()
        local ctx_now = utils.get_context(cmp_ctx_now, cfg)
        local effective = pool_suggestions(ctx, params, ctx_now.lines_before, ctx_now.lines_after, cfg)
        if #effective > 0 then
            ctx.suggestions = effective
            if not ctx.choice or ctx.choice > #effective then
                ctx.choice = 1
            end
            ctx.shown_choices = ctx.shown_choices or {}
            update_preview(ctx)
        end

        if done ~= false then
            ctx.request_inflight = false

            local max_retries = cfg.virtualtext.max_retries or 3
            local n_retries = ctx.n_retries or 0
            if (not ctx.pending_trigger)
                and next(data)
                and #(ctx.suggestions or {}) < n_completions
                and n_retries < max_retries
            then
                ctx.n_retries = n_retries + 1
                trigger(bufnr, overrides, true)
                return
            end

            if ctx.pending_trigger then
                local pending_overrides = ctx.pending_overrides
                local pending_is_manual = ctx.pending_is_manual
                ctx.pending_trigger = nil
                ctx.pending_overrides = nil
                ctx.pending_is_manual = nil
                vim.schedule(function()
                    if
                        ctx.request_generation == request_generation
                        and api.nvim_get_current_buf() == bufnr
                        and vim.fn.mode() == 'i'
                    then
                        trigger(bufnr, pending_overrides, false, pending_is_manual)
                    end
                end)
            end
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

    local function maybe_trigger()
        local show_on_completion_menu = require('minuet').config.virtualtext.show_on_completion_menu

        if
            internal.is_on_throttle
            or (not show_on_completion_menu and completion_menu_visible())
            or (not utils.run_hooks_until_failure(config.enable_predicates))
            -- Re-check at fire time: in 'unintrusive' mode the cursor may have
            -- moved into a position with non-whitespace text after it during
            -- the debounce window.
            or (not should_auto_trigger())
        then
            return
        end

        if (config.throttle or 0) > 0 then
            internal.is_on_throttle = true
            vim.defer_fn(function()
                internal.is_on_throttle = false
            end, config.throttle)
        end

        trigger(bufnr)
    end

    if (config.debounce or 0) <= 0 then
        maybe_trigger()
        return
    end

    internal.timer = vim.defer_fn(maybe_trigger, config.debounce)
end

local action = {}

---@param overrides? table Partial config patch, deep-merged onto the live
---config for this single request only. No global mutation. Useful for
---one-off completions with a different provider/model/stop tokens.
---Bypasses auto-trigger gating (debounce/throttle/predicates).
function action.fire(overrides)
    trigger(api.nvim_get_current_buf(), overrides, false, true)
end

---@param overrides? table Optional config patch.
---Behavior:
---  * no suggestions yet → fire a trigger with overrides applied
---  * suggestions visible and overrides resolve to a DIFFERENT param-set
---    than the one that produced them (e.g. user is showing autotrigger
---    results with stop=\n and presses a keymap that overrides stop=\n\n)
---    → fire a fresh trigger so the user actually gets the variant they
---    asked for, rather than cycling within the wrong set
---  * suggestions visible and overrides match (or are absent) → cycle
local function cycle_or_fetch(direction, overrides)
    local ctx = get_ctx()

    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf(), overrides, false, true)
        return
    end

    if overrides then
        local cfg = vim.tbl_deep_extend('force', require('minuet').config, overrides)
        local new_params = extract_cache_params(cfg)
        if not vim.deep_equal(new_params, ctx.last_trigger_params) then
            trigger(api.nvim_get_current_buf(), overrides, false, true)
            return
        end
    end

    advance(direction, ctx)
end

action.next = function(overrides)
    cycle_or_fetch(1, overrides)
end

action.prev = function(overrides)
    cycle_or_fetch(-1, overrides)
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

-- Returns the byte length of the next "word unit" in s, matching :h word /
-- the `e` normal-mode motion: leading blanks (including EOL) followed by
-- either a run of \k chars or a run of non-blank non-\k chars. Returns nil
-- when s is empty or contains no word.
--
-- \_s is vim's whitespace-or-EOL class; \k\@!\S is "non-blank that is not a
-- keyword char", so the second alternative groups runs of punctuation the way
-- `e` does (e.g. `foo!!!bar` -> foo, !!!, bar). \k and \S handle multibyte
-- input on their own, so no per-character walk is needed.
local function next_word_end(s)
    if #s == 0 then
        return nil
    end
    local byte_end = vim.fn.matchend(s, [[^\_s*\(\k\+\|\%(\k\@!\S\)\+\)]])
    if byte_end < 0 then
        return nil
    end
    return byte_end
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

    local _, end_idx = suggestion:find(char, 1, true)
    if not end_idx then
        return
    end

    accept_n_chars(end_idx)
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

---@param mode 'off' | 'unintrusive' | 'full'
function action.set_auto_trigger_mode(mode)
    if mode ~= 'off' and mode ~= 'unintrusive' and mode ~= 'full' then
        vim.notify(
            'Minuet Virtual Text auto trigger mode must be one of: off, unintrusive, full',
            vim.log.levels.ERROR
        )
        return
    end
    vim.b.minuet_virtual_text_auto_trigger_mode = mode
    -- Reflect the new mode on the display side: if the new state allows
    -- auto-triggering at the current cursor position, fire a request right
    -- away so the user does not have to type a character to see a completion.
    -- Otherwise clear any currently visible ghost text so disabling /
    -- switching to unintrusive over occupied text actually dismisses it.
    if should_auto_trigger() then
        trigger(api.nvim_get_current_buf(), nil, false, false)
    else
        cleanup(get_ctx())
    end
    vim.notify('Minuet Virtual Text auto trigger: ' .. mode, vim.log.levels.INFO)
end

function action.disable_auto_trigger()
    action.set_auto_trigger_mode 'off'
end

-- Restore the mode configured in `config.virtualtext.auto_trigger_mode`.
-- If the configured value is itself 'off', default to 'full' so a user who
-- presses "enable" actually gets auto-triggering.
function action.enable_auto_trigger()
    local configured = require('minuet').config.virtualtext.auto_trigger_mode or 'full'
    if configured == 'off' then
        configured = 'full'
    end
    action.set_auto_trigger_mode(configured)
end

function action.toggle_auto_trigger()
    if auto_trigger_mode() == 'off' then
        action.enable_auto_trigger()
    else
        action.disable_auto_trigger()
    end
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

    -- Only serve cached completions when auto-trigger is on, or when the user
    -- explicitly fired a manual completion that is still "live" (not yet
    -- dismissed by cleanup). This prevents stale ghost-text from appearing
    -- while the user has auto-trigger deliberately turned off.
    local can_show_cache = should_auto_trigger() or ctx.last_trigger_was_manual

    -- Check cache with the params from the last trigger. Using stored params
    -- (rather than re-resolving the config) means one-off completions fired
    -- with overridden model/stop-tokens keep working while the user types into
    -- them, without contaminating or being contaminated by the default cache.
    if can_show_cache and ctx.last_trigger_params then
        local cfg = require('minuet').config
        local context = utils.get_context(utils.make_cmp_context(), cfg)
        local effective, needs_refresh = pool_suggestions(ctx, ctx.last_trigger_params, context.lines_before, context.lines_after, cfg)
        if #effective > 0 then
            ctx.suggestions = effective
            if not ctx.choice or ctx.choice > #effective then
                ctx.choice = 1
            end
            ctx.shown_choices = ctx.shown_choices or {}
            update_preview(ctx)
            if needs_refresh and should_auto_trigger() then
                -- Context drifted past soft limit: keep showing the cached
                -- result but kick a fresh request in the background.
                schedule()
            else
                stop_timer()
            end
            return
        end
    end

    -- Cache miss: clear display state if something was shown, then request fresh.
    if ctx.shown_choices and next(ctx.shown_choices) then
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
                    vim.b.minuet_virtual_text_auto_trigger_mode = config.virtualtext.auto_trigger_mode or 'full'
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
