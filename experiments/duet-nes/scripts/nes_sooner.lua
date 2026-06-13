-- "Get me sooner": measure the FIRST model turn (no loop) at k=1 and k=2 edits.
-- Does the model act immediately (apply_patch) and correctly (forward), or does
-- it hesitate (read)? Compare the shipped prompt vs an 'eager' variant that says
-- act on a single edit and don't read (we already send the whole file).

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
local N = tonumber(os.getenv 'BENCH_N') or 8

local ORIGINAL = {
    '#set text(lang: "es")', '', '"max" z = 3x_1 + x_2', 'cases(',
    '  x_1 - x_2 <= -1,', '  -x_1 - x_2 <= -2,', '  2x_1 + x_2 <= 4,', '  x_1, x_2 >= 0', ')',
}

local function make(k)
    local snaps = { vim.deepcopy(ORIGINAL) }
    local cur, cursor = vim.deepcopy(ORIGINAL), { 1, 0 }
    for _ = 1, k do
        for row = 1, #cur do
            local c = cur[row]:find 'x_'
            if c then
                cur[row] = cur[row]:sub(1, c - 1) .. 'y' .. cur[row]:sub(c + 1)
                cursor = { row, c }
                break
            end
        end
        table.insert(snaps, vim.deepcopy(cur))
    end
    return { snaps = snaps, current = cur, cursor = cursor, k = k }
end

local SHIPPED = root.duet.session.system .. '\n\n' .. root.duet.session.capability_reminder
local EAGER = SHIPPED
    .. '\n\nBe decisive: even a SINGLE recent edit can be the start of a repeated '
    .. 'change (a rename or refactor). If the recent edit looks repeatable and other '
    .. 'matching sites remain, propose the next one NOW rather than waiting for more '
    .. 'examples. You already have the full current file and the cursor note, so do '
    .. 'NOT call `read` unless a previous patch in this turn failed to apply.'

local function build_user(sc)
    local hist = {}
    for i = 1, sc.k do
        table.insert(hist, session.render_edit(sc.snaps[i], sc.snaps[i + 1], 'taller.typ', 8))
    end
    local line = sc.current[sc.cursor[1]] or ''
    local note = ('Editor cursor: line %d, column %d (1-based). That line currently reads: `%s`')
        :format(sc.cursor[1], sc.cursor[2] + 1, line)
    return table.concat({
        note, '',
        'Recent edits (oldest to newest):', '', table.concat(hist, '\n\n'), '',
        'Current file `taller.typ`:', '', table.concat(sc.current, '\n'),
    }, '\n')
end

local function countx(lines)
    local n = 0
    for _, l in ipairs(lines) do n = n + select(2, l:gsub('x_', '')) end
    return n
end

-- Single turn. Returns class: read / forward / other_apply / badpatch / no_edit / other
local function one_turn(system, sc)
    local done, result
    chat.request({ { role = 'system', content = system }, { role = 'user', content = build_user(sc) } },
        tools.specs(), function(r) result = r; done = true end)
    vim.wait(40000, function() return done end, 50)
    if not result or result.error then return 'error' end
    local m = result.message
    local call = m.tool_calls and m.tool_calls[1]
    if not (call and call['function']) then
        return (m.content and m.content:find '%*%*%* No Edit') and 'no_edit' or 'other'
    end
    if call['function'].name == 'read' then return 'read' end
    local args = vim.json.decode(call['function'].arguments or '{}')
    local ok, nl = apply_patch.apply(sc.current, args.input or '')
    if not ok then return 'badpatch' end
    return (countx(nl) < countx(sc.current)) and 'forward' or 'other_apply'
end

print(('"sooner" bench · effort=%s · N=%d · single first turn'):format(
    root.duet.provider_options.openai_compatible.optional.reasoning.effort, N))
print('metrics: acted=apply_patch (not read), forward=correct next rename, read=hesitated')
print('----------------------------------------------------------------------')
for _, k in ipairs { 1, 2 } do
    local sc = make(k)
    for _, p in ipairs { { 'shipped', SHIPPED }, { 'eager', EAGER } } do
        local cnt = {}
        io.write(('  k=%d %-8s '):format(k, p[1]))
        for _ = 1, N do
            local c = one_turn(p[2], sc)
            cnt[c] = (cnt[c] or 0) + 1
            io.write(({ read = 'r', forward = '+', other_apply = 'o', badpatch = 'x', no_edit = 'n', other = '?', error = 'E' })[c] or '.')
            io.flush()
        end
        local acted = (cnt.forward or 0) + (cnt.other_apply or 0) + (cnt.badpatch or 0)
        print(('  -> acted %d/%d  forward %d/%d  read %d/%d  badpatch %d/%d'):format(
            acted, N, cnt.forward or 0, N, cnt.read or 0, N, cnt.badpatch or 0, N))
    end
end
