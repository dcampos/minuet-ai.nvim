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
        name = 'virtualtext caps the suffix sent to the backend via context_after_chars',
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
                    -- function form: budget depends on the prefix length
                    context_after_chars = function(prefix_chars)
                        return prefix_chars >= 10 and 5 or 100
                    end,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return {
                        lines_before = 'abcdefghij', -- 10 chars -> budget 5
                        lines_after = '0123456789', -- 10 chars, should be cut to 5
                        opts = {},
                    }
                end,
            }, { __index = real_utils })

            local sent_context
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback)
                    sent_context = context
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'abcdefghij' }, { 1, 10 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()

            helpers.expect_truthy(sent_context, 'backend received a request')
            helpers.expect_equal(sent_context.lines_after, '01234', 'suffix capped to the budget')
            helpers.expect_truthy(sent_context.opts.is_incomplete_after, 'capping marks the suffix incomplete')

            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext anchor snaps back to an older snap point after a jump',
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
                    context_growth_slack = 100,
                    max_anchors = 8,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            -- control.fresh = the prefix a fresh (no-anchor) window returns.
            -- control.a_anchors = whether a candidate whose snap prefix is 'A'
            -- is currently still buffer-valid (anchors). This lets us simulate
            -- a jump where the newest snap ('B') is stale but an older one ('A')
            -- is still warm.
            local control = { fresh = 'A', a_anchors = false }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function(_, _, anchor)
                    if anchor then
                        local ok = anchor.prev_lines_before == 'A' and control.a_anchors
                        return {
                            lines_before = anchor.prev_lines_before .. '+',
                            lines_after = 'AFT',
                            opts = { anchored = ok },
                        }
                    end
                    return { lines_before = control.fresh, lines_after = 'AFT', opts = {} }
                end,
            }, { __index = real_utils })

            local sent = {}
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback)
                    table.insert(sent, context)
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- T1: fresh window 'A' -> establishes snap point A.
            virtualtext.action.fire()
            -- T2: snap A rejected (slack exceeded), fresh window 'B' -> snap B.
            control.fresh = 'B'
            virtualtext.action.fire()
            -- T3: a jump back -- newest snap B is stale, older snap A is warm.
            control.a_anchors = true
            virtualtext.action.fire()

            helpers.expect_equal(#sent, 3, 'three requests dispatched')
            helpers.expect_equal(sent[1].lines_before, 'A', 'T1 sends the fresh A window')
            helpers.expect_equal(sent[2].lines_before, 'B', 'T2 re-anchors to a fresh B window')
            -- The newest snap (B) does not match on the jump; the ring looks
            -- back and snaps to the older A, growing from it ('A+').
            helpers.expect_equal(sent[3].lines_before, 'A+', 'T3 snaps back to the older warm anchor')
            helpers.expect_truthy(sent[3].opts.anchored, 'snap-back is an anchored reuse')

            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Content-based cache (no shift): the same state re-shows from cache
        -- verbatim, but a typed-ahead state (cursor advanced past the cached
        -- position) is no longer "shifted" into a partial match -- it misses
        -- and refetches.
        name = 'virtualtext content cache re-shows the same state and refetches a shifted one',
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
            local current = { lines_before = 'abc', lines_after = 'xyz', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'qhello' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- First request at state 'abc' -> caches and shows 'qhello'.
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^qhello')

            -- Exact same state: served from cache, no new request.
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1, 'identical state is served from cache')
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^qhello')

            -- Typed-ahead state 'bcq' is not a suffix of cached 'abc' (no shift):
            -- the cache misses and a fresh request fires.
            current = { lines_before = 'bcq', lines_after = 'xy', opts = {} }
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 2, 'a shifted state refetches instead of shifting the cache')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Forward typing grows the window (the prefix start stays put until the
        -- buffer exceeds context_window), so cached 'abc' is a *prefix* of the
        -- typed-ahead 'abcq'. The user typed the head of 'qhello', so the cache
        -- serves the stripped remainder 'hello' without a new request.
        name = 'virtualtext content cache strips the typed prefix when the window grows forward',
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
            local current = { lines_before = 'abc', lines_after = 'xyz', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'qhello' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- First request at 'abc' -> caches and shows 'qhello'.
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^qhello')

            -- Typed 'q' into the completion: window grew to 'abcq'. The cache
            -- serves 'hello' (the untyped remainder), no new request.
            current = { lines_before = 'abcq', lines_after = 'xyz', opts = {} }
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1, 'a grown window is served from cache, not refetched')
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^hello')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext cycling locks a choice that re-shows on returning to the state',
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
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'S', lines_after = '', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { 'AA', 'BB' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- State S: two suggestions, top-ranked AA shown.
            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^AA')

            -- Cycle to BB: this pins BB as the choice for state S.
            virtualtext.action.next()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^BB')

            -- Move to a different, incompatible state: the lock does not apply,
            -- so the natural ranking (AA) shows there.
            current = { lines_before = 'AWAY', lines_after = '', opts = {} }
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^AA')

            -- Return to state S: the pinned BB comes back, not the ranked AA.
            current = { lines_before = 'S', lines_after = '', opts = {} }
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^BB',
                'returning to the state re-shows the cycled (locked) choice'
            )

            -- An explicit dismiss drops the lock; next visit shows the ranked AA.
            virtualtext.action.dismiss()
            current = { lines_before = 'S', lines_after = '', opts = {} }
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^AA', 'dismiss clears the lock')

            virtualtext.action.dismiss()
            package.loaded['minuet.utils'] = real_utils
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
        name = 'virtualtext consecutive accept_word inserts the whole suggestion with one round-trip',
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
            end, 1000, 'five accept_word calls should insert the whole 23-char suggestion')

            helpers.expect_equal(
                backend_calls,
                1,
                'the cache-slide keeps the entry compatible, so one round-trip is enough'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext fires concurrent requests and an older one still lands for its own state',
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

            -- Request #2 matches the current state 'ab' and shows immediately.
            pending[2] { 'XY' }
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^XY')

            -- The OLDER request (fired at state 'a') lands later. It still caches
            -- its completion, but 'a' is not compatible with the current 'ab'
            -- state (no shift), so the display stays on #2's result.
            pending[1] { 'Z1' }
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^XY')

            -- Returning to state 'a' re-shows the older request's cached result.
            before = 'a'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^Z1',
                'the older in-flight request still lands in the cache and shows when its state returns'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Soft band: a cached completion the cursor has drifted past the soft
        -- limit (but not the hard one) is still shown, yet does not count as a
        -- fresh completion, so a background top-up request keeps firing to refill
        -- the n_completions bucket.
        name = 'virtualtext soft band shows the completion but still fires a top-up',
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
                    cache_soft_chars_ahead = 2,
                    cache_max_chars_ahead = 20,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local before = 'p'
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return { lines_before = before, lines_after = '', opts = {} }
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'abcdefghij' }
                    else
                        callback {}
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'p' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- Fresh at 'p': one completion satisfies n_completions, no top-up.
            before = 'p'
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^abcdefghij')

            -- Typed 'abc': drift 3 is past the soft limit (2) but within the hard
            -- limit (20). The remainder still shows, but it no longer counts as
            -- fresh, so a top-up request fires.
            before = 'pabc'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^defghij',
                'soft-band completion stays shown'
            )
            helpers.expect_equal(backend_calls, 2, 'a soft-band state fires a background top-up')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Hard band: an unlocked sibling completion is hidden from the cycle list
        -- once the cursor drifts past the hard limit, while the shown/locked one
        -- stays visible (so accept_word / accept_line sliding never drops it). A
        -- cursor that returns within the band re-shows the hidden sibling.
        name = 'virtualtext hard band hides the unlocked sibling but keeps the locked one and re-shows on return',
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
                    cache_soft_chars_ahead = 2,
                    cache_max_chars_ahead = 4,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local before = 'p'
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return { lines_before = before, lines_after = '', opts = {} }
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'abcdefAAA', 'abcdefBBB' }
                    else
                        callback {}
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'p' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- Two siblings at 'p'; the first is shown (and becomes the lock).
            before = 'p'
            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^abcdefAAA %(1/2%)')

            -- Typed 5 chars (drift 5 > hard 4): the unlocked sibling drops out of
            -- the list, but the locked one stays visible -- no (x/2) any more.
            before = 'pabcde'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            local shown = get_suggestion_text(bufnr, virtualtext.ns_id)
            helpers.expect_match(shown, '^fAAA', 'the locked completion survives past the hard limit')
            helpers.expect_falsy(shown:find('/2', 1, true), 'the unlocked sibling is hidden past the hard limit')

            -- Backspace to drift 2 (fresh again): the hidden sibling returns.
            before = 'pab'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^cdefAAA %(1/2%)',
                'a returning cursor re-shows the cached sibling'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- With dismiss_drops_lock = false, dismiss is a temporary "get out of my
        -- way" hide: the per-state lock survives, so re-triggering at the locked
        -- state brings the cycled choice back instead of the natural ranking.
        name = 'virtualtext dismiss_drops_lock=false keeps the cycled choice across a dismiss',
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
                    auto_trigger_mode = 'full',
                    dismiss_drops_lock = false,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'S', lines_after = '', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { 'AA', 'BB' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            virtualtext.action.next()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^BB')

            -- Dismiss hides the ghost text but keeps the lock.
            virtualtext.action.dismiss()
            helpers.expect_falsy(virtualtext.action.is_visible(), 'dismiss still hides the ghost text')

            -- Re-trigger at the same state: the cycled BB returns, not ranked AA.
            virtualtext.action.fire()
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^BB',
                'the lock survives dismiss and re-shows the cycled choice'
            )

            virtualtext.action.dismiss()
            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
}
