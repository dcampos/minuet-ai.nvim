-- Focused experiment: the user's exact expectation. After renaming BOTH x's on
-- line 8 ("max" z = 3x_1 + x_2 -> 3y_1 + y_2), the cursor sits at end of line 8
-- and the next un-renamed x is on a DIFFERENT line (the cases block). Does the
-- model propose that cross-line x->y? We sweep prompt x effort x cursor-marker.

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
    '#set text(lang: "es")',
    '',
    '',
    '= Taller 2.1: El método simplex revisado',
    '',
    '1. Dados los siguientes datos de optimización lineal',
    '$',
    '"max" z = 3x_1 + x_2',
    '"sujeto a"',
    'cases(',
    '  x_1 - x_2 <= -1,',
    '  -x_1 - x_2 <= -2,',
    '  2x_1 + x_2 <= 4,',
    '  x_1, x_2 >= 0',
    ')',
    '$',
}

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
vim.api.nvim_buf_set_name(bufnr, dev .. '/tmp/taller.typ')
vim.bo[bufnr].filetype = 'typst'
vim.api.nvim_set_current_buf(bufnr)
session.clear(bufnr)
session.rebase(bufnr)

-- Rename the two x's on line 8, each captured as its own edit.
local function rename_on_line8(col0)
    local line = vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)[1]
    local nl = line:sub(1, col0) .. 'y' .. line:sub(col0 + 2)
    vim.api.nvim_buf_set_lines(bufnr, 7, 8, false, { nl })
    vim.api.nvim_win_set_cursor(0, { 8, col0 + 1 })
    session.capture(bufnr, root.duet.session.history_context_lines)
end
rename_on_line8(select(1, ({ vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)[1]:find 'x_' })[1] - 1)) -- first x
rename_on_line8(({ vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)[1]:find 'x_' })[1] - 1) -- second x
-- Cursor at END of line 8 (user just finished that line).
vim.api.nvim_win_set_cursor(0, { 8, #vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)[1] })

print('Line 8 is now: ' .. vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)[1])
print('Next un-renamed x is on line 11. Correct prediction = change an x->y on line >= 11.\n')

local baseline_system = root.duet.session.system .. '\n\n' .. root.duet.session.capability_reminder

local improved_system = table.concat({
    'You are a next-edit-prediction engine inside the user\'s code editor.',
    '',
    'The user is partway through a REPETITIVE multi-site edit (for example renaming',
    'a symbol everywhere it appears). You are given their recent edits (apply_patch',
    'dialect, oldest to newest) and the current file. Your job is to CONTINUE that',
    'pattern: find the NEXT place in the file that still needs the same change and',
    'emit it via the apply_patch tool.',
    '',
    'Rules:',
    '- Infer the transformation from the recent edits and apply it to the next',
    '  not-yet-edited occurrence. The next occurrence is frequently NOT near the',
    '  cursor and is often on a different line; scan the WHOLE file for it.',
    '- Never revert or undo a recent edit. Never emit a no-op patch.',
    '- Emit exactly ONE small `*** Update File` hunk (no Add/Delete/Move). Context',
    '  and removed (`-`) lines must match the current buffer EXACTLY.',
    '- The <|cursor|> marker (if present) is not real text; never include it in a',
    '  patch and do not treat fixing it as the edit.',
    '- If every occurrence is already changed and nothing remains, reply with the',
    '  text `*** No Edit` and do not call a tool.',
}, '\n')

-- Build a user turn, optionally without the cursor marker.
local function build_turn(with_marker)
    local state = session.get_state(bufnr)
    local parts = {}
    local all = {}
    vim.list_extend(all, state.seed)
    vim.list_extend(all, state.edits)
    if #all > 0 then
        table.insert(parts, 'Recent edits (oldest to newest):')
        table.insert(parts, '')
        table.insert(parts, table.concat(all, '\n\n'))
        table.insert(parts, '')
    end
    local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if with_marker then
        local pos = vim.api.nvim_win_get_cursor(0)
        local row, col = pos[1], pos[2]
        cur[row] = cur[row]:sub(1, col) .. '<|cursor|>' .. cur[row]:sub(col + 1)
        table.insert(parts, 'Current file `tmp/taller.typ` (<|cursor|> marks the cursor; it is not real text):')
    else
        table.insert(parts, 'Current file `tmp/taller.typ`:')
    end
    table.insert(parts, '')
    table.insert(parts, table.concat(cur, '\n'))
    return table.concat(parts, '\n')
end

local function ask(system, with_marker, effort)
    root.duet.provider_options.openai_compatible.optional.reasoning.effort = effort
    local messages = {
        { role = 'system', content = system },
        { role = 'user', content = build_turn(with_marker) },
    }
    local done, result = false, nil
    chat.request(messages, tools.specs(), function(r)
        result = r
        done = true
    end)
    vim.wait(40000, function()
        return done
    end, 50)
    if not result or result.error then
        return { error = result and result.error or 'timeout' }
    end
    local msg = result.message
    local call = msg.tool_calls and msg.tool_calls[1]
    local out = { content = msg.content }
    if call and call['function'] then
        out.tool = call['function'].name
        local ok, args = pcall(vim.json.decode, call['function'].arguments or '{}')
        out.args = ok and args or {}
        if out.tool == 'apply_patch' then
            out.patch = out.args.input
            local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local applied, new_lines = apply_patch.apply(cur, out.patch)
            out.applied = applied and true or false
            if applied then
                for i = 1, math.max(#cur, #new_lines) do
                    if cur[i] ~= new_lines[i] then
                        out.row, out.old, out.new = i, cur[i], new_lines[i]
                        break
                    end
                end
            end
        end
    end
    return out
end

local function classify(out)
    if out.error then
        return 'ERROR ' .. tostring(out.error)
    end
    if out.tool == 'read' then
        return 'read()'
    end
    if out.tool == 'apply_patch' then
        if not out.applied then
            return 'BAD PATCH (did not apply): ' .. (out.patch or ''):gsub('\n', ' | ')
        end
        local good = out.row and out.row >= 11 and out.new and out.new:find 'y_'
        local revert = out.new and out.old and (out.new:gsub('%s', '') ~= out.old:gsub('%s', '')) and out.new:find 'x_' and not out.old:find 'x_'
        local tag = good and 'CORRECT (cross-line)' or (revert and 'REVERT' or 'other')
        return ('%s  row %s: %q -> %q'):format(tag, tostring(out.row), tostring(out.old), tostring(out.new))
    end
    if out.content and out.content:find '%*%*%* No Edit' then
        return 'NO EDIT'
    end
    return 'no tool; content=' .. tostring(out.content)
end

local configs = {
    { name = 'baseline prompt | low  | marker', sys = baseline_system, marker = true, effort = 'low' },
    { name = 'baseline prompt | high | marker', sys = baseline_system, marker = true, effort = 'high' },
    { name = 'improved prompt | high | marker', sys = improved_system, marker = true, effort = 'high' },
    { name = 'improved prompt | high | NOmark', sys = improved_system, marker = false, effort = 'high' },
    { name = 'improved prompt | low  | NOmark', sys = improved_system, marker = false, effort = 'low' },
}

for _, c in ipairs(configs) do
    -- two samples each (model is stochastic)
    for s = 1, 2 do
        local out = ask(c.sys, c.marker, c.effort)
        print(('%-34s #%d  %s'):format(c.name, s, classify(out)))
    end
end
