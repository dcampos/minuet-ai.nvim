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
}
