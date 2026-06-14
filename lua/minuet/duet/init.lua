local api = vim.api
local apply_patch = require 'minuet.duet.apply_patch'
local session = require 'minuet.duet.session'
local tools = require 'minuet.duet.tools'
local chat = require 'minuet.duet.chat'
local preview = require 'minuet.duet.preview'
local utils = require 'minuet.duet.utils'

local M = {}

M.augroup = api.nvim_create_augroup('MinuetDuet', { clear = true })
M.auto_enabled = nil -- nil = follow config default; true/false override at runtime

local internal = {
    states = {},
    request_seq = 0,
    debounce = {}, -- bufnr -> uv_timer
    memory = {}, -- bufnr -> list of { patch, result }: inter-diff memory of shown predictions
    shown_mem = nil, -- the memory entry for the preview currently on screen
}

-- Session transcript surfaced by `:Minuet duet inspect`: one record per
-- prediction (inputs / model turns / outcome / user result). M.last is the most
-- recent; M.history keeps the recent run so you can review what the model
-- inferred over time and which suggestions you accepted / ignored / rejected.
M.last = nil
M.history = {}
local HISTORY_MAX = 12

--- Record the user's disposition on the prediction whose preview is on screen.
--- `force` overrides the default (only settle a still-"shown" record), used when
--- the user explicitly accepts/dismisses/cycles. Settles both the inspect record
--- and its inter-diff memory entry.
local function settle(result, force)
    local rec = internal.shown
    if rec and (force or rec.result == 'shown') then
        rec.result = result
    end
    internal.shown = nil
    local mem = internal.shown_mem
    if mem and (force or mem.result == 'shown') then
        mem.result = result
    end
    internal.shown_mem = nil
end

local function record_turn(ctx, turn)
    if ctx.last then
        table.insert(ctx.last.turns, turn)
    end
end

local function set_outcome(ctx, outcome)
    if ctx.last then
        ctx.last.outcome = outcome
    end
end

--- Pull reasoning + assistant text off a response message (both optional).
---@return string? reasoning, string? content
local function msg_meta(message)
    local reasoning = (type(message.reasoning) == 'string' and message.reasoning ~= '') and message.reasoning or nil
    local content = (type(message.content) == 'string' and message.content ~= '') and message.content or nil
    return reasoning, content
end

local function scfg()
    return require('minuet').config.duet.session
end

local function get_memory(bufnr)
    local m = internal.memory[bufnr]
    if not m then
        m = {}
        internal.memory[bufnr] = m
    end
    return m
end

--- Phrase a prior prediction's disposition as a short factual line for replay.
local function disposition_phrase(result)
    if result == 'accepted' then
        return 'The user accepted it.'
    elseif result == 'dismissed' then
        return 'The user dismissed it.'
    elseif result == 'rejected (cycled)' then
        return 'The user rejected it and asked for a different edit.'
    end
    return 'The user did not use it.' -- ignored / superseded
end

