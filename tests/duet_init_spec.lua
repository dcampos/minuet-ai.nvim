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

local function install_chat_queue_stub()
    local captured = { requests = {} }
    package.loaded['minuet.duet.chat'] = {
        request = function(messages, tools, callback)
            captured.calls = (captured.calls or 0) + 1
            local request = {
                messages = messages,
                tools = tools,
                callback = callback,
            }
            captured.requests[#captured.requests + 1] = request
            captured.messages = messages
            captured.tools = tools
            captured.callback = callback
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
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local x = new', 'local y = old' })
            local entries = require('minuet.duet.session').diff_entries(bufnr)
            helpers.expect_equal(#entries, 1)
            helpers.expect_equal(entries[1].original, 'local x = old')
            helpers.expect_equal(entries[1].updated, 'local x = new')
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
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local x = old', 'local y = old' })
            duet.action.apply()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local x = old', 'local y = old' })
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
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local x = new', 'local y = old' })
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

            -- An auto prediction fires immediately off the edit-capture autocmd.
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
        name = 'duet auto-trigger rate limits rapid edit events',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = { cursor = '|' },
                    session = { auto_trigger = true, max_auto_requests_per_second = 1 },
                },
            }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = old' }, { 1, 12 })
            require('minuet.duet.session').rebase(bufnr)

            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
            helpers.expect_equal(captured.calls, 1)
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
            helpers.expect_equal(captured.calls, 1, 'second auto request inside the same second should be skipped')

            duet.action.predict()
            helpers.expect_equal(captured.calls, 2, 'manual requests bypass the auto safety valve')
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
            helpers.expect_falsy(
                captured.messages[1].content:find 'auto%-triggered',
                'manual prompt must not offer the decline path'
            )

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
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local x = new', 'local y = old' })
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
            helpers.setup_root_config {
                duet = {
                    preview = { cursor = '|' },
                    session = { prediction_memory = true },
                },
            }
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
                if
                    m.role == 'assistant'
                    and type(m.content) == 'string'
                    and m.content:find('local x = new', 1, true)
                then
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
    {
        name = 'duet accept_or_next navigates and accepts inline chunks one at a time',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = { cursor = '|' },
                    session = { prefetch_after_preview = false },
                },
            }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return alpha + beta' }, { 1, 0 })
            require('minuet.duet.session').rebase(bufnr)
            local patch = table.concat({
                '*** Begin Patch',
                '*** Update File: buf',
                '@@',
                '-return alpha + beta',
                '+return omega + gamma',
                '*** End Patch',
            }, '\n')

            duet.action.predict()
            captured.callback(patch_call(patch))
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'preview did not render')

            -- Tab 1: navigate to the first change (reveal); cursor lands on it,
            -- nothing accepted yet.
            duet.action.accept_or_next()
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, #'return ' })
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return alpha + beta' })

            -- Tab 2: accept the first change, then auto-advance within the same
            -- response -- the cursor moves onto the second change with no
            -- re-collapse, so the next Tab accepts it directly.
            duet.action.accept_or_next()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return omega + beta' })
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, #'return omega + ' })
            helpers.expect_truthy(duet.action.is_visible(), 'second change should stay revealed')

            -- Tab 3: accept the second (last) change -- the response is fully
            -- applied and the preview clears (crossing to any next response would
            -- need its own Tab).
            duet.action.accept_or_next()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return omega + gamma' })
            helpers.expect_falsy(duet.action.is_visible(), 'all changes accepted')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet accept_or_next ignores its own TextChanged after partial accept',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = { cursor = '|' },
                    session = { prefetch_after_preview = false },
                },
            }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({
                'local total = 0',
                'log("start")',
                'count = count + 1',
                'log("mid")',
                'print(count)',
            }, { 3, 0 })
            require('minuet.duet.session').rebase(bufnr)
            local patch = table.concat({
                '*** Begin Patch',
                '*** Update File: buf',
                '@@',
                '-local total = 0',
                '-log("start")',
                '-count = count + 1',
                '-log("mid")',
                '-print(count)',
                '+local total = 0',
                '+log("start")',
                '+total = total + 1',
                '+log("mid")',
                '+print(total)',
                '*** End Patch',
            }, '\n')

            duet.action.predict()
            captured.callback(patch_call(patch))
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'preview did not render')

            duet.action.accept_or_next() -- accept the first `count`, auto-advance to the second
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[3], 'total = count + 1')
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 3, #'total = ' })

            -- Neovim may deliver TextChanged for the programmatic set_lines used
            -- by partial accept. That event must not force the next Tab to
            -- navigate away from the chunk already selected by auto-advance.
            vim.cmd 'doautocmd <nomodeline> TextChanged'
            duet.action.accept_or_next()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[3], 'total = total + 1')
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 5, #'print(' })

            duet.action.accept_or_next()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
                'local total = 0',
                'log("start")',
                'total = total + 1',
                'log("mid")',
                'print(total)',
            })
            helpers.expect_falsy(duet.action.is_visible(), 'all chunks should be accepted')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet accept_or_next reveals a collapsed block when cursor starts on its marker',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = { cursor = '|' },
                    session = { prefetch_after_preview = false },
                },
            }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local original = {
                'local function div(a, b)',
                '    return a / b',
                'end',
            }
            local proposed = {
                'local function div(a, b)',
                '    if b == 0 then',
                '        return 0',
                '    end',
                '    return a / b',
                'end',
            }
            local bufnr = helpers.create_buffer(original, { 1, 0 })
            require('minuet.duet.session').rebase(bufnr)
            local patch = table.concat({
                '*** Begin Patch',
                '*** Update File: buf',
                '@@',
                '-local function div(a, b)',
                '-    return a / b',
                '-end',
                '+local function div(a, b)',
                '+    if b == 0 then',
                '+        return 0',
                '+    end',
                '+    return a / b',
                '+end',
                '*** End Patch',
            }, '\n')

            duet.action.predict()
            captured.callback(patch_call(patch))
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'preview did not render')
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 0 })

            duet.action.accept_or_next()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), original)
            helpers.expect_truthy(duet.action.is_visible(), 'first Tab should reveal, not accept')

            duet.action.accept_or_next()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), proposed)
            helpers.expect_falsy(duet.action.is_visible(), 'second Tab should accept the revealed block')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet accept_or_next accepts and advances through end-of-line insertions',
        run = function()
            -- An end-of-line insertion (e.g. appending `\`) anchors one byte past
            -- the last character, where the normal-mode cursor cannot land. The
            -- accept/navigation must still recognize the cursor as on that chunk,
            -- or every Tab just re-navigates to it and nothing can be accepted.
            helpers.setup_root_config {
                duet = {
                    preview = { cursor = '|' },
                    session = { prefetch_after_preview = false },
                },
            }
            local captured = install_chat_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return alpha', 'return beta' }, { 1, 0 })
            require('minuet.duet.session').rebase(bufnr)
            local patch = table.concat({
                '*** Begin Patch',
                '*** Update File: buf',
                '@@',
                '-return alpha',
                '-return beta',
                '+return alpha \\',
                '+return beta \\',
                '*** End Patch',
            }, '\n')

            duet.action.predict()
            captured.callback(patch_call(patch))
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'preview did not render')

            -- Tab 1: navigate to the first end-of-line change; cursor lands at the
            -- last reachable column (one short of the anchor), nothing accepted.
            duet.action.accept_or_next()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return alpha', 'return beta' })

            -- Tab 2: accept the first change despite the unreachable anchor, then
            -- auto-advance to the second end-of-line change.
            duet.action.accept_or_next()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return alpha \\', 'return beta' })
            helpers.expect_truthy(duet.action.is_visible(), 'second change should stay revealed')

            -- Tab 3: accept the last change; the response is fully applied.
            duet.action.accept_or_next()
            helpers.expect_equal(
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                { 'return alpha \\', 'return beta \\' }
            )
            helpers.expect_falsy(duet.action.is_visible(), 'all end-of-line changes accepted')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet prefetch queues the simulated-after-accept prediction',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = { cursor = '|' },
                    session = {
                        auto_trigger = true,
                        diagnostic_auto_trigger = false,
                        prefetch_after_preview = true,
                    },
                },
            }
            local captured = install_chat_queue_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = old', 'local y = old' }, { 1, 12 })
            require('minuet.duet.session').rebase(bufnr)
            local y_patch = table.concat({
                '*** Begin Patch',
                '*** Update File: buf',
                '@@',
                '-local y = old',
                '+local y = new',
                '*** End Patch',
            }, '\n')

            duet.action.predict()
            captured.requests[1].callback(patch_call(rename_patch, 'call_x'))
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'first preview did not render')
            helpers.wait_until(function()
                return captured.calls == 2
            end, 1000, 'prefetch request did not fire')
            helpers.expect_match(captured.requests[2].messages[#captured.requests[2].messages].content, 'local x = new')

            captured.requests[2].callback(patch_call(y_patch, 'call_y'))
            vim.wait(50, function()
                return false
            end, 10)

            duet.action.apply()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local x = new', 'local y = old' })
            helpers.expect_truthy(duet.action.is_visible(), 'queued prediction should be shown after first accept')

            duet.action.apply()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local x = new', 'local y = new' })
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto-trigger sends a diagnostic-focused request with diagnostic history',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = { cursor = '|' },
                    session = {
                        auto_trigger = true,
                        diagnostic_auto_trigger = true,
                    },
                },
            }
            local captured = install_chat_queue_stub()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'local x = nil', 'return x.foo' }, { 1, 0 })
            require('minuet.duet.session').rebase(bufnr)
            local diagnostic = {
                lnum = 1,
                col = 9,
                severity = vim.diagnostic.severity.ERROR,
                message = 'attempt to index nil value',
                source = 'lua_ls',
            }
            require('minuet.duet.session').note_diagnostics(bufnr, { diagnostic })

            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
            helpers.wait_until(function()
                return captured.calls == 2
            end, 1000, 'cursor + diagnostic auto requests should fire')

            local diagnostic_user = captured.requests[2].messages[#captured.requests[2].messages].content
            helpers.expect_match(diagnostic_user, 'Prediction focus: fix')
            helpers.expect_match(diagnostic_user, 'Focus diagnostic: line 2, column 10')
            helpers.expect_match(diagnostic_user, 'attempt to index nil value')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet history_format action group sets and toggles the config',
        run = function()
            helpers.setup_root_config {}
            local duet = require 'minuet.duet'
            local session = require('minuet').config.duet.session

            duet.action.history_format.unified()
            helpers.expect_equal(session.edit_history_format, 'unified')
            duet.action.history_format.synthetic()
            helpers.expect_equal(session.edit_history_format, 'synthetic')
            duet.action.history_format.toggle()
            helpers.expect_equal(session.edit_history_format, 'unified')
            duet.action.history_format.toggle()
            helpers.expect_equal(session.edit_history_format, 'synthetic')
        end,
    },
}
