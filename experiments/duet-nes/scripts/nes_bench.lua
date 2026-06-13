-- Bench: does an append-only KV-log (initial state + small diffs + plans +
-- consolidated big-context diff) make apply_patch SUCCEED more often than the
-- current "8-line history diffs + full current file + cursor marker" turn?
--
-- For each (scenario stage, strategy, sample) we run the real predict loop
-- (max_attempts=3, max_reads=2) and record whether it ever produces a cleanly
-- applying patch, plus whether that patch is a forward edit (vs revert/no-op).
--
-- Env: BENCH_N (samples/cell, default 5), BENCH_STAGES ("2,5" default),
--      BENCH_STRATS (csv, default all), MINUET_EFFORT (default medium).

local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { duet = { provider = 'openai_compatible' } }

local session = require 'minuet.duet.session'
local chat = require 'minuet.duet.chat'
local tools = require 'minuet.duet.tools'
local apply_patch = require 'minuet.duet.apply_patch'
local root = require('minuet').config

local EFFORT = os.getenv 'MINUET_EFFORT' or 'medium'
root.duet.provider_options.openai_compatible.optional.reasoning.effort = EFFORT
local N = tonumber(os.getenv 'BENCH_N') or 5
local STAGES = {}
for s in (os.getenv 'BENCH_STAGES' or '2,5'):gmatch '%d+' do
    table.insert(STAGES, tonumber(s))
end
local PATH = 'taller.typ'

local ORIGINAL = {
    '#set text(lang: "es")', '', '', '= Taller 2.1: El método simplex revisado', '',
    '1. Dados los siguientes datos de optimización lineal', '$',
    '"max" z = 3x_1 + x_2', '"sujeto a"', 'cases(',
    '  x_1 - x_2 <= -1,', '  -x_1 - x_2 <= -2,', '  2x_1 + x_2 <= 4,', '  x_1, x_2 >= 0', ')', '$',
}

