local helpers = require 'tests.helpers'

local session = require 'minuet.duet.session'
local ap = require 'minuet.duet.apply_patch'

local before = { 'local timeout = 30', '', 'local function connect(host)', '  return open(host, timeout)', 'end' }
local after = { 'local timeout_secs = 30', '', 'local function connect(host)', '  return open(host, timeout)', 'end' }

return {
    {
        name = 'session.render_edit emits an apply_patch block with bare @@ and context',
        run = function()
            local block = session.render_edit(before, after, 'net.lua', 8)
            helpers.expect_match(block, '%*%*%* Begin Patch')
            helpers.expect_match(block, '%*%*%* Update File: net%.lua')
            helpers.expect_match(block, '\n%-local timeout = 30')
            helpers.expect_match(block, '\n%+local timeout_secs = 30')
            helpers.expect_match(block, '%*%*%* End Patch')
            -- header rewritten to bare @@ (no -1,3 +1,3 line numbers)
            helpers.expect_match(block, '\n@@\n')
            helpers.expect_falsy(block:find '@@ %-')
            -- expanded context present (the unchanged function line)
            helpers.expect_match(block, 'local function connect%(host%)')
        end,
    },
    {
        name = 'session.render_edit returns nil when nothing changed',
        run = function()
            helpers.expect_falsy(session.render_edit(before, before, 'net.lua', 8))
        end,
    },
    {
        name = 'session.render_edit output round-trips through apply_patch',
        run = function()
            local block = session.render_edit(before, after, 'net.lua', 8)
            local ok, new_lines, err = ap.apply(before, block, { path = 'net.lua' })
            helpers.expect_truthy(ok, 'rendered history block should be valid apply_patch: ' .. tostring(err))
            helpers.expect_equal(new_lines, after)
        end,
    },
    {
        name = 'session.capture records uncoalesced edits and advances baseline',
        run = function()
            local bufnr = helpers.create_buffer { 'a = 1', 'b = 2' }
            session.clear(bufnr)
            session.rebase(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a = 11', 'b = 2' })
            local b1 = session.capture(bufnr, 3)
            helpers.expect_truthy(b1)
            helpers.expect_equal(#session.edits(bufnr), 1)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a = 11', 'b = 22' })
            session.capture(bufnr, 3)
            helpers.expect_equal(#session.edits(bufnr), 2)

            -- second block reflects only the second change
            helpers.expect_match(session.edits(bufnr)[2], '%+b = 22')
            helpers.expect_falsy(session.edits(bufnr)[2]:find 'a = 11\n%+')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'session.should_reset trips on the edit cap',
        run = function()
            local bufnr = helpers.create_buffer { 'x' }
            session.clear(bufnr)
            session.rebase(bufnr)
            helpers.expect_falsy(session.should_reset(bufnr, 2, 20))
            for i = 1, 3 do
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'x' .. i })
                session.capture(bufnr, 3)
            end
            helpers.expect_truthy(session.should_reset(bufnr, 2, 20))
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'session.reset seeds the last edits and clears the running log',
        run = function()
            local bufnr = helpers.create_buffer { 'n = 0' }
            session.clear(bufnr)
            session.rebase(bufnr)
            for i = 1, 4 do
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'n = ' .. i })
                session.capture(bufnr, 3)
            end
            helpers.expect_equal(#session.edits(bufnr), 4)
            session.reset(bufnr, 2)
            helpers.expect_equal(#session.edits(bufnr), 0)
            helpers.expect_equal(#session.get_state(bufnr).seed, 2)
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'session.build_user_turn includes recent edits and a separate cursor note',
        run = function()
            local bufnr = helpers.create_buffer({ 'x = 1', 'y = 2' }, { 1, 5 })
            session.clear(bufnr)
            session.rebase(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'x = 10' })
            -- re-place cursor (set_lines may move it); row 1 col 5
            vim.api.nvim_win_set_cursor(0, { 1, 5 })
            session.capture(bufnr, 3)

            local turn = session.build_user_turn(bufnr, { ctx_lines = 3 })
            helpers.expect_match(turn, 'Recent edits %(oldest to newest%):')
            -- cursor fed as a separate note (line 1), not an inline marker in the file text
            helpers.expect_match(turn, 'Editor cursor: line 1')
            helpers.expect_falsy(turn:find('<|cursor|>', 1, true), 'file text must stay clean of cursor markers')
            helpers.expect_match(turn, 'Current file')
            helpers.delete_buffer(bufnr)
        end,
    },
}
