-- Round 3 (generality): does a rename-focused prompt break a LOCAL edit (finish
-- the line at the cursor)? Compare an 'improved' (multi-site-leaning) prompt vs a
-- 'balanced' prompt across two scenario types, cursor fed as a SEPARATE channel.

local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { duet = { provider = 'openai_compatible' } }

local session = require 'minuet.duet.session'
local chat = require 'minuet.duet.chat'
local tools = require 'minuet.duet.tools'
local apply_patch = require 'minuet.duet.apply_patch'
local root = require('minuet').config
root.duet.provider_options.openai_compatible.optional.reasoning.effort = os.getenv 'MINUET_EFFORT' or 'medium'
local N = tonumber(os.getenv 'BENCH_N') or 5

-- ---- scenarios -------------------------------------------------------------
-- Each returns { initial, current, cursor={row,col0}, path, grade=fn(new_lines,cur)->'good'|'bad'|... }
local function rename_scenario()
    local original = {
        '#set text(lang: "es")', '', '"max" z = 3x_1 + x_2', 'cases(',
        '  x_1 - x_2 <= -1,', '  -x_1 - x_2 <= -2,', '  2x_1 + x_2 <= 4,', '  x_1, x_2 >= 0', ')',
    }
    local cur = vim.deepcopy(original)
    local cursor
    for _ = 1, 2 do -- rename the two x's on line 3
        local c = cur[3]:find 'x_'
        cur[3] = cur[3]:sub(1, c - 1) .. 'y' .. cur[3]:sub(c + 1)
        cursor = { 3, c }
    end
    local function countx(lines)
        local n = 0
        for _, l in ipairs(lines) do n = n + select(2, l:gsub('x_', '')) end
        return n
    end
    return {
        name = 'rename', path = 'taller.typ', initial = original, current = cur, cursor = cursor,
        grade = function(new_lines)
            local dx = countx(new_lines) - countx(cur)
            return (dx < 0 and 'good') or (dx > 0 and 'revert') or 'noop'
        end,
    }
end

