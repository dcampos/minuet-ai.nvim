local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { virtualtext = { auto_trigger_ft = { 'typst' } } }

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = 'typst' -- fires the FileType autocmd that seeds vt mode

local duet = require('minuet.duet')
local vt = require('minuet.virtualtext')
local function state()
  return ('duet.auto_enabled=%-5s  vt.mode=%s'):format(
    tostring(duet.auto_enabled), tostring(vim.b.minuet_virtual_text_auto_trigger_mode))
end

print('initial : ' .. state())
-- exactly what the <S-Tab> keymap does:
for i = 1, 3 do
  duet.action.toggle()
  vt.action.toggle_auto_trigger()
  print(('S-Tab #%d: %s'):format(i, state()))
end
