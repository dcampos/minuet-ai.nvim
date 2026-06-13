-- Headless reproduction of the user's Typst x->y NES session.
-- For each x->y rename (document order) we capture the edit, then ask the live
-- duet model for the next-edit prediction and log request + response. Goal:
-- see whether the model ever proposes the *next* x on a *different* line.
--
-- Run: OPENROUTER_API_KEY=... nvim --headless -u NONE -i NONE -n \
--        -c "luafile tmp/nes_repro.lua" -c "qa!"

local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')

require('minuet').setup { duet = { provider = 'openai_compatible' } }

local session = require 'minuet.duet.session'
local chat = require 'minuet.duet.chat'
local tools = require 'minuet.duet.tools'
local apply_patch = require 'minuet.duet.apply_patch'

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

local ts = os.date '%Y-%m-%d_%H-%M-%S'
local logpath = dev .. '/tmp/nes_repro_' .. ts .. '.jsonl'
local logf = assert(io.open(logpath, 'w'))
local function log(obj)
    obj.t_ms = vim.uv.now()
    logf:write(vim.json.encode(obj) .. '\n')
    logf:flush()
end

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
vim.api.nvim_buf_set_name(bufnr, dev .. '/tmp/taller.typ')
vim.bo[bufnr].filetype = 'typst'
vim.api.nvim_set_current_buf(bufnr)

session.clear(bufnr)
session.rebase(bufnr)

local scfg = require('minuet').config.duet.session

-- Find the next variable `x` (an 'x' immediately followed by '_') in document
-- order, returning 1-based row and 0-based byte col.
local function next_x()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for row = 1, #lines do
        local col = lines[row]:find 'x_'
        if col then
            return row, col - 1 -- 0-based byte col of the 'x'
        end
    end
    return nil
end

local function build_messages()
    local system = scfg.system .. '\n\n' .. scfg.capability_reminder
    local user = session.build_user_turn(bufnr, {
        cursor_marker = scfg.cursor_marker,
        ctx_lines = scfg.history_context_lines,
    })
    return {
        { role = 'system', content = system },
        { role = 'user', content = user },
    }
end

-- One synchronous model round trip.
local function predict_once(step)
    local messages = build_messages()
    local done, result = false, nil
    chat.request(messages, tools.specs(), function(r)
        result = r
        done = true
    end)
    vim.wait(30000, function()
        return done
    end, 50)
    if not result then
        return { error = 'timeout' }
    end
    if result.error then
        return { error = result.error }
    end
    local msg = result.message
    local call = msg.tool_calls and msg.tool_calls[1]
    local out = { reasoning = msg.reasoning, content = msg.content }
    if call and call['function'] then
        out.tool = call['function'].name
        local ok, args = pcall(vim.json.decode, call['function'].arguments or '{}')
        out.args = ok and args or call['function'].arguments
        if out.tool == 'apply_patch' and type(out.args) == 'table' then
            out.patch = out.args.input
            -- Determine which buffer row the proposed patch actually changes.
            local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local applied, new_lines = apply_patch.apply(cur, out.patch)
            out.applied = applied and true or false
            if applied then
                for i = 1, math.max(#cur, #new_lines) do
                    if cur[i] ~= new_lines[i] then
                        out.changed_row = i
                        out.changed_old = cur[i]
                        out.changed_new = new_lines[i]
                        break
                    end
                end
            end
        end
    end
    log { step = step, kind = 'request', user = messages[2].content }
    log { step = step, kind = 'response', out = out }
    return out
end

print('LOG: ' .. logpath)
print('====================================================================')

local step = 0
while true do
    local row, col = next_x()
    if not row then
        break
    end
    step = step + 1
    if step > 10 then
        break
    end

    -- Perform the x->y rename at (row,col) and place the cursor just after it.
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
    local newline = line:sub(1, col) .. 'y' .. line:sub(col + 2)
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { newline })
    vim.api.nvim_win_set_cursor(0, { row, col + 1 })
    session.capture(bufnr, scfg.history_context_lines)

    local out = predict_once(step)

    local where
    if out.error then
        where = 'ERROR: ' .. tostring(out.error)
    elseif out.tool == 'read' then
        where = 'read() ' .. vim.inspect(out.args):gsub('%s+', ' ')
    elseif out.tool == 'apply_patch' then
        if out.applied then
            local rel = out.changed_row == row and 'SAME line'
                or (out.changed_row and ('line ' .. out.changed_row .. ' (cursor on ' .. row .. ')') or '??')
            where = ('apply_patch -> changes row %s [%s]  %q -> %q'):format(
                tostring(out.changed_row),
                rel,
                tostring(out.changed_old),
                tostring(out.changed_new)
            )
        else
            where = 'apply_patch BUT did not apply to current buffer; patch=\n' .. tostring(out.patch)
        end
    elseif out.content and out.content:find '%*%*%* No Edit' then
        where = 'NO EDIT'
    else
        where = 'no tool; content=' .. tostring(out.content)
    end

    print(('step %2d: renamed x->y at row %d col %d ; cursor row %d | model: %s'):format(step, row, col, row, where))
end

print('====================================================================')
print('done. full request/response in ' .. logpath)
logf:close()
