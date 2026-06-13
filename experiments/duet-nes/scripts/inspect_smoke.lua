local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { duet = { provider = 'openai_compatible' } }

local inspect = require 'minuet.duet.inspect'

-- A) render/toggle mechanics on a synthetic transcript -----------------------
local fake = {
    time = '23:59:59', path = 'foo.lua', mode = 'manual', model = 'm', effort = 'medium',
    system = 'SYS line1\nSYS line2', user = 'cursor note\n\nCurrent file `foo.lua`:\nlocal x = 1',
    outcome = 'preview shown',
    turns = {
        { kind = 'read', args = { start_line = 1, end_line = 9 }, reasoning = 'need to check' },
        { kind = 'apply_patch', applied = true, reasoning = 'rename x->y next', patch = '*** Begin Patch\n*** Update File: foo.lua\n@@\n-local x = 1\n+local y = 1\n*** End Patch' },
    },
}
inspect.toggle(fake)
assert(inspect.win and vim.api.nvim_win_is_valid(inspect.win), 'window should be open')
local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(inspect.win), 0, -1, false)
local text = table.concat(lines, '\n')
for _, needle in ipairs { '# Minuet duet', 'System prompt', 'Inputs %(user turn%)', 'Model turns %(2%)', 'read {end_line=9, start_line=1}', 'applied', 'rename x%->y next' } do
    assert(text:find(needle), 'missing in float: ' .. needle)
end
inspect.toggle(fake) -- toggle closes
assert(not (inspect.win and vim.api.nvim_win_is_valid(inspect.win)), 'window should be closed')
print 'A) float render + toggle: OK'

-- B) a real prediction fills M.last with reasoning/patch ----------------------
local duet = require 'minuet.duet'
duet.setup()
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local a = old_name', 'local b = old_name' })
vim.api.nvim_buf_set_name(buf, dev .. '/tmp/smoke.lua')
vim.bo[buf].filetype = 'lua'
vim.api.nvim_set_current_buf(buf)
require('minuet.duet.session').clear(buf)
require('minuet.duet.session').rebase(buf)
-- one edit: rename first old_name -> new_name, so the model should propose the next
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'local a = new_name' })
vim.api.nvim_win_set_cursor(0, { 1, 18 })
require('minuet.duet.session').capture(buf, 8)

duet.action.predict()
vim.wait(40000, function()
    return duet.last and duet.last.outcome ~= 'pending'
end, 100)

print('B) outcome   = ' .. tostring(duet.last and duet.last.outcome))
print('B) #turns    = ' .. tostring(duet.last and #duet.last.turns))
local has_reason, has_patch = false, false
for _, t in ipairs(duet.last and duet.last.turns or {}) do
    if t.reasoning then has_reason = true end
    if t.patch then has_patch = true end
end
print('B) any reasoning captured = ' .. tostring(has_reason))
print('B) any patch captured     = ' .. tostring(has_patch))
print('B) user-turn has cursor note = ' .. tostring((duet.last.user or ''):find('Editor cursor:') ~= nil))
print('B) user-turn clean of marker = ' .. tostring((duet.last.user or ''):find('<|cursor|>', 1, true) == nil))
