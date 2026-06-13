-- Drive several predictions with different dispositions and verify M.history +
-- result tracking, then render the session float.
local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { duet = { provider = 'openai_compatible' } }

local duet = require 'minuet.duet'
local session = require 'minuet.duet.session'
duet.setup()

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local a = old_name', 'local b = old_name', 'local c = old_name' })
vim.api.nvim_buf_set_name(buf, dev .. '/tmp/sess.lua')
vim.bo[buf].filetype = 'lua'
vim.api.nvim_set_current_buf(buf)
session.clear(buf)
session.rebase(buf)

local function wait_settled()
    vim.wait(40000, function()
        return duet.last and duet.last.outcome ~= 'pending'
    end, 100)
end

-- edit 1 -> predict -> ACCEPT
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'local a = new_name' })
vim.api.nvim_win_set_cursor(0, { 1, 18 })
session.capture(buf, 8)
duet.action.predict()
wait_settled()
if duet.action.is_visible() then duet.action.apply() end

-- predict again -> DISMISS
duet.action.predict()
wait_settled()
if duet.action.is_visible() then duet.action.dismiss() end

-- predict again -> leave it (ignored by a new predict)
duet.action.predict()
wait_settled()
duet.action.predict() -- supersede the previous -> should mark it ignored
wait_settled()

print('history length = ' .. #duet.history)
for i, rec in ipairs(duet.history) do
    local has_reason = false
    for _, t in ipairs(rec.turns) do
        if t.reasoning then has_reason = true end
    end
    print(('  #%d  outcome=%-16s result=%-18s turns=%d reasoning=%s'):format(
        i, tostring(rec.outcome), tostring(rec.result), #rec.turns, tostring(has_reason)))
end

-- render the float and confirm it shows multiple predictions + results
local inspect = require 'minuet.duet.inspect'
inspect.toggle(duet.history)
local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(inspect.win), 0, -1, false)
local text = table.concat(lines, '\n')
print('float shows session header = ' .. tostring(text:find('session %(%d') ~= nil))
print('float shows result line    = ' .. tostring(text:find('result:') ~= nil))
local _, npred = text:gsub('\n## #%d', '')
print('float prediction sections  = ' .. npred)
inspect.close()
