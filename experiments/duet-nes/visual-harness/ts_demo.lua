-- Harness demo: compare how a fixture's PROPOSED lines look as virtual text
-- under three foreground-coloring policies, stacked for a single screenshot:
--   1. flat        - the current renderer (all add-text one green group)
--   2. treesitter  - ts_highlight full-saturation capture colors
--   3. ts + dim    - ts_highlight with dimmed/blended capture groups
--
--   MINUET_FIXTURE=func_rewrite MINUET_INIT=ts_demo.lua nvim -u ts_demo.lua
-- (run via shot_cage.sh with MINUET_INIT set; see README).

local here = debug.getinfo(1, 'S').source:sub(2)
local harness_dir = vim.fn.fnamemodify(here, ':p:h')
local repo = os.getenv 'MINUET_REPO'
if not repo or repo == '' then
    repo = vim.fn.fnamemodify(harness_dir, ':h:h:h')
end
vim.opt.runtimepath:prepend(repo)
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

vim.o.termguicolors = true
vim.o.number = false
vim.o.signcolumn = 'no'
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.o.ruler = false
vim.o.showmode = false
vim.o.cmdheight = 0
vim.o.fillchars = 'eob: '

pcall(function()
    vim.pack.add { { src = 'https://github.com/folke/tokyonight.nvim' } }
end)
if not pcall(vim.cmd.colorscheme, 'tokyonight-night') then
    pcall(vim.cmd.colorscheme, 'habamax')
end

local ts = require 'minuet.duet.ts_highlight'
local fixtures = dofile(harness_dir .. '/fixtures.lua')
local fx = fixtures[os.getenv 'MINUET_FIXTURE' or '' ] or fixtures.func_rewrite
local lang = fx.filetype or 'lua'
local proposed = fx.proposed

local ns = vim.api.nvim_create_namespace 'minuet.ts_demo'
local buf = vim.api.nvim_get_current_buf()

local ADD_TINT = 0x294b38 -- subtle "added" green background

local labels = {
    '1. flat (current MinuetDuetAdd):',
    '2. treesitter (full):',
    '3. treesitter + dim (blend 40):',
    '4. treesitter + dim + add tint (chosen):',
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, labels)

-- 1. flat
local flat = {}
for _, line in ipairs(proposed) do
    flat[#flat + 1] = { { line, 'MinuetDuetAdd' } }
end
vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_lines = flat })

-- 2. treesitter full
vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, {
    virt_lines = ts.highlight_lines(proposed, lang, { base_hl = 'Normal' }),
})

-- 3. treesitter dimmed
vim.api.nvim_buf_set_extmark(buf, ns, 2, 0, {
    virt_lines = ts.highlight_lines(proposed, lang, { dim = true, blend = 40, base_hl = 'Normal' }),
})

-- 4. treesitter dimmed + "added" background tint (the chosen policy)
vim.api.nvim_buf_set_extmark(buf, ns, 3, 0, {
    virt_lines = ts.highlight_lines(proposed, lang, { dim = true, blend = 35, bg = ADD_TINT, base_hl = 'Normal' }),
})

vim.g.minuet_harness_ready = true