-- Build a scenario: apply `k` x->y renames in document order, recording a
-- snapshot after each plus the cursor position (just after the renamed char).
local function make_scenario(k)
    local snaps = { vim.deepcopy(ORIGINAL) }
    local cursor = { 1, 0 }
    local cur = vim.deepcopy(ORIGINAL)
    for _ = 1, k do
        local found
        for row = 1, #cur do
            local c = cur[row]:find 'x_'
            if c then
                cur[row] = cur[row]:sub(1, c - 1) .. 'y' .. cur[row]:sub(c + 1)
                cursor = { row, c } -- 0-based col after the new 'y'
                found = true
                break
            end
        end
        if not found then
            break
        end
        table.insert(snaps, vim.deepcopy(cur))
    end
    return { snaps = snaps, current = cur, cursor = cursor, k = #snaps - 1 }
end

local function join(lines)
    return table.concat(lines, '\n')
end

-- A short synthetic "plan" a well-behaved model would have emitted for edit i.
local function plan_for(sc, i)
    local row = nil
    local before, after = sc.snaps[i], sc.snaps[i + 1]
    for r = 1, #before do
        if before[r] ~= after[r] then
            row = r
            break
        end
    end
    return ('Plan: renaming variable `x` to `y` everywhere it appears. Applied it to the occurrence on line %d; more `x_` occurrences still remain to convert.'):format(
        row or 0
    )
end

-- ---- prompt / instruction variants ("what to do") --------------------------
local PROMPTS = {
    -- the shipped NES prompt
    baseline = root.duet.session.system .. '\n\n' .. root.duet.session.capability_reminder,

    -- multi-site continuation + exact-match + marker/read/never-revert guidance
    improved = table.concat({
        "You are a next-edit-prediction engine in the user's editor.",
        'The user is partway through a REPETITIVE multi-site edit (e.g. renaming a',
        'symbol). From their recent edits, infer the transformation and apply it to',
        'the NEXT not-yet-edited occurrence, which is frequently on a DIFFERENT line;',
        'scan the whole file.',
        'Emit exactly ONE small `*** Update File` apply_patch hunk (no Add/Delete/Move).',
        'Context and `-` lines MUST match the current file byte-for-byte. If unsure of',
        'the exact current text, call `read` first, then emit the patch. Never include',
        'the `<|cursor|>` marker in a patch; never revert a recent edit; never emit a',
        'no-op. If nothing remains to change, reply with `*** No Edit`.',
    }, '\n'),

    -- terse, apply-validity focused
    terse = table.concat({
        'Predict the user\'s next edit and emit it with the apply_patch tool: exactly',
        'one `*** Update File` hunk whose context and `-` lines match the current file',
        'EXACTLY. The user is repeating an edit across the file; apply it to the next',
        'remaining site (often on another line). If unsure of the exact text, call',
        '`read` first. Do not include `<|cursor|>` in the patch. Do not undo previous edits.',
    }, '\n'),
}

-- ---- strategies: each returns the initial user message content -------------
local strat = {}

function strat.current(sc, marker)
    local parts, hist = {}, {}
    for i = 1, sc.k do
        table.insert(hist, session.render_edit(sc.snaps[i], sc.snaps[i + 1], PATH, 8))
    end
    if #hist > 0 then
        table.insert(parts, 'Recent edits (oldest to newest):')
        table.insert(parts, '')
        table.insert(parts, table.concat(hist, '\n\n'))
        table.insert(parts, '')
    end
    local cur = vim.deepcopy(sc.current)
    if marker then
        local r, c = sc.cursor[1], sc.cursor[2]
        cur[r] = cur[r]:sub(1, c) .. '<|cursor|>' .. cur[r]:sub(c + 1)
        table.insert(parts, ('Current file `%s` (<|cursor|> marks the cursor; it is not real text):'):format(PATH))
    else
        table.insert(parts, ('Current file `%s`:'):format(PATH))
    end
    table.insert(parts, '')
    table.insert(parts, join(cur))
    return table.concat(parts, '\n')
end

function strat.current_marker(sc)
    return strat.current(sc, true)
end
-- Cursor fed as a SEPARATE channel (note up top); file text kept clean / in-distribution.
function strat.current_note(sc)
    local line = sc.current[sc.cursor[1]] or ''
    local note = ('Editor cursor: line %d, column %d (1-based). That line currently reads: `%s`')
        :format(sc.cursor[1], sc.cursor[2] + 1, line)
    return note .. '\n\n' .. strat.current(sc, false)
end
function strat.current_nomarker(sc)
    return strat.current(sc, false)
end

local function proposed(sc, with_plan)
    local parts = {}
    table.insert(parts, ('Initial file `%s`:'):format(PATH))
    table.insert(parts, '')
    table.insert(parts, join(sc.snaps[1]))
    table.insert(parts, '')
    table.insert(parts, 'Edits so far (each a small apply_patch hunk, oldest to newest):')
    table.insert(parts, '')
    for i = 1, sc.k do
        table.insert(parts, session.render_edit(sc.snaps[i], sc.snaps[i + 1], PATH, 2))
        if with_plan then
            table.insert(parts, plan_for(sc, i))
        end
        table.insert(parts, '')
    end
    table.insert(parts, 'Consolidated change so far (initial -> current) with full surrounding context:')
    table.insert(parts, '')
    table.insert(parts, session.render_edit(sc.snaps[1], sc.current, PATH, 9999))
    table.insert(parts, '')
    table.insert(parts, ('The cursor is on line %d. Reconstruct the exact current file from the initial file plus the consolidated change above, then emit (via apply_patch) the single next `*** Update File` edit that continues this pattern; context and `-` lines must match the current file exactly.'):format(sc.cursor[1]))
    return table.concat(parts, '\n')
end

function strat.proposed_noplan(sc)
    return proposed(sc, false)
end
function strat.proposed_plan(sc)
    return proposed(sc, true)
end

-- ---- one synchronous model round trip --------------------------------------
local function ask(messages)
    local done, result
    chat.request(messages, tools.specs(), function(r)
        result = r
        done = true
    end)
    vim.wait(60000, function()
        return done
    end, 50)
    return result
end

local function assistant_echo(message)
    return { role = 'assistant', tool_calls = message.tool_calls, content = (type(message.content) == 'string') and message.content or vim.NIL }
end

-- Run the real predict loop for one sample against `current` lines. Returns
-- success, attempts, reads, class.
local function run_loop(messages, sc, bufnr)
    local attempts, reads = 0, 0
    while attempts < 3 do
        local result = ask(messages)
        if not result or result.error then
            return { success = false, err = result and result.error or 'timeout', attempts = attempts, reads = reads }
        end
        local msg = result.message
        local call = msg.tool_calls and msg.tool_calls[1]
        if call and call['function'] then
            local name = call['function'].name
            local ok, args = pcall(vim.json.decode, call['function'].arguments or '{}')
            args = ok and args or {}
            if name == 'read' then
                if reads >= 2 then
                    return { success = false, reason = 'read_budget', attempts = attempts, reads = reads }
                end
                table.insert(messages, assistant_echo(msg))
                table.insert(messages, { role = 'tool', tool_call_id = call.id, content = tools.read_result(bufnr, args) })
                reads = reads + 1
            elseif name == 'apply_patch' then
                local applied, new_lines, err = apply_patch.apply(sc.current, args.input or '')
                if applied then
                    -- forward = the patch removes an `x_` (renamed to y); revert = adds one back.
                    local function countx(lines)
                        local n = 0
                        for _, l in ipairs(lines) do
                            n = n + select(2, l:gsub('x_', ''))
                        end
                        return n
                    end
                    local dx = countx(new_lines) - countx(sc.current)
                    local class = (dx < 0 and 'forward') or (dx > 0 and 'revert') or 'noop'
                    return { success = true, attempts = attempts, reads = reads, class = class }
                end
                table.insert(messages, assistant_echo(msg))
                table.insert(messages, {
                    role = 'tool',
                    tool_call_id = call.id,
                    content = 'apply_patch failed: ' .. tostring(err) .. '\nYou may call `read` then emit a corrected patch.',
                })
                attempts = attempts + 1
            else
                attempts = attempts + 1
            end
        else
            local content = type(msg.content) == 'string' and msg.content or ''
            if content:find '%*%*%* No Edit' then
                return { success = false, reason = 'no_edit', attempts = attempts, reads = reads }
            end
            attempts = attempts + 1
        end
    end
    return { success = false, reason = 'exhausted', attempts = attempts, reads = reads }
end

-- ---- driver ----------------------------------------------------------------
local order = { 'current_marker', 'current_nomarker', 'proposed_noplan', 'proposed_plan' }
local pick = os.getenv 'BENCH_STRATS'
if pick then
    order = {}
    for s in pick:gmatch '[%w_]+' do
        table.insert(order, s)
    end
end
local prompts = { 'baseline', 'improved', 'terse' }
local ppick = os.getenv 'BENCH_PROMPTS'
if ppick then
    prompts = {}
    for s in ppick:gmatch '[%w_]+' do
        table.insert(prompts, s)
    end
end

print(('bench effort=%s N=%d stages=%s structures=%s prompts=%s'):format(
    EFFORT, N, table.concat(STAGES, ','), table.concat(order, ','), table.concat(prompts, ',')))
print '(per-sample marks: +=apply_ok&forward  ~=apply_ok&revert/noop  x=no valid patch)'
print '----------------------------------------------------------------------'

local results = {}
for _, k in ipairs(STAGES) do
    local sc = make_scenario(k)
    -- real buffer holding the CURRENT state (for read() + cursor)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sc.current)
    for _, pname in ipairs(prompts) do
        for _, sname in ipairs(order) do
            local succ, fwd, att, rds = 0, 0, 0, 0
            io.write(('  k=%d %-9s %-17s '):format(sc.k, pname, sname))
            for _ = 1, N do
                local messages = {
                    { role = 'system', content = PROMPTS[pname] },
                    { role = 'user', content = strat[sname](sc) },
                }
                local r = run_loop(messages, sc, bufnr)
                if r.success then
                    succ = succ + 1
                    if r.class == 'forward' then
                        fwd = fwd + 1
                    end
                end
                att = att + (r.attempts or 0)
                rds = rds + (r.reads or 0)
                io.write(r.success and (r.class == 'forward' and '+' or '~') or 'x')
                io.flush()
            end
            local line = ('apply_ok %d/%d  forward %d/%d  avg_att %.1f avg_read %.1f'):format(
                succ, N, fwd, N, att / N, rds / N)
            print('  -> ' .. line)
            table.insert(results, ('k=%d %-9s %-17s %s'):format(sc.k, pname, sname, line))
        end
    end
end
print '======================================================================'
for _, l in ipairs(results) do
    print(l)
end
print '----------------------------------------------------------------------'
print('done. effort=' .. EFFORT)