--- Record a shown prediction in the per-buffer inter-diff memory: its patch now,
--- the user's disposition later (via settle). Capped to the most recent N.
local function remember_shown(bufnr, patch)
    local s = scfg()
    if not s.prediction_memory then
        return
    end
    local mem = get_memory(bufnr)
    local entry = { patch = patch, result = 'shown' }
    mem[#mem + 1] = entry
    while #mem > (s.prediction_memory_max or 8) do
        table.remove(mem, 1)
    end
    internal.shown_mem = entry
end

local function get_state(bufnr)
    local state = internal.states[bufnr]
    if not state then
        state = {}
        internal.states[bufnr] = state
    end
    return state
end

local function clear_state(bufnr, state)
    state = state or get_state(bufnr)
    preview.clear(bufnr, state)
    state.pending_seq = nil
    state.changedtick = nil
    state.range = nil
    state.original_lines = nil
    state.proposed_lines = nil
    state.proposed_cursor = nil
    state.proposed_patch = nil
end

local function buf_lines(bufnr)
    return api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function is_normal_mode()
    return api.nvim_get_mode().mode:sub(1, 1) == 'n'
end

--- Only act on real, editable file buffers. Skips the `:Minuet duet inspect`
--- float, read-only scratch views, and any other scratch/special buffer (help,
--- terminal, prompt, nofile), which otherwise leaks an auto-trigger onto
--- non-file content.
local function is_file_buffer(bufnr)
    return api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == '' and vim.bo[bufnr].modifiable
end

local function auto_active()
    if M.auto_enabled ~= nil then
        return M.auto_enabled
    end
    return require('minuet').config.duet.session.auto_trigger
end

--- Assemble the message list for a prediction: system (+ capability reminder +
--- the mode-specific decline policy) and the session user turn (recent edits +
--- cursor file), plus an optional "propose a different edit" nudge for cycling.
---@param mode 'manual'|'auto'
local function build_messages(bufnr, mode, reject_patch)
    local s = scfg()
    local system = s.system .. '\n\n' .. s.capability_reminder
    -- Only auto-trigger may legitimately decline; a manual trigger must edit.
    system = system .. '\n\n' .. (mode == 'auto' and s.auto_instruction or s.manual_instruction)
    local messages = { { role = 'system', content = system } }

    -- Inter-diff memory: replay this session's earlier predictions as interleaved
    -- turns (the model's own patch, then what the user did with it) BEFORE the
    -- full current file. Additive — the full file still follows. See duet-nes-spec.md.
    local mem = s.prediction_memory and internal.memory[bufnr]
    if mem and #mem > 0 then
        table.insert(messages, { role = 'user', content = s.memory_preamble })
        for _, entry in ipairs(mem) do
            table.insert(messages, { role = 'assistant', content = entry.patch })
            table.insert(messages, { role = 'user', content = disposition_phrase(entry.result) })
        end
    end

    local user = session.build_user_turn(bufnr, {
        ctx_lines = s.history_context_lines,
    })
    if reject_patch then
        user = user
            .. '\n\nThe following edit was already proposed and rejected; propose a DIFFERENT next edit:\n'
            .. reject_patch
    end
    table.insert(messages, { role = 'user', content = user })
    return messages
end

--- A clean assistant message to echo back before a tool result.
local function assistant_echo(message)
    local echo = { role = 'assistant', tool_calls = message.tool_calls }
    echo.content = (type(message.content) == 'string') and message.content or vim.NIL
    return echo
end

local function first_diff_row(a, b)
    for i = 1, math.max(#a, #b) do
        if a[i] ~= b[i] then
            return i
        end
    end
    return 1
end

local function show_preview(bufnr, state, original_lines, new_lines, changedtick, patch)
    state.changedtick = changedtick
    state.range = { start_row = 0, end_row = #original_lines }
    state.original_lines = original_lines
    state.proposed_lines = new_lines
    state.proposed_cursor = nil
    state.proposed_patch = patch
    preview.render(bufnr, state)
end

-- Forward declaration so the async loop can recurse.
local run_loop

---@param ctx table
function run_loop(ctx)
    local s = scfg()
    if ctx.attempts >= (s.max_attempts or 3) then
        utils.notify('Minuet duet: no valid patch after ' .. ctx.attempts .. ' attempts.', 'warn', vim.log.levels.WARN)
        set_outcome(ctx, 'no valid patch after ' .. ctx.attempts .. ' attempts')
        ctx.state.pending_seq = nil
        return
    end

    chat.request(ctx.messages, tools.specs(), function(result)
        vim.schedule(function()
            if not api.nvim_buf_is_loaded(ctx.bufnr) or ctx.state.pending_seq ~= ctx.seq then
                return -- superseded or buffer gone
            end

            if result.error then
                utils.notify('Minuet duet request failed: ' .. result.error, 'warn', vim.log.levels.WARN)
                set_outcome(ctx, 'request failed: ' .. tostring(result.error))
                ctx.state.pending_seq = nil
                return
            end

            local message = result.message
            local call = message.tool_calls and message.tool_calls[1]
            local reasoning, msg_content = msg_meta(message)

            -- Tool call path -------------------------------------------------
            if call and call['function'] then
                local name = call['function'].name
                local ok_args, args = pcall(vim.json.decode, call['function'].arguments or '{}')
                args = ok_args and args or {}

                if name == 'read' then
                    if ctx.reads >= (s.max_reads or 2) then
                        -- Read budget exhausted: stop rather than service another read,
                        -- otherwise a model that keeps calling `read` loops unbounded
                        -- (reads do not spend an attempt).
                        utils.notify('Minuet duet: read limit reached; no patch produced.', 'verbose', vim.log.levels.INFO)
                        record_turn(ctx, { kind = 'read', reasoning = reasoning, args = args, refused = true })
                        set_outcome(ctx, 'read limit reached')
                        ctx.state.pending_seq = nil
                        return
                    end
                    local content = tools.read_result(ctx.bufnr, args)
                    record_turn(ctx, { kind = 'read', reasoning = reasoning, args = args, result = content })
                    table.insert(ctx.messages, assistant_echo(message))
                    table.insert(ctx.messages, { role = 'tool', tool_call_id = call.id, content = content })
                    ctx.reads = ctx.reads + 1
                    run_loop(ctx) -- read does not spend an attempt
                    return
                elseif name == 'apply_patch' then
                    local patch = args.input or ''
                    if utils.get_changedtick(ctx.bufnr) ~= ctx.changedtick then
                        utils.notify('Minuet duet: buffer changed; discarded.', 'verbose', vim.log.levels.INFO)
                        record_turn(ctx, { kind = 'apply_patch', reasoning = reasoning, content = msg_content, patch = patch })
                        set_outcome(ctx, 'buffer changed; discarded')
                        ctx.state.pending_seq = nil
                        return
                    end
                    local applied, new_lines, err = apply_patch.apply(ctx.buf_lines, patch, { cursor_row = ctx.cursor_row })
                    record_turn(ctx, {
                        kind = 'apply_patch',
                        reasoning = reasoning,
                        content = msg_content,
                        patch = patch,
                        applied = applied,
                        error = err,
                    })
                    if applied then
                        set_outcome(ctx, 'preview shown')
                        if ctx.last then
                            ctx.last.result = 'shown'
                        end
                        internal.shown = ctx.last
                        remember_shown(ctx.bufnr, patch)
                        ctx.state.pending_seq = nil
                        show_preview(ctx.bufnr, ctx.state, ctx.buf_lines, new_lines, ctx.changedtick, patch)
                        return
                    end
                    table.insert(ctx.messages, assistant_echo(message))
                    table.insert(ctx.messages, {
                        role = 'tool',
                        tool_call_id = call.id,
                        content = 'apply_patch failed: '
                            .. tostring(err)
                            .. '\nYou may call `read` to re-check the exact buffer text, then emit a corrected patch.',
                    })
                    ctx.attempts = ctx.attempts + 1
                    run_loop(ctx)
                    return
                end
            end

            -- Plain-content fallbacks ---------------------------------------
            local content = type(message.content) == 'string' and message.content or ''
            if content:find '%*%*%* Begin Patch' then
                local applied, new_lines, err = apply_patch.apply(ctx.buf_lines, content, { cursor_row = ctx.cursor_row })
                record_turn(ctx, { kind = 'content_patch', reasoning = reasoning, content = content, patch = content, applied = applied, error = err })
                if applied then
                    set_outcome(ctx, 'preview shown')
                    if ctx.last then
                        ctx.last.result = 'shown'
                    end
                    internal.shown = ctx.last
                    remember_shown(ctx.bufnr, content)
                    ctx.state.pending_seq = nil
                    show_preview(ctx.bufnr, ctx.state, ctx.buf_lines, new_lines, ctx.changedtick, content)
                else
                    table.insert(ctx.messages, assistant_echo(message))
                    table.insert(ctx.messages, { role = 'user', content = 'apply_patch failed: ' .. tostring(err) })
                    ctx.attempts = ctx.attempts + 1
                    run_loop(ctx)
                end
                return
            end

            if content:find(vim.pesc(s.no_edit_token)) then
                record_turn(ctx, { kind = 'no_edit', reasoning = reasoning, content = content })
                if ctx.mode == 'auto' then
                    set_outcome(ctx, 'no edit suggested')
                    ctx.state.pending_seq = nil
                    return
                end
                -- Manual trigger: declining is not a valid response. Tell the model
                -- what went wrong and have it try again (this spends an attempt).
                table.insert(ctx.messages, assistant_echo(message))
                table.insert(ctx.messages, {
                    role = 'user',
                    content = '`'
                        .. s.no_edit_token
                        .. '` is invalid here: this prediction was manually requested by the user, so you '
                        .. 'must propose a concrete next edit. Emit exactly one small apply_patch hunk for '
                        .. 'the most likely next edit now.',
                })
                ctx.attempts = ctx.attempts + 1
                run_loop(ctx)
                return
            end

            record_turn(ctx, { kind = 'other', reasoning = reasoning, content = content })
            set_outcome(ctx, 'no usable edit')
            ctx.state.pending_seq = nil
            if ctx.mode ~= 'auto' then
                utils.notify('Minuet duet: model returned no usable edit.', 'verbose', vim.log.levels.INFO)
            end
        end)
    end)
end

---@param mode? 'manual'|'auto'
---@param opts? { reject_patch?: string }
local function predict(mode, opts)
    mode = mode or 'manual'
    opts = opts or {}
    local bufnr = api.nvim_get_current_buf()
    if not is_file_buffer(bufnr) then
        return -- never predict on the inspect float or other scratch/special buffers
    end
    local state = get_state(bufnr)
    -- A preview still on screen when a new prediction starts was passed over.
    settle('ignored', false)
    clear_state(bufnr, state)

    local s = scfg()
    if session.should_reset(bufnr, s.max_edits, s.idle_minutes) then
        session.reset(bufnr, s.seed_edits)
        internal.memory[bufnr] = nil -- fresh session: drop prior-prediction memory
    end

    internal.request_seq = internal.request_seq + 1
    local seq = internal.request_seq
    state.pending_seq = seq
    state.mode = mode

    if mode ~= 'auto' then
        utils.notify('Minuet duet predicting...', 'verbose', vim.log.levels.INFO)
    end

    local messages = build_messages(bufnr, mode, opts.reject_patch)
    local duet = require('minuet').config.duet
    local popts = duet.provider_options[duet.provider] or {}
    M.last = {
        time = os.date '%H:%M:%S',
        path = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ':.'),
        mode = mode,
        model = popts.model,
        effort = popts.optional and popts.optional.reasoning and popts.optional.reasoning.effort or nil,
        system = messages[1].content,
        user = messages[#messages].content, -- the final user turn (after any memory turns)
        turns = {},
        outcome = 'pending',
        result = nil, -- user disposition: shown/accepted/dismissed/rejected/ignored
    }
    table.insert(M.history, M.last)
    if #M.history > HISTORY_MAX then
        table.remove(M.history, 1)
    end

    run_loop {
        bufnr = bufnr,
        state = state,
        seq = seq,
        changedtick = utils.get_changedtick(bufnr),
        buf_lines = buf_lines(bufnr),
        cursor_row = api.nvim_win_get_cursor(0)[1], -- bias patch matching toward the cursor
        messages = messages,
        mode = mode,
        attempts = 0,
        reads = 0,
        last = M.last,
    }
end

local function apply()
    local bufnr = api.nvim_get_current_buf()
    local state = get_state(bufnr)

    if not state.proposed_lines or not state.range then
        utils.notify('No Minuet duet prediction to apply.', 'warn', vim.log.levels.WARN)
        return
    end
    if utils.get_changedtick(bufnr) ~= state.changedtick then
        settle('ignored', false)
        clear_state(bufnr, state)
        utils.notify('Minuet duet prediction is stale and has been discarded.', 'warn', vim.log.levels.WARN)
        return
    end

    settle('accepted', true)

    local original = state.original_lines
    local proposed = state.proposed_lines
    local target_row = first_diff_row(original, proposed)

    api.nvim_buf_set_lines(bufnr, 0, -1, false, proposed)
    -- The accepted edit becomes the new baseline (do not capture it as a user edit).
    session.rebase(bufnr)

    target_row = math.min(target_row, #proposed)
    local line = api.nvim_buf_get_lines(bufnr, target_row - 1, target_row, false)[1] or ''
    pcall(api.nvim_win_set_cursor, 0, { target_row, #line })

    clear_state(bufnr, state)

    -- Burst: chain straight into the next prediction when auto-trigger is on.
    -- `nvim_buf_set_lines` does not fire TextChanged, so the edit-capture autocmd
    -- never sees this accept; fire it here (no debounce) so consecutive accepts
    -- feel instant.
    if auto_active() then
        vim.schedule(function()
            if api.nvim_buf_is_loaded(bufnr) and api.nvim_get_current_buf() == bufnr and is_normal_mode() then
                predict 'auto'
            end
        end)
    end
end

local function dismiss()
    local bufnr = api.nvim_get_current_buf()
    settle('dismissed', true)
    clear_state(bufnr, get_state(bufnr))
end

local function cycle()
    local bufnr = api.nvim_get_current_buf()
    local state = get_state(bufnr)
    local reject = state.proposed_patch
    local mode = state.mode or 'manual'
    settle('rejected (cycled)', true)
    clear_state(bufnr, state)
    predict(mode, { reject_patch = reject })
end

local function toggle()
    local enabled = M.auto_enabled
    if enabled == nil then
        enabled = scfg().auto_trigger
    end
    M.auto_enabled = not enabled
    if not M.auto_enabled then
        -- Turning auto off also clears a suggestion already on screen (and cancels
        -- any in-flight prediction via clear_state), like virtualtext's disable.
        dismiss()
    end
    -- User-initiated status: notify directly (always shown), matching the
    -- virtualtext/cmp toggle convention rather than the gated utils.notify.
    vim.notify('Minuet duet auto-trigger ' .. (M.auto_enabled and 'enabled' or 'disabled'), vim.log.levels.INFO)
end

-- Debounced per-buffer handler for edits: capture history, invalidate preview,
-- and optionally auto-trigger.
local function on_edit(info)
    local bufnr = info.buf
    if not is_file_buffer(bufnr) then
        return -- ignore edits on the inspect float / scratch buffers
    end
    -- An edit while a preview is up means the user passed it over.
    settle('ignored', false)
    local state = internal.states[bufnr]
    if state then
        clear_state(bufnr, state)
    end

    local timer = internal.debounce[bufnr]
    if timer then
        timer:stop()
        timer:close()
    end
    timer = vim.uv.new_timer()
    internal.debounce[bufnr] = timer
    timer:start(scfg().debounce_ms or 150, 0, function()
        timer:stop()
        timer:close()
        internal.debounce[bufnr] = nil
        vim.schedule(function()
            if not api.nvim_buf_is_loaded(bufnr) then
                return
            end
            session.capture(bufnr, scfg().history_context_lines)
            if auto_active() and api.nvim_get_current_buf() == bufnr and is_normal_mode() then
                predict 'auto'
            end
        end)
    end)
end

local action = {
    predict = function()
        predict 'manual'
    end,
    apply = apply,
    dismiss = dismiss,
    cycle = cycle,
    toggle = toggle,
    -- Toggle the introspection float showing the session: each prediction's
    -- model reasoning, patch, outcome and the result (accepted/ignored/...).
    inspect = function()
        require('minuet.duet.inspect').toggle(M.history)
    end,
    is_visible = function()
        local bufnr = api.nvim_get_current_buf()
        return preview.is_visible(bufnr, get_state(bufnr))
    end,
}

M.action = action

function M.setup()
    api.nvim_clear_autocmds { group = M.augroup }

    api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
        group = M.augroup,
        callback = on_edit,
        desc = '[minuet.duet] capture edit history + invalidate preview',
    })

    api.nvim_create_autocmd('InsertEnter', {
        group = M.augroup,
        callback = function(info)
            -- NES is normal-mode; a preview should not linger once the user types.
            local state = internal.states[info.buf]
            if state then
                settle('ignored', false)
                clear_state(info.buf, state)
            end
        end,
        desc = '[minuet.duet] dismiss preview on entering insert mode',
    })

    api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
        group = M.augroup,
        callback = function(info)
            -- Initialise the session baseline before any edits so the first edit is captured.
            session.get_state(info.buf)
        end,
        desc = '[minuet.duet] seed session baseline',
    })

    api.nvim_create_autocmd('BufWipeout', {
        group = M.augroup,
        callback = function(info)
            internal.states[info.buf] = nil
            internal.memory[info.buf] = nil
            local timer = internal.debounce[info.buf]
            if timer then
                pcall(function()
                    timer:stop()
                    timer:close()
                end)
                internal.debounce[info.buf] = nil
            end
            session.clear(info.buf)
        end,
        desc = '[minuet.duet] clear state on buf wipeout',
    })
end

return M
