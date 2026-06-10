local helpers = require 'tests.helpers'

local function get_extmarks(bufnr, ns_id)
    return vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
end

local function get_suggestion_text(bufnr, ns_id)
    local extmarks = get_extmarks(bufnr, ns_id)
    if #extmarks == 0 then
        return nil
    end

    local details = extmarks[1][4]
    if not details or not details.virt_text then
        return nil
    end

    local lines = { details.virt_text[1][1] }
    if details.virt_lines then
        for _, line in ipairs(details.virt_lines) do
            table.insert(lines, line[1][1])
        end
    end

    return table.concat(lines, '\n')
end

return {
    {
        name = 'virtualtext.action.fire reuses cached suggestions when the stop token becomes narrower',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {
                            stop = '\n\n',
                        },
                    },
                },
            }

            local backend_calls = 0
            local pending_callback

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'alpha\nbeta' }
                    else
                        pending_callback = callback
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()

            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^alpha\nbeta')

            virtualtext.action.fire {
                provider_options = {
                    test = {
                        optional = {
                            stop = '\n',
                        },
                    },
                },
            }

            helpers.expect_truthy(virtualtext.action.is_visible(), 'cached suggestion should remain visible immediately')
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^alpha')
            helpers.expect_truthy(pending_callback, 'second backend request should still be in flight')

            pending_callback { 'alpha\nbeta' }

            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^alpha')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext.action.fire reuses cached suggestions across truncated cursor context shifts',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {},
                    },
                },
            }

            local real_utils = require 'minuet.utils'
            local context_index = 0
            local contexts = {
                {
                    lines_before = 'abc',
                    lines_after = 'xyz',
                    opts = {},
                },
                {
                    lines_before = 'bcq',
                    lines_after = 'xy',
                    opts = {},
                },
            }

            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    context_index = context_index + 1
                    if context_index <= 2 then
                        return contexts[1]
                    end
                    return contexts[2]
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            local pending_callback

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'qhello' }
                    else
                        pending_callback = callback
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^qhello')

            virtualtext.action.fire()

            helpers.expect_truthy(virtualtext.action.is_visible(), 'cached suggestion should remain visible immediately')
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^hello')
            helpers.expect_truthy(pending_callback, 'second backend request should still be in flight')

            pending_callback { 'qhello' }

            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^hello')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext cache keeps future entries but hides them after backspace',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {},
                    },
                },
            }

            local real_utils = require 'minuet.utils'
            local current_context = {
                lines_before = 'abcabc',
                lines_after = 'tail',
                opts = {},
            }

            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current_context
                end,
            }, { __index = real_utils })

            local backend_calls = 0

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'future-derived' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'abcabc' }, { 1, 6 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^future%-derived')

            current_context = {
                lines_before = 'abc',
                lines_after = 'tail',
                opts = {},
            }
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'abc' })
            vim.api.nvim_win_set_cursor(0, { 1, 3 })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_falsy(
                virtualtext.action.is_visible(),
                'cache entries requested ahead of the current cursor must not render'
            )

            current_context = {
                lines_before = 'abcabc',
                lines_after = 'tail',
                opts = {},
            }
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'abcabc' })
            vim.api.nvim_win_set_cursor(0, { 1, 6 })
            virtualtext.action.fire()

            helpers.expect_equal(backend_calls, 1, 'hidden future entry should remain cached')
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^future%-derived')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext.action.next fetches instead of cycling when overrides change cache params',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {
                            stop = '\n',
                        },
                    },
                },
            }

            local backend_calls = 0
            local pending_callback

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'alpha-one', 'alpha-two' }
                    else
                        pending_callback = callback
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^alpha%-one')

            virtualtext.action.next {
                provider_options = {
                    test = {
                        optional = {
                            stop = '\n\n',
                        },
                    },
                },
            }

            helpers.expect_equal(backend_calls, 2, 'override request should fetch a fresh completion set')
            helpers.expect_truthy(pending_callback, 'second backend request should still be in flight')
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^alpha%-one',
                'override request should not cycle through the existing completion set'
            )

            pending_callback { 'paragraph-one', 'paragraph-two' }
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^paragraph%-one')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext auto trigger fires immediately while typing when debounce and throttle are zero',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
            }

            local backend_calls = 0

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'

            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_equal(backend_calls, 3, 'zero-debounce auto trigger should not be deferred until typing pauses')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext unintrusive mode skips auto trigger when text follows the cursor',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'unintrusive',
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            -- Cursor in the middle of `foo(bar) ` between `(` and `bar`: text
            -- after the cursor (`bar) `) is not whitespace-only, so
            -- unintrusive mode should suppress auto-trigger.
            local bufnr = helpers.create_buffer({ 'foo(bar) ' }, { 1, 4 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'unintrusive'

            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_equal(backend_calls, 0, 'unintrusive mode must not fire when non-whitespace follows the cursor')

            -- Cursor on the trailing space at col 8: after-cursor is ` `,
            -- whitespace-only, so unintrusive mode must trigger.
            vim.api.nvim_win_set_cursor(0, { 1, 8 })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_equal(backend_calls, 1, 'unintrusive mode must fire when only whitespace follows')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext set_auto_trigger_mode switches the per-buffer mode',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                virtualtext = { auto_trigger_mode = 'full' },
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            local _, restore_notify = helpers.capture_notifications()
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'n'
            end

            virtualtext.action.set_auto_trigger_mode 'unintrusive'
            helpers.expect_equal(vim.b[bufnr].minuet_virtual_text_auto_trigger_mode, 'unintrusive')

            virtualtext.action.set_auto_trigger_mode 'off'
            helpers.expect_equal(vim.b[bufnr].minuet_virtual_text_auto_trigger_mode, 'off')

            virtualtext.action.set_auto_trigger_mode 'full'
            helpers.expect_equal(vim.b[bufnr].minuet_virtual_text_auto_trigger_mode, 'full')

            vim.fn.mode = original_mode
            restore_notify()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext enable_auto_trigger immediately fires a completion',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'auto-fired' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'off'

            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.enable_auto_trigger()
            helpers.expect_equal(backend_calls, 1, 'enabling auto-trigger should fire a completion immediately')
            helpers.expect_truthy(virtualtext.action.is_visible(), 'ghost text should appear after enable')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext disable_auto_trigger dismisses currently visible ghost text',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                },
            }

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { 'shown' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_truthy(virtualtext.action.is_visible(), 'ghost text should be visible before disable')

            virtualtext.action.disable_auto_trigger()
            helpers.expect_falsy(virtualtext.action.is_visible(), 'disabling auto-trigger should hide ghost text')

            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext disable_auto_trigger ignores in-flight auto-trigger callbacks',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                },
            }

            local backend_calls = 0
            local pending_callback
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    pending_callback = callback
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.set_auto_trigger_mode 'full'
            helpers.expect_equal(backend_calls, 1, 'auto-trigger should start one backend request')
            helpers.expect_truthy(pending_callback, 'backend request should be in flight')

            virtualtext.action.disable_auto_trigger()
            pending_callback { 'stale' }

            helpers.expect_falsy(
                virtualtext.action.is_visible(),
                'late auto-trigger callback should not show ghost text after disable'
            )

            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext accept_word handles multibyte keyword characters',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
            }

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { ' condición = true' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            virtualtext.action.accept_word()

            helpers.wait_until(function()
                return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ' condición'
            end, 1000, 'accept_word should insert the full multibyte word')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext accept_until_char includes a multibyte target character',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
            }

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { 'condición' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            local original_mode = vim.fn.mode
            local original_getcharstr = vim.fn.getcharstr
            vim.fn.mode = function()
                return 'i'
            end
            vim.fn.getcharstr = function()
                return 'ó'
            end

            virtualtext.action.fire()
            virtualtext.action.accept_until_char()

            helpers.wait_until(function()
                return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == 'condició'
            end, 1000, 'accept_until_char should include the full multibyte target')

            virtualtext.action.dismiss()
            vim.fn.getcharstr = original_getcharstr
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext consecutive accept_word inserts successive words from the same suggestion',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'foo bar baz' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            -- Real headless nvim is in normal mode; mode() is mocked to 'i' so
            -- triggers fire, but nvim_win_set_cursor still clamps to the last
            -- char position. virtualedit=onemore lets the cursor sit one past
            -- the end of line, matching real insert-mode behavior so the next
            -- accept inserts at the right column.
            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            virtualtext.action.accept_word()
            virtualtext.action.accept_word()
            virtualtext.action.accept_word()

            helpers.wait_until(function()
                return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == 'foo bar baz'
            end, 1000, 'three consecutive accept_word should insert all three words in order')

            helpers.expect_equal(
                backend_calls,
                1,
                'no extra backend round-trip should be needed between accepts'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext consecutive accept_word survives past the cache drift hard limit',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    cache_max_chars_ahead = 10,
                    cache_soft_chars_ahead = 5,
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'one two three four five' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            for _ = 1, 5 do
                virtualtext.action.accept_word()
            end

            helpers.wait_until(function()
                return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == 'one two three four five'
            end, 1000, 'five accept_word calls should insert the whole 23-char suggestion despite the 10-char drift limit')

            helpers.expect_equal(
                backend_calls,
                1,
                'cache-slide should keep one round-trip enough even past the drift limit'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext fires concurrent requests and an older one still lands matching typed-ahead text',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {},
                    },
                },
            }

            -- get_context is driven by this closure var so we can advance the
            -- "cursor" between keystrokes without touching the real buffer.
            local real_utils = require 'minuet.utils'
            local before = 'a'
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return { lines_before = before, lines_after = '', opts = {} }
                end,
            }, { __index = real_utils })

            -- The fake backend never invokes its callback on its own, so every
            -- request stays "in flight" until the test drives it manually.
            local backend_calls = 0
            local pending = {}
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    table.insert(pending, callback)
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'a' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- First keystroke: cache miss -> request #1, left in flight.
            before = 'a'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            -- Second keystroke at a new position while #1 is still pending and
            -- nothing has been cached yet: it must fire its own request rather
            -- than queue behind the first (the old serialization bug).
            before = 'ab'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_equal(backend_calls, 2, 'second keystroke must fire its own request, not queue behind the first')
            helpers.expect_equal(#pending, 2, 'both requests should be in flight concurrently')

            -- The OLDER request (fired when before='a') returns and "guesses"
            -- the char typed since: its completion 'bc' begins with the
            -- typed-since 'b', so the remaining 'c' should surface as ghost text.
            pending[1] { 'bc' }
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^c',
                'an older in-flight request must still land in the cache and match typed-ahead text'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
}
