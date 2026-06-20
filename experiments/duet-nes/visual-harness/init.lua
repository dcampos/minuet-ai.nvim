-- Visual-harness nvim driver for the duet NES preview renderer.
--
-- Renders one before/after fixture as duet preview extmarks, with no model or
-- network call, so a screenshot tool (vhs / cage+foot+grim) can capture the
-- real highlight output. Pick the fixture with $MINUET_FIXTURE.
--
--   nvim -u experiments/duet-nes/visual-harness/init.lua
--
-- Env:
--   MINUET_REPO     repo root (defaults to this file's repo)
--   MINUET_FIXTURE  fixture name from fixtures.lua (default: word_swap)

local here = debug.getinfo(1, 'S').source:sub(2)
local harness_dir = vim.fn.fnamemodify(here, ':p:h')
local repo = os.getenv 'MINUET_REPO'
if not repo or repo == '' then
    repo = vim.fn.fnamemodify(harness_dir, ':h:h:h')
end

vim.opt.runtimepath:prepend(repo)
package.path = table.concat({
    repo .. '/lua/?.lua',
    repo .. '/lua/?/init.lua',
    package.path,
}, ';')

-- A clean, screenshot-friendly chrome.
vim.o.termguicolors = true
vim.o.number = false
vim.o.relativenumber = false
vim.o.signcolumn = 'no'
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.o.ruler = false
vim.o.more = false
vim.o.showmode = false
vim.o.fillchars = 'eob: '
vim.o.cmdheight = 0

-- Colors matter: load the user's colorscheme via the built-in 0.12 plugin
-- manager. Non-transparent so screenshots have a solid background.
pcall(function()
    vim.pack.add { { src = 'https://github.com/folke/tokyonight.nvim' } }
end)
if not pcall(vim.cmd.colorscheme, 'tokyonight-night') then
    pcall(vim.cmd.colorscheme, 'habamax')
end

local fixtures = dofile(harness_dir .. '/fixtures.lua')
local name = os.getenv 'MINUET_FIXTURE'
if not name or name == '' then
    name = 'word_swap'
end
local fx = fixtures[name]
if not fx then
    error('unknown fixture: ' .. name)
end

-- Model-free minuet config, mirroring how tests stand up config.duet.
local cfg = vim.deepcopy(require 'minuet.config')
local preview_overrides = vim.tbl_extend('force', { cursor = '|' }, fx.opts or {})
-- MINUET_TS=1 exercises the integrated treesitter foreground coloring path.
if os.getenv 'MINUET_TS' == '1' then
    preview_overrides.ts_highlight = true
end
package.loaded['minuet'] = {
    config = vim.tbl_deep_extend('force', cfg, {
        notify = false,
        duet = { preview = preview_overrides },
    }),
}

local preview = require 'minuet.duet.preview'

local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].buftype = ''
if fx.filetype then
    vim.bo[buf].filetype = fx.filetype
    -- Base-buffer treesitter highlighting (the "before" code under the diff).
    pcall(vim.treesitter.start, buf, fx.filetype)
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, fx.original)

local state = {
    range = { start_row = 0, end_row = #fx.original },
    original_lines = fx.original,
    proposed_lines = fx.proposed,
    proposed_cursor = fx.cursor,
    preview_focus = fx.focus,
}

preview.render(buf, state)

-- Accept the currently active chunk at the preview level, mirroring the real
-- finish_accept partial path: apply the chunk, fold it into original_lines, drop
-- the active selection, and re-render (remaining changes recollapse to a marker).
local function accept_active()
    preview.rebuild_chunks(state)
    local chunk = select(1, preview.current_chunk(state))
    if not chunk then
        return
    end
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local after = preview.apply_chunk(before, chunk)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, after)
    state.original_lines = after
    state.preview_active = nil
    preview.render(buf, state)
end

-- MINUET_STEPS replays the Tab workflow one action per step so each value
-- screenshots a distinct frame: odd step = navigate (reveal the hunk), even
-- step = accept one change. Falls back to fx.select for the single-shot case.
local steps = tonumber(os.getenv 'MINUET_STEPS' or '') or 0
if steps > 0 then
    for n = 1, steps do
        if n % 2 == 1 then
            pcall(preview.select_next_chunk, buf, state)
        else
            accept_active()
        end
    end
elseif fx.select then
    pcall(preview.select_next_chunk, buf, state)
end

-- Signal for the screenshot tool / smoke checks.
vim.g.minuet_harness_ready = true
vim.g.minuet_harness_fixture = name
