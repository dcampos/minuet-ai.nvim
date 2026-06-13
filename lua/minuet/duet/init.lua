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
}

local function scfg()
    return require('minuet').config.duet.session
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

--- Assemble the message list for a prediction: system (+ capability reminder)
--- and the session user turn (recent edits + cursor file), plus an optional
--- "propose a different edit" nudge for cycling.
local function build_messages(bufnr, reject_patch)
    local s = scfg()
    local system = s.system .. '\n\n' .. s.capability_reminder
    local user = session.build_user_turn(bufnr, {
        cursor_marker = s.cursor_marker,
        ctx_lines = s.history_context_lines,
    })
    if reject_patch then
        user = user
            .. '\n\nThe following edit was already proposed and rejected; propose a DIFFERENT next edit:\n'
            .. reject_patch
    end
    return {
        { role = 'system', content = system },
        { role = 'user', content = user },
    }
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
                ctx.state.pending_seq = nil
                return
            end

            local message = result.message
            local call = message.tool_calls and message.tool_calls[1]

            -- Tool call path -------------------------------------------------
            if call and call['function'] then
                local name = call['function'].name
                local ok_args, args = pcall(vim.json.decode, call['function'].arguments or '{}')
                args = ok_args and args or {}

                if name == 'read' then
                    if ctx.reads >= (s.max_reads or 2) then
                        utils.notify('Minuet duet: read limit reached.', 'verbose', vim.log.levels.INFO)
                    end
                    local content = tools.read_result(ctx.bufnr, args)
                    table.insert(ctx.messages, assistant_echo(message))
                    table.insert(ctx.messages, { role = 'tool', tool_call_id = call.id, content = content })
                    ctx.reads = ctx.reads + 1
                    run_loop(ctx) -- read does not spend an attempt
                    return
                elseif name == 'apply_patch' then
                    if utils.get_changedtick(ctx.bufnr) ~= ctx.changedtick then
                        utils.notify('Minuet duet: buffer changed; discarded.', 'verbose', vim.log.levels.INFO)
                        ctx.state.pending_seq = nil
                        return
                    end
                    local patch = args.input or ''
                    local applied, new_lines, err = apply_patch.apply(ctx.buf_lines, patch)
                    if applied then
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
                local applied, new_lines, err = apply_patch.apply(ctx.buf_lines, content)
                if applied then
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
                ctx.state.pending_seq = nil
                if ctx.mode ~= 'auto' then
                    utils.notify('Minuet duet: no edit suggested.', 'verbose', vim.log.levels.INFO)
                end
                return
            end

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
    local state = get_state(bufnr)
    clear_state(bufnr, state)

    local s = scfg()
    if session.should_reset(bufnr, s.max_edits, s.idle_minutes) then
        session.reset(bufnr, s.seed_edits)
    end

    internal.request_seq = internal.request_seq + 1
    local seq = internal.request_seq
    state.pending_seq = seq
    state.mode = mode

    if mode ~= 'auto' then
        utils.notify('Minuet duet predicting...', 'verbose', vim.log.levels.INFO)
    end

    run_loop {
        bufnr = bufnr,
        state = state,
        seq = seq,
        changedtick = utils.get_changedtick(bufnr),
        buf_lines = buf_lines(bufnr),
        messages = build_messages(bufnr, opts.reject_patch),
        mode = mode,
        attempts = 0,
        reads = 0,
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
        clear_state(bufnr, state)
        utils.notify('Minuet duet prediction is stale and has been discarded.', 'warn', vim.log.levels.WARN)
        return
    end

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
end

local function dismiss()
    local bufnr = api.nvim_get_current_buf()
    clear_state(bufnr, get_state(bufnr))
end

local function cycle()
    local bufnr = api.nvim_get_current_buf()
    local state = get_state(bufnr)
    local reject = state.proposed_patch
    local mode = state.mode or 'manual'
    clear_state(bufnr, state)
    predict(mode, { reject_patch = reject })
end

local function toggle()
    local enabled = M.auto_enabled
    if enabled == nil then
        enabled = scfg().auto_trigger
    end
    M.auto_enabled = not enabled
    utils.notify(
        'Minuet duet auto-trigger ' .. (M.auto_enabled and 'enabled' or 'disabled'),
        'info',
        vim.log.levels.INFO
    )
end

local function auto_active()
    if M.auto_enabled ~= nil then
        return M.auto_enabled
    end
    return scfg().auto_trigger
end

-- Debounced per-buffer handler for edits: capture history, invalidate preview,
-- and optionally auto-trigger.
local function on_edit(info)
    local bufnr = info.buf
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