local function local_scenario()
    local initial = {
        'local PI = 3.14159', '', 'local function area(r)', '  return PI * r * r', 'end',
    }
    local current = {
        'local PI = 3.14159', '', 'local function area(r)', '  return PI * r * r', 'end', '',
        'local function circumference(r)', '  return ', 'end',
    }
    return {
        name = 'local', path = 'geom.lua', initial = initial, current = current,
        cursor = { 8, #'  return ' }, -- end of the half-written return line
        grade = function(new_lines, cur)
            -- good = it edited the cursor line (8) and extended it (added content after `return `).
            for i = 1, math.max(#cur, #new_lines) do
                if cur[i] ~= new_lines[i] then
                    if i == 8 and #(new_lines[i] or '') > #(cur[i] or '') then return 'good' end
                    return 'elsewhere(row ' .. i .. ')'
                end
            end
            return 'noop'
        end,
    }
end

-- ---- prompts ---------------------------------------------------------------
local PROMPTS = {
    improved = table.concat({
        "You are a next-edit-prediction engine in the user's editor.",
        'The user is partway through a REPETITIVE multi-site edit (e.g. renaming a',
        'symbol). From their recent edits, infer the transformation and apply it to',
        'the NEXT not-yet-edited occurrence, which is frequently on a DIFFERENT line.',
        'Emit exactly ONE small `*** Update File` apply_patch hunk; context and `-`',
        'lines MUST match the current file byte-for-byte. If unsure, call `read` first.',
        'Never include any cursor annotation in a patch; never revert; never no-op.',
        'If nothing remains to change, reply with `*** No Edit`.',
    }, '\n'),
    balanced = table.concat({
        "You are a next-edit-prediction engine in the user's editor.",
        'From the recent edits and the cursor position, predict the user\'s SINGLE next',
        'edit and emit it via the apply_patch tool. It is usually one of:',
        '  (a) finishing or fixing the edit in progress AT the cursor, or',
        '  (b) the next site of a repetitive change the user is making across the file',
        '      (a rename or similar), often on a DIFFERENT line.',
        'Decide which from the recent edits. Emit exactly ONE small `*** Update File`',
        'hunk; context and `-` lines MUST match the current file byte-for-byte. If',
        'unsure of the exact text, call `read` first. Never include any cursor',
        'annotation in the patch; never revert a recent edit or emit a no-op. If',
        'nothing needs changing, reply with `*** No Edit`.',
    }, '\n'),
}

-- ---- message construction: full file + separate cursor note ----------------
local function build_user(sc)
    local hist = session.render_edit(sc.initial, sc.current, sc.path, 8)
    local line = sc.current[sc.cursor[1]] or ''
    local note = ('Editor cursor: line %d, column %d (1-based). That line currently reads: `%s`')
        :format(sc.cursor[1], sc.cursor[2] + 1, line)
    return table.concat({
        note, '',
        'Recent edits (oldest to newest):', '', hist, '',
        ('Current file `%s`:'):format(sc.path), '',
        table.concat(sc.current, '\n'),
    }, '\n')
end

-- ---- loop ------------------------------------------------------------------
local function ask(messages)
    local done, result
    chat.request(messages, tools.specs(), function(r) result = r; done = true end)
    vim.wait(60000, function() return done end, 50)
    return result
end
local function echo(m)
    return { role = 'assistant', tool_calls = m.tool_calls, content = (type(m.content) == 'string') and m.content or vim.NIL }
end
local function run_loop(messages, sc, bufnr)
    local attempts, reads = 0, 0
    while attempts < 3 do
        local result = ask(messages)
        if not result or result.error then return { success = false, reads = reads, attempts = attempts } end
        local m = result.message
        local call = m.tool_calls and m.tool_calls[1]
        if call and call['function'] then
            local name = call['function'].name
            local ok, args = pcall(vim.json.decode, call['function'].arguments or '{}')
            args = ok and args or {}
            if name == 'read' then
                if reads >= 2 then return { success = false, reason = 'read_budget', reads = reads, attempts = attempts } end
                table.insert(messages, echo(m))
                table.insert(messages, { role = 'tool', tool_call_id = call.id, content = tools.read_result(bufnr, args) })
                reads = reads + 1
            elseif name == 'apply_patch' then
                local applied, new_lines, err = apply_patch.apply(sc.current, args.input or '')
                if applied then
                    return { success = true, reads = reads, attempts = attempts, class = sc.grade(new_lines, sc.current) }
                end
                table.insert(messages, echo(m))
                table.insert(messages, { role = 'tool', tool_call_id = call.id, content = 'apply_patch failed: ' .. tostring(err) .. '\nYou may call `read` then retry.' })
                attempts = attempts + 1
            else
                attempts = attempts + 1
            end
        else
            local c = type(m.content) == 'string' and m.content or ''
            if c:find '%*%*%* No Edit' then return { success = false, reason = 'no_edit', reads = reads, attempts = attempts } end
            attempts = attempts + 1
        end
    end
    return { success = false, reason = 'exhausted', reads = reads, attempts = attempts }
end

-- ---- driver ----------------------------------------------------------------
print(('round3 effort=%s N=%d  (cursor = separate note; structure = full file)'):format(
    root.duet.provider_options.openai_compatible.optional.reasoning.effort, N))
print '----------------------------------------------------------------------'
for _, mk in ipairs { rename_scenario, local_scenario } do
    local sc = mk()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sc.current)
    for _, pname in ipairs { 'improved', 'balanced' } do
        local ok, good, classes = 0, 0, {}
        io.write(('  %-7s %-9s '):format(sc.name, pname))
        for _ = 1, N do
            local r = run_loop({ { role = 'system', content = PROMPTS[pname] }, { role = 'user', content = build_user(sc) } }, sc, bufnr)
            if r.success then
                ok = ok + 1
                classes[r.class] = (classes[r.class] or 0) + 1
                if r.class == 'good' then good = good + 1 end
                io.write(r.class == 'good' and '+' or '~')
            else
                io.write('x')
            end
            io.flush()
        end
        local cs = {}
        for k, v in pairs(classes) do table.insert(cs, k .. '=' .. v) end
        print(('  -> apply_ok %d/%d  good %d/%d  [%s]'):format(ok, N, good, N, table.concat(cs, ' ')))
    end
end
