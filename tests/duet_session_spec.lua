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
        name = 'session.render_edit_diff emits range-based Mercury Edit history (no context lines, synthetic header)',
        run = function()
            local block = session.render_edit_diff(before, after, 'net.lua')
            helpers.expect_match(block, '^%-%-%- net%.lua\n%+%+%+ net%.lua')
            -- synthetic hunk header anchored at line 1, non-empty line counts
            helpers.expect_match(block, '\n@@ %-1,1 %+1,1 @@\n')
            helpers.expect_match(block, '\n%-local timeout = 30')
            helpers.expect_match(block, '\n%+local timeout_secs = 30')
            helpers.expect_falsy(block:find '%*%*%* Begin Patch')
            -- unchanged surrounding lines are NOT carried as context
            helpers.expect_falsy(block:find 'local function connect', 'history is range-based, no context lines')
        end,
    },
    {
        name = 'session.diff_region returns the bounding changed block before/after',
        run = function()
            local original, updated, start_line = session.diff_region(before, after)
            helpers.expect_equal(original, { 'local timeout = 30' })
            helpers.expect_equal(updated, { 'local timeout_secs = 30' })
            helpers.expect_equal(start_line, 1)
            helpers.expect_falsy(session.diff_region(before, before))
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
    {
        name = 'session.build_inception_edit_turn uses Mercury Edit tags and range-based history',
        run = function()
            local bufnr = helpers.create_buffer({ 'local x = 1', 'local y = 2', 'return x + y' }, { 2, 9 })
            session.clear(bufnr)
            session.rebase(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'local x = 10' })
            vim.api.nvim_win_set_cursor(0, { 2, 9 })
            session.capture(bufnr, 3)

            local prompt, region = session.build_inception_edit_turn(bufnr, { lines_before = 1, lines_after = 1 })
            helpers.expect_match(prompt, '<|recently_viewed_code_snippets|>')
            helpers.expect_match(prompt, '<|/recently_viewed_code_snippets|>')
            helpers.expect_match(prompt, '<|current_file_content|>')
            helpers.expect_match(prompt, 'current_file_path: %[No Name%]')
            helpers.expect_match(prompt, '<|code_to_edit|>')
            helpers.expect_match(prompt, 'local y =<|cursor|> 2')
            helpers.expect_match(prompt, '<|edit_diff_history|>')
            -- range-based history entry: synthetic header + the changed block
            helpers.expect_match(
                prompt,
                '%-%-%- %[No Name%]\n%+%+%+ %[No Name%]\n@@ %-1,1 %+1,1 @@\n%-local x = 1\n%+local x = 10\n'
            )
            helpers.expect_equal(region.original_lines, { 'local x = 10', 'local y = 2', 'return x + y' })
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'session.build_inception_edit_turn emits cross-file snippets from recent cursor locations',
        run = function()
            local other = helpers.create_buffer({ 'def helper():', '    return 1' }, { 1, 0 })
            vim.api.nvim_buf_set_name(other, 'helper.py')
            session.note_cursor(other)

            local bufnr = helpers.create_buffer({ 'main = 1', 'main = 2' }, { 2, 0 })
            session.clear(bufnr)
            session.rebase(bufnr)

            local prompt = session.build_inception_edit_turn(bufnr, { lines_before = 1, lines_after = 1 })
            helpers.expect_match(prompt, '<|recently_viewed_code_snippet|>\ncode_snippet_file_path: helper%.py\n')
            helpers.expect_match(prompt, 'def helper%(%):')
            helpers.delete_buffer(bufnr)
            helpers.delete_buffer(other)
        end,
    },
}
