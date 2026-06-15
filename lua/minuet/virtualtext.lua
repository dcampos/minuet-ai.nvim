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
---@field last_anchor? { params: table, lines_before: string, lines_after: string }
---@field n_retries? integer
---@field request_generation? integer

-- Provider callbacks capture this token; a *hard* cleanup bumps it so in-flight
-- callbacks cannot repaint ghost text after an explicit dismiss / insert-leave.
-- Concurrent requests fired while typing share one generation (trigger does NOT
-- bump it), so each still lands its result in the cache and may repaint if it
-- matches the live cursor; only a dismiss invalidates them all at once.
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
---@param soft? boolean When true, preserve `ctx.last_trigger_was_manual` so a
---subsequent CursorMovedI can revive cached suggestions (e.g. user typed a
---typo that broke the match, then backspaced to realign). Used by the
---auto-cleanup path in on_cursor_moved_i; explicit dismiss and insert/buf
---leave use the default (full clear).
local function cleanup(ctx, soft)
    ctx = ctx or get_ctx()
    stop_timer()
    reset_ctx(ctx)
    -- Only a hard cleanup (explicit dismiss, insert/buf-leave) invalidates
    -- in-flight requests. A soft cleanup is the auto path clearing a no-longer-
    -- matching ghost text mid-typing; bumping the generation there would discard
    -- the results of requests fired for earlier keystrokes, which we now want to
    -- keep so they can still land in the cache and match as the user types on.
    if not soft then
        bump_request_generation(ctx)
        ctx.last_trigger_was_manual = nil
    end
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

    if not is_retry then
        ctx.n_retries = 0
        ctx.last_trigger_was_manual = is_manual or false
    end
    ctx.cache = ctx.cache or {}

    local params = extract_cache_params(cfg)

    -- Anchor reuse: keep the FIM prompt prefix region byte-identical to the
    -- previous request as long as the user is typing forward within slack.
    -- This is what unlocks server-side KV cache hits across keystrokes; the
    -- legacy fresh window slides on every typed char and never hits cache.
    -- See utils.get_context for the SPM mechanics.
    local growth_slack = (cfg.virtualtext or {}).context_growth_slack or 0
    local anchor
    if growth_slack > 0 and ctx.last_anchor and vim.deep_equal(ctx.last_anchor.params, params) then
        anchor = {
            prev_lines_before = ctx.last_anchor.lines_before,
            prev_lines_after = ctx.last_anchor.lines_after,
            growth_slack = growth_slack,
        }
    end

    local context = utils.get_context(utils.make_cmp_context(), cfg, anchor)
    -- Bound the suffix independently of the prefix. The prefix is kept warm on
    -- the server's KV cache by the anchor, but the suffix is rarely cached, so
    -- a smaller suffix directly cuts the un-cached token cost per request.
    local after_opt = (cfg.virtualtext or {}).context_after_chars
    if after_opt ~= nil then
        local budget = type(after_opt) == 'function' and after_opt(vim.fn.strchars(context.lines_before)) or after_opt
        if type(budget) == 'number' and budget >= 0 then
            local full_after = context.lines_after
            if vim.fn.strchars(full_after) > budget then
                context.lines_after = vim.fn.strcharpart(full_after, 0, budget)
                context.opts.is_incomplete_after = true
            end
        end
    end
    -- Virtual text fires one request per keystroke that misses the cache and
    -- lets them run concurrently, so the backend must NOT terminate the jobs of
    -- earlier in-flight requests: any of them may still return a completion that
    -- matches what the user types next. (cmp / duet leave this unset and keep
    -- the cancel-the-previous-request behavior.)
    context.opts.keep_existing_jobs = true
    local cur_before = context.lines_before
    local cur_after = context.lines_after

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

    -- We are about to dispatch the request — record what we sent so the next
    -- trigger can anchor against it. Update unconditionally (even if the
    -- request later fails): the server only caches what it actually saw, and
    -- a stale anchor just means the next request misses cache, which is the
    -- legacy behavior.
    ctx.last_anchor = {
        params = params,
        lines_before = cur_before,
        lines_after = cur_after,
    }

    local provider = require('minuet.backends.' .. cfg.provider)

    -- Capture (do not bump) the current generation: concurrent in-flight
    -- requests share it, so each one's callback runs and caches its result.
    -- A hard cleanup bumps the generation to invalidate them all at once.
    ctx.request_generation = ctx.request_generation or 0
    local request_generation = ctx.request_generation

    provider.complete(context, function(data, done)
        if api.nvim_get_current_buf() ~= bufnr then
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

        -- Caching above always runs so a request fired for an earlier keystroke
        -- still lands its completion. Painting and retrying, though, are display
        -- concerns: skip them once a hard cleanup (dismiss / insert-leave) has
        -- invalidated this request's generation.
        if ctx.request_generation ~= request_generation then
            return
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
            local max_retries = cfg.virtualtext.max_retries or 3
            local n_retries = ctx.n_retries or 0
            if next(data)
                and #(ctx.suggestions or {}) < n_completions
                and n_retries < max_retries
            then
                ctx.n_retries = n_retries + 1
                trigger(bufnr, overrides, true)
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

-- Slide cache entries forward by `accepted` so they remain the canonical match
-- for the new cursor position. For each entry, keep only completions that begin
-- with `accepted` (those came from the same suggestion family the user just
-- partially accepted), strip the accepted prefix off them, extend the entry's
-- lines_before, and stamp the current changedtick so the typed_since==0 stale
-- guard in pool_suggestions does not skip the entry on the next CursorMovedI.
-- This is what keeps the cache priority #1 across long accept-word sessions:
-- the hard drift limit never trips because the entries follow the cursor.
local function slide_cache_after_accept(ctx, accepted)
    if not ctx.cache or #accepted == 0 then
        return
    end
    local changedtick = api.nvim_buf_get_changedtick(0)
    for _, entry in ipairs(ctx.cache) do
        local kept = {}
        for _, comp in ipairs(entry.completions) do
            if comp:sub(1, #accepted) == accepted then
                table.insert(kept, comp:sub(#accepted + 1))
            end
        end
        if #kept > 0 then
            entry.lines_before = entry.lines_before .. accepted
            entry.completions = kept
            entry.changedtick = changedtick
        end
    end
end

-- Slice ctx.suggestions forward by `accepted`, preserving the index of the
-- active suggestion so cycling continues from the same spot. Siblings that
-- don't start with `accepted` are dropped — they belong to a different family
-- than the one the user just committed to.
local function slice_suggestions_after_accept(ctx, accepted)
    if not ctx.suggestions or #ctx.suggestions == 0 then
        return
    end
    local active_idx = ctx.choice or 1
    local kept = {}
    local new_choice
    for i, s in ipairs(ctx.suggestions) do
        if s:sub(1, #accepted) == accepted then
            local rest = s:sub(#accepted + 1)
            if #rest > 0 then
                table.insert(kept, rest)
                if i == active_idx then
                    new_choice = #kept
                end
            end
        end
    end
    if #kept == 0 then
        reset_ctx(ctx)
        return
    end
    ctx.suggestions = kept
    ctx.choice = new_choice or 1
end

-- Insert the first n_chars of the current suggestion. Runs synchronously when
-- no popup is open so that an auto-repeated keymap can immediately read the
-- sliced remainder on the next press, instead of seeing the unsliced
-- suggestion and re-inserting its first word. While the edit is in flight
-- `ctx.in_accept` is set so the synchronously fired CursorMovedI short-circuits
-- in on_cursor_moved_i and does not race with the slice. The cache is slid
-- forward by `to_insert` so future CursorMovedI events keep the same entry as
-- the canonical match (no flash, no drift expiration).
local function accept_n_chars(n_chars)
    local ctx = get_ctx()
    local suggestion = get_current_suggestion(ctx)
    if not suggestion or #suggestion == 0 then
        return
    end

    local to_insert = n_chars and suggestion:sub(1, n_chars) or suggestion
    local has_remaining = n_chars ~= nil and #suggestion > n_chars

    local cursor = api.nvim_win_get_cursor(0)
    local line, col = cursor[1] - 1, cursor[2]
    local lines = vim.split(to_insert, '\n', { plain = true })

    local function apply()
        ctx.in_accept = true
        clear_preview()
        api.nvim_buf_set_text(0, line, col, line, col, lines)
        local new_col = #lines[#lines]
        if #lines == 1 then
            new_col = new_col + col
        end
        api.nvim_win_set_cursor(0, { line + #lines, new_col })
        slide_cache_after_accept(ctx, to_insert)
        if has_remaining then
            slice_suggestions_after_accept(ctx, to_insert)
            update_preview(ctx)
        else
            reset_ctx(ctx)
        end
        ctx.in_accept = nil
    end

    if vim.fn.pumvisible() == 1 then
        -- Accepting Minuet completion while the pum is open is temporary; when
        -- the user closes the pum, Vim restores the buffer state and removes
        -- Minuet's completion text. Close the pum first via feedkeys, then run
        -- the edit on the next tick so the C-e is processed before our edit.
        api.nvim_feedkeys(api.nvim_replace_termcodes('<C-e>', true, true, true), 'n', true)
        vim.schedule(apply)
    else
        apply()
    end
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

    if n_lines then
        local lines = vim.split(suggestion, '\n', { plain = true })
        -- An empty leading element means the original suggestion began with a
        -- newline (typical after a partial accept). The user wants the next
        -- visible line, so bump n_lines past that empty.
        if lines[1] == '' then
            n_lines = n_lines + 1
        end
        n_lines = math.min(n_lines, #lines)
        local picked = vim.list_slice(lines, 1, n_lines)
        accept_n_chars(#table.concat(picked, '\n'))
        return
    end

    accept_n_chars(#suggestion)
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

    -- accept_n_chars sets this around its synchronous buffer edit + cursor
    -- move. The CursorMovedI fired by our own edit must not re-derive from the
    -- cache: accept_n_chars has already sliced ctx.suggestions and slid the
    -- cache forward, so running pool_suggestions here would just race with
    -- that and could repaint with stale state.
    if ctx.in_accept then
        return
    end

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
    -- soft=true preserves ctx.last_trigger_was_manual so a backspace that
    -- realigns the cursor with a cached prefix can revive the suggestion (the
    -- typo+backspace recovery path for manual-trigger users).
    if ctx.shown_choices and next(ctx.shown_choices) then
        cleanup(ctx, true)
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
