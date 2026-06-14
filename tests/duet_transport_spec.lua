local helpers = require 'tests.helpers'

return {
    {
        name = 'duet.action.predict works through the openai-compatible tool-call transport',
        run = function()
            local original_api_key = vim.env.OPENROUTER_API_KEY
            local bufnr

            local ok, err = xpcall(function()
                local mock = vim.fn.getcwd() .. '/tests/scripts/mock_openai_toolcall.sh'
                vim.env.OPENROUTER_API_KEY = 'test-key'

                helpers.setup_root_config {
                    curl_cmd = mock,
                    duet = {
                        provider = 'openai_compatible',
                        request_timeout = 5,
                        provider_options = {
                            openai_compatible = {
                                end_point = 'http://127.0.0.1/duet-mock',
                                model = 'fixture-model',
                                api_key = 'OPENROUTER_API_KEY',
                                name = 'Fixture',
                                optional = {},
                            },
                        },
                    },
                }

                local duet = helpers.reload 'minuet.duet'
                duet.setup()

                bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
                require('minuet.duet.session').rebase(bufnr)

                duet.action.predict()

                helpers.wait_until(function()
                    return duet.action.is_visible()
                end, 3000, 'duet preview did not become visible through the transport test')

                duet.action.apply()

                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 42' })
                helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after apply')
            end, debug.traceback)

            vim.env.OPENROUTER_API_KEY = original_api_key
            helpers.delete_buffer(bufnr)

            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'duet.action.predict works through the Inception Mercury Edit transport',
        run = function()
            local original_api_key = vim.env.INCEPTION_API_KEY
            local bufnr

            local ok, err = xpcall(function()
                local mock = vim.fn.getcwd() .. '/tests/scripts/mock_inception_edit.sh'
                vim.env.INCEPTION_API_KEY = 'test-key'

                helpers.setup_root_config {
                    curl_cmd = mock,
                    duet = {
                        provider = 'inception_edit',
                        request_timeout = 5,
                        provider_options = {
                            inception_edit = {
                                end_point = 'http://127.0.0.1/inception-edit-mock',
                                model = 'mercury-edit-2',
                                api_key = 'INCEPTION_API_KEY',
                                name = 'Inception Fixture',
                                lines_before = 0,
                                lines_after = 0,
                                max_tokens = 128,
                                optional = {},
                            },
                        },
                    },
                }

                local duet = helpers.reload 'minuet.duet'
                duet.setup()

                bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
                require('minuet.duet.session').rebase(bufnr)

                duet.action.predict()

                helpers.wait_until(function()
                    return duet.action.is_visible()
                end, 3000, 'duet preview did not become visible through the Inception edit transport test')

                duet.action.apply()

                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 42' })
                helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after apply')
            end, debug.traceback)

            vim.env.INCEPTION_API_KEY = original_api_key
            helpers.delete_buffer(bufnr)

            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'Inception Mercury Edit unchanged replacement declines auto and errors manual',
        run = function()
            local original_api_key = vim.env.INCEPTION_API_KEY
            local original_mock_content = vim.env.MINUET_MOCK_INCEPTION_CONTENT
            local bufnr

            local ok, err = xpcall(function()
                local mock = vim.fn.getcwd() .. '/tests/scripts/mock_inception_edit.sh'
                vim.env.INCEPTION_API_KEY = 'test-key'
                vim.env.MINUET_MOCK_INCEPTION_CONTENT = 'return 1'

                helpers.setup_root_config {
                    curl_cmd = mock,
                    duet = {
                        provider = 'inception_edit',
                        request_timeout = 5,
                        provider_options = {
                            inception_edit = {
                                end_point = 'http://127.0.0.1/inception-edit-mock',
                                model = 'mercury-edit-2',
                                api_key = 'INCEPTION_API_KEY',
                                name = 'Inception Fixture',
                                lines_before = 0,
                                lines_after = 0,
                                max_tokens = 128,
                                optional = {},
                            },
                        },
                    },
                }

                bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
                require('minuet.duet.session').clear(bufnr)
                require('minuet.duet.session').rebase(bufnr)
                local chat = helpers.reload 'minuet.duet.chat'

                local auto_done, auto_result = false, nil
                chat.request({}, {}, function(result)
                    auto_result = result
                    auto_done = true
                end, { bufnr = bufnr, mode = 'auto' })
                helpers.wait_until(function()
                    return auto_done
                end, 3000, 'auto unchanged Mercury response did not complete')
                helpers.expect_match(auto_result.message.content, '%*%*%* No Edit')

                local manual_done, manual_result = false, nil
                chat.request({}, {}, function(result)
                    manual_result = result
                    manual_done = true
                end, { bufnr = bufnr, mode = 'manual' })
                helpers.wait_until(function()
                    return manual_done
                end, 3000, 'manual unchanged Mercury response did not complete')
                helpers.expect_match(manual_result.error, 'no change')
            end, debug.traceback)

            vim.env.INCEPTION_API_KEY = original_api_key
            vim.env.MINUET_MOCK_INCEPTION_CONTENT = original_mock_content
            helpers.delete_buffer(bufnr)

            if not ok then
                error(err)
            end
        end,
    },
}
