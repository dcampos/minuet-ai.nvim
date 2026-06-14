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
            helpers.setup_root_config { duet = { preview = { cursor = '|' }, session = { auto_trigger = true } } }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = old' }, { 1, 12 })
            require('minuet.duet.session').rebase(bufnr)

            -- An auto prediction fires off the edit-capture autocmd (debounced).
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
            helpers.wait_until(function()
                return captured.callback ~= nil
            end, 1000, 'auto-trigger did not fire a prediction')
            -- The model is told it was auto-triggered, so declining is allowed.
            helpers.expect_match(captured.messages[1].content, 'auto%-triggered')

            captured.callback { message = { role = 'assistant', content = '*** No Edit' } }

            vim.wait(50, function()
                return false
            end, 10)
            helpers.expect_equal(captured.calls, 1, 'auto No Edit should not re-request')
            helpers.expect_falsy(duet.action.is_visible(), 'no preview should render for No Edit')
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local x = old' })
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet manual mode rejects *** No Edit and re-requests with an error',
        run = function()
            helpers.setup_root_config { duet = { preview = { cursor = '|' } } }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = old', 'local y = old' }, { 1, 12 })
            require('minuet.duet.session').rebase(bufnr)

            duet.action.predict()
            -- A manual trigger must produce an edit; the system prompt says so.
            helpers.expect_match(captured.messages[1].content, 'MUST propose')
            helpers.expect_falsy(captured.messages[1].content:find('auto%-triggered'), 'manual prompt must not offer the decline path')

            -- Model declines anyway: the loop should push back an error and re-request.
            captured.callback { message = { role = 'assistant', content = '*** No Edit' } }
            helpers.wait_until(function()
                return captured.calls == 2
            end, 1000, 'manual No Edit did not trigger a re-request')
            local pushback = captured.messages[#captured.messages]
            helpers.expect_equal(pushback.role, 'user')
            helpers.expect_match(pushback.content, 'invalid')

            -- A real patch on the retry still applies cleanly.
            captured.callback(patch_call(rename_patch))
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'preview did not render after the retry patch')
            duet.action.apply()
            helpers.expect_equal(
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                { 'local x = new', 'local y = old' }
            )
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet does not predict on a scratch/special buffer (e.g. the inspect float)',
        run = function()
            helpers.setup_root_config { duet = { preview = { cursor = '|' } } }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ '# Minuet duet · session' }, { 1, 1 })
            vim.bo[bufnr].buftype = 'nofile' -- like the inspect float / scratch buffers
            duet.action.predict()
            helpers.expect_falsy(captured.callback, 'no chat request should fire on a non-file buffer')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto-trigger ignores non-modifiable buffers',
        run = function()
            helpers.setup_root_config { duet = { preview = { cursor = '|' }, session = { auto_trigger = true } } }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'read only view' }, { 1, 1 })
            vim.bo[bufnr].modifiable = false
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

            vim.wait(50, function()
                return false
            end, 10)
            helpers.expect_falsy(captured.callback, 'auto-trigger should not fire on a non-modifiable buffer')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet replays a shown prediction + disposition as inter-diff memory next time',
        run = function()
            helpers.setup_root_config { duet = { preview = { cursor = '|' } } }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = old', 'local y = old' }, { 1, 12 })
            require('minuet.duet.session').rebase(bufnr)

            -- first prediction -> patch shown -> accepted
            duet.action.predict()
            captured.callback(patch_call(rename_patch))
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'first preview did not render')
            duet.action.apply()

            -- second prediction: the accepted patch should be replayed as an
            -- interleaved assistant turn, followed by its disposition.
            duet.action.predict()
            local msgs = captured.messages
            helpers.expect_equal(msgs[1].role, 'system')
            local asst_idx
            for i, m in ipairs(msgs) do
                if m.role == 'assistant' and type(m.content) == 'string' and m.content:find('local x = new', 1, true) then
                    asst_idx = i
                end
            end
            helpers.expect_truthy(asst_idx, 'the prior patch should be replayed as an assistant turn')
            helpers.expect_equal(msgs[asst_idx + 1].role, 'user')
            helpers.expect_match(msgs[asst_idx + 1].content, 'accepted')
            -- the full current file still follows as the final user turn
            helpers.expect_equal(msgs[#msgs].role, 'user')
            helpers.expect_match(msgs[#msgs].content, 'Current file')
            helpers.delete_buffer(bufnr)
        end,
    },
}
