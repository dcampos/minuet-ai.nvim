-- Minimal Neovim 0.12 config to drive the *local* dev copy of minuet-ai under
-- tmux (or --headless). The plugin under test is on disk, so we put it on the
-- runtimepath directly instead of fetching it.
--
-- vim.pack (nvim 0.12) would be used for *remote* deps, e.g.:
--   vim.pack.add({ 'https://github.com/nvim-lua/plenary.nvim' })
-- duet needs none, so we skip it.

local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
vim.opt.packpath:prepend(dev)
package.path = table.concat({
    dev .. '/lua/?.lua',
    dev .. '/lua/?/init.lua',
    package.path,
}, ';')

vim.o.swapfile = false
vim.o.shada = ''
vim.o.laststatus = 2

-- Expose the reusable applier for harness assertions.
_G.duet_apply_patch = require 'minuet.duet.apply_patch'

--- Apply a patch string to the current buffer and report the result on the
--- last line so `tmux capture-pane` can assert on it.
function _G.duet_demo_apply(patch)
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local ok, new_lines, err = _G.duet_apply_patch.apply(lines, patch)
    if not ok then
        vim.api.nvim_echo({ { 'DUET_APPLY_ERR: ' .. tostring(err) } }, false, {})
        return
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    vim.api.nvim_echo({ { 'DUET_APPLY_OK' } }, false, {})
end

--- Like `duet_demo_apply` but reads the patch from a file, to avoid quoting /
--- newline fragility when driving the command line over tmux.
function _G.duet_demo_apply_file(path)
    local patch = table.concat(vim.fn.readfile(path), '\n')
    _G.duet_demo_apply(patch)
end
