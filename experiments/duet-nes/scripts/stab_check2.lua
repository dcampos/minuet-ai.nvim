local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { virtualtext = { auto_trigger_ft = { 'typst' } } }
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = 'typst'
local duet = require('minuet.duet')
local vt = require('minuet.virtualtext').action
local function state()
  return ('duet=%-5s  vt=%s'):format(tostring(duet.auto_enabled), tostring(vim.b.minuet_virtual_text_auto_trigger_mode))
end
print('initial : ' .. state())
for i = 1, 3 do
  -- new synced keymap body:
  duet.action.toggle()
  if duet.auto_enabled then vt.enable_auto_trigger() else vt.disable_auto_trigger() end
  print(('S-Tab #%d: %s'):format(i, state()))
end
