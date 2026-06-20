-- Standalone, model-free demo of minuet's duet NES (next-edit-suggestion).
--
--   nvim -u experiments/duet-nes/demo/init.lua
--
-- It loads this repo, stands up the real duet engine, and replaces ONLY the
-- network layer (`minuet.duet.chat.request`) with a deterministic mock that
-- serves scripted before/after edits from `scenarios.lua`. Everything you see --
-- the inline word diffs, the blue collapsed-hunk squares, the revealed
-- virtual-line blocks, the treesitter coloring, and the per-change <Tab> flow --
-- is the real preview renderer and the real accept/navigate state machine. No
-- API key, no request leaves the machine. Neovim state is isolated under
-- experiments/duet-nes/demo/.state, even when launched directly.
--
-- Controls (normal mode, one buffer containing every example):
--   Move normally  choose an example by putting the cursor anywhere in it
--   <CR>           next step of the current example (demo-only)
--   <Tab>          jump to / accept the shown change, or request the next one
--                  (same shape as the user's real NES keybinding)
--   <BS>           restart the example under the cursor
--   :DemoGoto N    jump cursor to example N
--   :DemoList      list examples
--
-- Env (used by the screenshot harness; ignore for interactive use):
--   MINUET_REPO          repo root override
--   MINUET_DEMO_SCENARIO 1-based example to place the cursor in on startup
--   MINUET_DEMO_KEYS     replay string, chars in {n=<CR>, t=<Tab>, b=<BS>}

local here = debug.getinfo(1, 'S').source:sub(2)
local demo_dir = vim.fn.fnamemodify(here, ':p:h')
local repo = os.getenv 'MINUET_REPO'
if not repo or repo == '' then
    repo = vim.fn.fnamemodify(demo_dir, ':h:h:h')
end

local state_root = demo_dir .. '/.state'
local xdg_dirs = {
    XDG_DATA_HOME = state_root .. '/data',
    XDG_STATE_HOME = state_root .. '/state',
    XDG_CACHE_HOME = state_root .. '/cache',
    XDG_CONFIG_HOME = state_root .. '/config',
}
for name, path in pairs(xdg_dirs) do
    vim.env[name] = path
    vim.fn.mkdir(path, 'p')
end

vim.opt.runtimepath:prepend(repo)
package.path = table.concat({
    repo .. '/lua/?.lua',
    repo .. '/lua/?/init.lua',
    package.path,
}, ';')

-- Readable chrome, but keep enough editor furniture that it feels like a real session.
vim.o.termguicolors = true
vim.o.number = true
vim.o.relativenumber = false
vim.o.signcolumn = 'no'
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.o.ruler = false
vim.o.showmode = false
vim.o.swapfile = false
vim.o.fillchars = 'eob: '
vim.o.scrolloff = 4
vim.o.cmdheight = 2
vim.opt.shortmess:append 'I'

-- Colorscheme via the built-in 0.12 package manager (network only on first run).
pcall(function()
    vim.pack.add { { src = 'https://github.com/folke/tokyonight.nvim' } }
end)
if not pcall(vim.cmd.colorscheme, 'tokyonight-night') then
    pcall(vim.cmd.colorscheme, 'habamax')
end

-- Real engine, model-free config: direct-region (inception_edit) shape so the
-- mock can return a replacement for just the example under the cursor.
require('minuet').setup {
    notify = 'error',
    duet = {
        provider = 'inception_edit',
        preview = { ts_highlight = true },
        session = {
            auto_trigger = false,
            prefetch_after_preview = false,
        },
    },
}

local duet = require 'minuet.duet'
local scenarios = dofile(demo_dir .. '/scenarios.lua')

local Demo = {
    scenarios = scenarios,
    progress = {}, -- accepted step per example, derived again from the buffer when possible
    active = nil, -- example that owns the currently visible preview
    pending = nil, -- example requested; consumed by the mocked transport
    buf = nil,
    win = nil,
}

local function narrate(msg)
    vim.api.nvim_echo({ { msg, 'MoreMsg' } }, false, {})
end

local function render_demo_lines()
    local lines = {
        '-- duet NES demo',
        '-- All examples live in this buffer. Move normally; cursor position picks the active example.',
        '-- <Tab> shows, jumps, or accepts. <CR> applies + asks for the next step.',
        '-- <BS> restarts the current example. :DemoGoto N jumps to one.',
        '',
    }

    for i, sc in ipairs(Demo.scenarios) do
        if i > 1 then
            lines[#lines + 1] = ''
        end
        lines[#lines + 1] = ('-- Example %d/%d: %s'):format(i, #Demo.scenarios, sc.title)
        lines[#lines + 1] = '-- ' .. sc.blurb
        vim.list_extend(lines, vim.deepcopy(sc.lines))
        lines[#lines + 1] = ('-- /Example %d'):format(i)
    end

    return lines
end

local function scan_sections()
    local lines = vim.api.nvim_buf_get_lines(Demo.buf, 0, -1, false)
    local sections = {}
    for row, line in ipairs(lines) do
        local open = line:match '^%-%- Example (%d+)/%d+:'
        if open then
            local index = tonumber(open)
            sections[index] = {
                index = index,
                header = row,
                code_start = row + 2,
                end_line = row,
                code_end = row + 1,
            }
        end

        local close = line:match '^%-%- /Example (%d+)'
        if close then
            local index = tonumber(close)
            if sections[index] then
                sections[index].code_end = row - 1
                sections[index].end_line = row
            end
        end
    end
    return sections
end

local function section_for_index(index)
    return scan_sections()[index]
end

local function scenario_at_cursor()
    if not (Demo.win and vim.api.nvim_win_is_valid(Demo.win)) then
        return nil
    end
    local row = vim.api.nvim_win_get_cursor(Demo.win)[1]
    for index, section in pairs(scan_sections()) do
        if row >= section.header and row <= section.end_line then
            return index, section
        end
    end
    return nil
end

local function code_lines(section)
    if not section or section.code_end < section.code_start then
        return {}
    end
    return vim.api.nvim_buf_get_lines(Demo.buf, section.code_start - 1, section.code_end, false)
end

local function replace_code(section, lines)
    vim.api.nvim_buf_set_lines(Demo.buf, section.code_start - 1, section.code_end, false, lines)
end

local function sync_progress(index)
    local sc = Demo.scenarios[index]
    local section = section_for_index(index)
    if not sc or not section then
        return 0
    end

    local current = code_lines(section)
    if vim.deep_equal(current, sc.lines) then
        Demo.progress[index] = 0
        return 0
    end

    for step = #sc.steps, 1, -1 do
        if vim.deep_equal(current, sc.steps[step].after) then
            Demo.progress[index] = step
            return step
        end
    end

    return Demo.progress[index] or 0
end

local function ensure_cursor_in_code(index)
    local section = section_for_index(index)
    local sc = Demo.scenarios[index]
    if not section or not sc then
        return
    end

    local row = vim.api.nvim_win_get_cursor(Demo.win)[1]
    if row >= section.code_start and row <= section.code_end then
        return
    end

    local cur = sc.cursor or { 1, 0 }
    local target = math.min(section.code_end, section.code_start + cur[1] - 1)
    pcall(vim.api.nvim_win_set_cursor, Demo.win, { target, cur[2] })
end

local function jump_to_scenario(index)
    index = ((index - 1) % #Demo.scenarios + #Demo.scenarios) % #Demo.scenarios + 1
    local section = section_for_index(index)
    local sc = Demo.scenarios[index]
    if not section or not sc then
        return
    end
    local cur = sc.cursor or { 1, 0 }
    local target = math.min(section.code_end, section.code_start + cur[1] - 1)
    pcall(vim.api.nvim_win_set_cursor, Demo.win, { target, cur[2] })
    Demo.active = index
    narrate(('[%d/%d] %s  -  %s'):format(index, #Demo.scenarios, sc.title, sc.blurb))
end

local function current_index()
    local index = scenario_at_cursor()
    return index or Demo.active
end

local function refresh_winbar()
    if not (Demo.win and vim.api.nvim_win_is_valid(Demo.win)) then
        return
    end

    local index = scenario_at_cursor()
    local label = 'move cursor into an example'
    if index and Demo.scenarios[index] then
        label = ('[%d/%d] %s'):format(index, #Demo.scenarios, Demo.scenarios[index].title)
    end

    local width = vim.api.nvim_win_get_width(Demo.win)
    local prefix = ' duet NES '
    local controls = ''
    if width >= 96 then
        controls = ' | <Tab> show/accept  <CR> next step  <BS> restart  :DemoGoto N'
    elseif width >= 76 then
        controls = ' | <Tab> show/accept  <CR> next  <BS> restart'
    elseif width >= 58 then
        controls = ' | <Tab> show/accept  <CR> next'
    end

    local max_label = width - #prefix - #controls - 1
    if max_label > 3 and #label > max_label then
        label = label:sub(1, max_label - 3) .. '...'
    elseif max_label <= 3 then
        label = ''
    end

    vim.api.nvim_set_option_value('winbar', prefix .. label .. controls, { win = Demo.win })
end

-- The deterministic transport. The real duet engine still builds a request, but
-- this mock responds with the next scripted replacement for the example under
-- the cursor. The returned direct_edit region is only that example's code, so the
-- other examples remain visible and untouched in the shared buffer.
local function install_mock()
    local chat = require 'minuet.duet.chat'
    chat.request = function(_messages, _tools, callback, _ctx)
        local index = Demo.pending or current_index()
        Demo.pending = nil

        local sc = index and Demo.scenarios[index]
        local section = index and section_for_index(index)
        if not sc or not section then
            narrate 'Put the cursor inside an example first.'
            callback { message = { role = 'assistant', content = require('minuet').config.duet.session.no_edit_token } }
            return
        end

        local progress = sync_progress(index)
        local step = progress + 1
        if step > #sc.steps then
            callback { message = { role = 'assistant', content = require('minuet').config.duet.session.no_edit_token } }
            return
        end

        Demo.active = index
        narrate(('[%d/%d] step %d/%d  -  %s'):format(index, #Demo.scenarios, step, #sc.steps, sc.steps[step].note))
        refresh_winbar()
        callback {
            direct_edit = {
                region = {
                    path = 'duet-nes-demo',
                    start_row = section.code_start,
                    end_row = section.code_end,
                },
                replacement = vim.deepcopy(sc.steps[step].after),
                content = '',
            },
        }
    end
end

local function request_next(index)
    index = index or current_index()
    local sc = index and Demo.scenarios[index]
    if not sc then
        narrate 'Put the cursor inside an example first.'
        return
    end

    local progress = sync_progress(index)
    if progress >= #sc.steps then
        vim.api.nvim_echo({
            { ('End of example %d: %s.  '):format(index, sc.title), 'WarningMsg' },
            { '<BS> restart this example, or move to another example.', 'Comment' },
        }, false, {})
        return
    end

    Demo.active = index
    Demo.pending = index
    ensure_cursor_in_code(index)
    duet.action.predict() -- -> chat.request mock -> preview
end

-- <CR>: accept any visible suggestion as a whole, then request the next scripted
-- edit for the same example.
local function next_step()
    local index = Demo.active or current_index()
    if duet.action.is_visible() then
        duet.action.apply()
        sync_progress(index)
    end
    request_next(index)
end

-- <Tab>: same flow as the user's real binding when a suggestion is visible. The
-- empty-screen branch asks the deterministic mock for the current example's next
-- step instead of calling cycle() against a model.
local function tab()
    if duet.action.is_visible() then
        local index = Demo.active
        duet.action.accept_or_next()
        vim.schedule(function()
            if index then
                sync_progress(index)
            end
            refresh_winbar()
        end)
    else
        request_next()
    end
end

local function restart_current()
    local index = current_index()
    local sc = index and Demo.scenarios[index]
    local section = index and section_for_index(index)
    if not sc or not section then
        narrate 'Put the cursor inside an example first.'
        return
    end

    pcall(duet.action.dismiss)
    replace_code(section, vim.deepcopy(sc.lines))
    Demo.progress[index] = 0
    Demo.active = index
    jump_to_scenario(index)
    narrate(('Restarted example %d: %s'):format(index, sc.title))
end

local function setup_buffer()
    Demo.buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(Demo.buf, 'duet-nes-demo')
    vim.bo[Demo.buf].buftype = ''
    vim.bo[Demo.buf].filetype = 'lua'
    Demo.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(Demo.win, Demo.buf)
    vim.api.nvim_buf_set_lines(Demo.buf, 0, -1, false, render_demo_lines())
    pcall(vim.treesitter.start, Demo.buf, 'lua')

    local function map(lhs, fn, desc)
        vim.keymap.set('n', lhs, fn, { buffer = Demo.buf, silent = true, desc = desc })
    end
    map('<CR>', next_step, 'duet demo: next step for current example')
    map('<Tab>', tab, 'duet: accept / jump, or request next')
    map('<BS>', restart_current, 'duet demo: restart current example')

    vim.api.nvim_create_user_command('DemoRestart', restart_current, {})
    vim.api.nvim_create_user_command('DemoGoto', function(a)
        jump_to_scenario(tonumber(a.args) or 1)
    end, { nargs = 1 })
    vim.api.nvim_create_user_command('DemoList', function()
        local lines = { { 'duet NES demo examples:', 'Title' } }
        local active = current_index()
        for i, sc in ipairs(Demo.scenarios) do
            local mark = i == active and '> ' or '  '
            lines[#lines + 1] = { ('\n%s%d. %s'):format(mark, i, sc.title), 'Normal' }
        end
        vim.api.nvim_echo(lines, false, {})
    end, {})

    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = Demo.buf,
        callback = refresh_winbar,
    })
end

install_mock()
setup_buffer()

local start = tonumber(os.getenv 'MINUET_DEMO_SCENARIO' or '') or 1
jump_to_scenario(start)
refresh_winbar()

-- Screenshot/replay hook: drive a sequence of keypresses, then signal ready.
-- predict() resolves its preview on a scheduled tick, so step the keys apart.
local keys = os.getenv 'MINUET_DEMO_KEYS'
if keys and keys ~= '' then
    local actions = {
        n = next_step,
        t = tab,
        b = restart_current,
    }
    local list = {}
    for ch in keys:gmatch '[ntb]' do
        list[#list + 1] = actions[ch]
    end
    local function run(i)
        if i > #list then
            vim.g.minuet_demo_ready = true
            return
        end
        list[i]()
        vim.defer_fn(function()
            run(i + 1)
        end, 200)
    end
    vim.defer_fn(function()
        run(1)
    end, 300)
else
    vim.g.minuet_demo_ready = true
end
