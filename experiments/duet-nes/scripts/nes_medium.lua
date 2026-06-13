-- Confirm reasoning=medium on the cross-line scenario (next x is on line >= 11).
local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { duet = { provider = 'openai_compatible' } }

local session = require 'minuet.duet.session'
local chat = require 'minuet.duet.chat'
local tools = require 'minuet.duet.tools'
local apply_patch = require 'minuet.duet.apply_patch'
local root = require('minuet').config

local content = {
    '#set text(lang: "es")', '', '', '= Taller 2.1: El método simplex revisado', '',
    '1. Dados los siguientes datos de optimización lineal', '$',
    '"max" z = 3x_1 + x_2', '"sujeto a"', 'cases(',
    '  x_1 - x_2 <= -1,', '  -x_1 - x_2 <= -2,', '  2x_1 + x_2 <= 4,', '  x_1, x_2 >= 0', ')', '$',
}
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
vim.api.nvim_buf_set_name(buf, dev .. '/tmp/taller.typ')
vim.bo[buf].filetype = 'typst'
vim.api.nvim_set_current_buf(buf)
session.clear(buf); session.rebase(buf)

local function rename_first_x_on_line8()
    local line = vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1]
    local c = line:find 'x_'
    local nl = line:sub(1, c - 1) .. 'y' .. line:sub(c + 1)
    vim.api.nvim_buf_set_lines(buf, 7, 8, false, { nl })
    vim.api.nvim_win_set_cursor(0, { 8, c })
    session.capture(buf, root.duet.session.history_context_lines)
end
rename_first_x_on_line8()
rename_first_x_on_line8()
vim.api.nvim_win_set_cursor(0, { 8, #vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1] })
print('line 8 -> ' .. vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1] .. '  (next x on line 11)\n')

local baseline = root.duet.session.system .. '\n\n' .. root.duet.session.capability_reminder
local improved = table.concat({
    "You are a next-edit-prediction engine inside the user's code editor.", '',
    'The user is partway through a REPETITIVE multi-site edit (for example renaming',
    'a symbol). You are given their recent edits (apply_patch dialect, oldest to',
    'newest) and the current file. CONTINUE that pattern: find the NEXT place that',
    'still needs the same change and emit it via the apply_patch tool.', '',
    'Rules:',
    '- Infer the transformation from the recent edits; apply it to the next not-yet-',
    '  edited occurrence. That occurrence is frequently NOT near the cursor and is',
    '  often on a different line; scan the WHOLE file.',
    '- Never revert or undo a recent edit. Never emit a no-op.',
    '- Exactly ONE small `*** Update File` hunk; context/`-` lines must match exactly.',
    '- The <|cursor|> marker is not real text; never include it in a patch.',
    '- If nothing remains to change, reply with the text `*** No Edit`.',
}, '\n')

local function build_turn(marker)
    local st = session.get_state(buf)
    local p = { 'Recent edits (oldest to newest):', '', table.concat(st.edits, '\n\n'), '' }
    local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if marker then
        local pos = vim.api.nvim_win_get_cursor(0)
        cur[pos[1]] = cur[pos[1]]:sub(1, pos[2]) .. '<|cursor|>' .. cur[pos[1]]:sub(pos[2] + 1)
        table.insert(p, 'Current file `tmp/taller.typ` (<|cursor|> marks the cursor; not real text):')
    else
        table.insert(p, 'Current file `tmp/taller.typ`:')
    end
    table.insert(p, ''); table.insert(p, table.concat(cur, '\n'))
    return table.concat(p, '\n')
end

local function ask(system, marker, effort)
    root.duet.provider_options.openai_compatible.optional.reasoning.effort = effort
    local done, result
    chat.request({ { role = 'system', content = system }, { role = 'user', content = build_turn(marker) } },
        tools.specs(), function(r) result = r; done = true end)
    vim.wait(40000, function() return done end, 50)
    if not result or result.error then return 'ERROR ' .. tostring(result and result.error) end
    local msg = result.message
    local call = msg.tool_calls and msg.tool_calls[1]
    if not (call and call['function']) then
        return (msg.content and msg.content:find '%*%*%* No Edit') and 'NO EDIT' or ('no-tool: ' .. tostring(msg.content))
    end
    if call['function'].name == 'read' then return 'read()' end
    local args = vim.json.decode(call['function'].arguments or '{}')
    local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local ok, nl = apply_patch.apply(cur, args.input)
    if not ok then return 'BAD PATCH: ' .. (args.input or ''):gsub('\n', ' | ') end
    for i = 1, math.max(#cur, #nl) do
        if cur[i] ~= nl[i] then
            local good = i >= 11 and nl[i]:find 'y_'
            local revert = nl[i]:find 'x_' and not cur[i]:find 'x_'
            return ('%s row %d: %q -> %q'):format(good and 'CORRECT' or (revert and 'REVERT' or 'other'), i, cur[i], nl[i])
        end
    end
    return 'NO-OP'
end

for _, c in ipairs {
    { 'baseline | medium | marker', baseline, true },
    { 'improved | medium | marker', improved, true },
    { 'improved | medium | NOmark', improved, false },
} do
    for s = 1, 3 do
        print(('%-30s #%d  %s'):format(c[1], s, ask(c[2], c[3], 'medium')))
    end
end
