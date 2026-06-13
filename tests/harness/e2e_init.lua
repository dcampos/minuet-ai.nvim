-- Full-plugin init for the live duet NES end-to-end test (tmux).
local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({
    dev .. '/lua/?.lua',
    dev .. '/lua/?/init.lua',
    package.path,
}, ';')

vim.o.swapfile = false
vim.o.shada = ''
vim.o.laststatus = 2

require('minuet').setup {
    duet = {
        provider = 'openai_compatible', -- gpt-oss-120b via OpenRouter (config.lua defaults)
    },
}

-- normal-mode keymaps mirroring completion (placeholders; user rebinds)
local map = vim.keymap.set
map('n', '<C-f>', '<cmd>Minuet duet predict<cr>', { desc = 'duet predict' })
map('n', '<C-n>', '<cmd>Minuet duet cycle<cr>', { desc = 'duet cycle' })
map('n', '<C-o>', '<cmd>Minuet duet apply<cr>', { desc = 'duet apply' })
map('n', '<C-a>', '<cmd>Minuet duet dismiss<cr>', { desc = 'duet dismiss' })
map('n', '<C-e>', '<cmd>Minuet duet toggle<cr>', { desc = 'duet toggle' })

function _G.duet_vis()
    vim.api.nvim_echo({ { 'DUET_VIS=' .. tostring(require('minuet.duet').action.is_visible()) } }, false, {})
end
