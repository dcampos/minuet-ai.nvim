local helpers = require 'tests.helpers'

-- Build an assistant message carrying a single apply_patch tool call.
local function patch_call(patch, id)
    return {
        message = {
            role = 'assistant',
            content = vim.NIL,
            tool_calls = {
                {
                    id = id or 'call_1',
                    ['function'] = { name = 'apply_patch', arguments = vim.json.encode { input = patch } },
                },
            },
        },
    }
end

local function read_call(args, id)
    return {
        message = {
            role = 'assistant',
            content = vim.NIL,
            tool_calls = {
                {
                    id = id or 'read_1',
                    ['function'] = { name = 'read', arguments = vim.json.encode(args or {}) },
                },
            },
        },
    }
end

--- Install a chat stub that captures the latest (messages, tools, callback).
local function install_chat_stub()
    local captured = {}
    package.loaded['minuet.duet.chat'] = {
        request = function(messages, tools, callback)
            captured.messages = messages
            captured.tools = tools
            captured.callback = callback
            captured.calls = (captured.calls or 0) + 1
        end,
    }
    return captured
end

local rename_patch = table.concat({
    '*** Begin Patch',
    '*** Update File: buf',
    '@@',
    '-local x = old',
    '+local x = new',
    '*** End Patch',
}, '\n')

return {
    {
        name = 'duet predict applies an apply_patch tool call and apply updates the buffer',
        run = function()
            helpers.setup_root_config { duet = { preview = { cursor = '|' } } }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = old', 'local y = old' }, { 1, 12 })
            require('minuet.duet.session').rebase(bufnr)

            duet.action.predict()
            helpers.expect_truthy(captured.callback, 'chat.request callback was not captured')
            -- the tools array is forwarded
            helpers.expect_truthy(captured.tools and #captured.tools >= 1)

            captured.callback(patch_call(rename_patch))

            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            duet.action.apply()
            helpers.expect_equal(
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                { 'local x = new', 'local y = old' }
            )
            helpers.expect_falsy(duet.action.is_visible(), 'preview should clear after apply')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet dismiss clears the preview without changing the buffer',
        run = function()
            helpers.setup_root_config { duet = { preview = { cursor = '|' } } }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = old', 'local y = old' }, { 1, 12 })
            require('minuet.duet.session').rebase(bufnr)

            duet.action.predict()
            captured.callback(patch_call(rename_patch))
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'preview did not render')

            duet.action.dismiss()
            helpers.expect_falsy(duet.action.is_visible(), 'preview should clear after dismiss')
            helpers.expect_equal(
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                { 'local x = old', 'local y = old' }
            )
            duet.action.apply()
            helpers.expect_equal(
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                { 'local x = old', 'local y = old' }
            )
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet predict honours a read tool call then applies the follow-up patch',
        run = function()
            helpers.setup_root_config { duet = { preview = { cursor = '|' } } }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = old', 'local y = old' }, { 1, 12 })
            require('minuet.duet.session').rebase(bufnr)

            duet.action.predict()
            -- 1) model asks to read the buffer
            captured.callback(read_call { start_line = 1, end_line = 2 })
            -- the loop should have re-requested with the tool result appended
            helpers.wait_until(function()
                return captured.calls == 2
            end, 1000, 'read did not trigger a follow-up request')
            local tool_msg = captured.messages[#captured.messages]
            helpers.expect_equal(tool_msg.role, 'tool')
            helpers.expect_match(tool_msg.content, 'local x = old')

            -- 2) model now emits the patch
            captured.callback(patch_call(rename_patch))
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'preview did not render after read')

            duet.action.apply()
            helpers.expect_equal(
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                { 'local x = new', 'local y = old' }
            )
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto mode stays silent on a *** No Edit reply',
        run = function()
            helpers.setup_root_config { duet = { preview = { cursor = '|' } } }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = old' }, { 1, 12 })
            require('minuet.duet.session').rebase(bufnr)

            -- drive the internal auto predict via the public manual path but feed a No Edit reply
            duet.action.predict()
            captured.callback { message = { role = 'assistant', content = '*** No Edit' } }

            vim.wait(50, function()
                return false
            end, 10)
            helpers.expect_falsy(duet.action.is_visible(), 'no preview should render for No Edit')
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local x = old' })
            helpers.delete_buffer(bufnr)
        end,
    },
}
