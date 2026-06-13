-- Verify the SHIPPED config prompt: rename@k=1 acts fast/forward without read,
-- and the local-edit case still finishes at the cursor (no regression).
local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { duet = { provider = 'openai_compatible' } }

local session = require 'minuet.duet.session'
local chat = require 'minuet.duet.chat'
local tools = require 'minuet.duet.tools'
local apply_patch = require 'minuet.duet.apply_patch'
local root = require('minuet').config
root.duet.provider_options.openai_compatible.optional.reasoning.effort = 'medium'
local N = tonumber(os.getenv 'BENCH_N') or 6
local SYS = root.duet.session.system .. '\n\n' .. root.duet.session.capability_reminder

local function ask(user)
    local done, result
    chat.request({ { role = 'system', content = SYS }, { role = 'user', content = user } },
        tools.specs(), function(r) result = r; done = true end)
    vim.wait(40000, function() return done end, 50)
    if not result or result.error then return nil end
    local m = result.message
    local call = m.tool_calls and m.tool_calls[1]
    return m, call
end

local function note(line, row, col)
    return ('Editor cursor: line %d, column %d (1-based). That line currently reads: `%s`'):format(row, col, line)
end

-- A) rename, k=1: one edit done on line 3; next x is on the same line.
local A_initial = { '#set text(lang: "es")', '', '"max" z = 3x_1 + x_2', 'cases(', '  x_1 - x_2 <= -1,', ')' }
local A_current = vim.deepcopy(A_initial)
A_current[3] = '"max" z = 3y_1 + x_2'
local A_user = table.concat({
    note(A_current[3], 3, 12), '',
    'Recent edits (oldest to newest):', '', session.render_edit(A_initial, A_current, 'a.typ', 8), '',
    'Current file `a.typ`:', '', table.concat(A_current, '\n'),
}, '\n')

-- B) local: just added a function with a half-written `return `; finish at cursor.
local B_initial = { 'local PI = 3.14159', '', 'local function area(r)', '  return PI * r * r', 'end' }
local B_current = { 'local PI = 3.14159', '', 'local function area(r)', '  return PI * r * r', 'end', '',
    'local function circumference(r)', '  return ', 'end' }
local B_user = table.concat({
    note(B_current[8], 8, #'  return ' + 1), '',
    'Recent edits (oldest to newest):', '', session.render_edit(B_initial, B_current, 'g.lua', 8), '',
    'Current file `g.lua`:', '', table.concat(B_current, '\n'),
}, '\n')

local function countx(lines)
    local n = 0; for _, l in ipairs(lines) do n = n + select(2, l:gsub('x_', '')) end; return n
end

print('verify shipped prompt · effort=medium · N=' .. N)
print('----------------------------------------------------------------------')

-- A
do
    local acted, forward, read = 0, 0, 0
    io.write('  A rename k=1   ')
    for _ = 1, N do
        local m, call = ask(A_user)
        if call and call['function'] then
            if call['function'].name == 'read' then read = read + 1; io.write('r')
            else
                acted = acted + 1
                local args = vim.json.decode(call['function'].arguments or '{}')
                local ok, nl = apply_patch.apply(A_current, args.input or '')
                if ok and countx(nl) < countx(A_current) then forward = forward + 1; io.write('+') else io.write('o') end
            end
        else io.write('.') end
        io.flush()
    end
    print(('  -> acted %d/%d forward %d/%d read %d/%d'):format(acted, N, forward, N, read, N))
end

-- B
do
    local good, elsewhere, read = 0, 0, 0
    io.write('  B local        ')
    for _ = 1, N do
        local m, call = ask(B_user)
        if call and call['function'] then
            if call['function'].name == 'read' then read = read + 1; io.write('r')
            else
                local args = vim.json.decode(call['function'].arguments or '{}')
                local ok, nl = apply_patch.apply(B_current, args.input or '')
                if ok then
                    local changed
                    for i = 1, math.max(#B_current, #nl) do if B_current[i] ~= nl[i] then changed = i; break end end
                    if changed == 8 and #(nl[8] or '') > #B_current[8] then good = good + 1; io.write('+')
                    else elsewhere = elsewhere + 1; io.write('o') end
                else io.write('x') end
            end
        else io.write('.') end
        io.flush()
    end
    print(('  -> finished-at-cursor %d/%d  elsewhere %d/%d  read %d/%d'):format(good, N, elsewhere, N, read, N))
end
