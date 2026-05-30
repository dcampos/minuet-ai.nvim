local helpers = require 'tests.helpers'

return {
    {
        name = 'openai FIM backend gives each parallel request its own body file',
        run = function()
            local root = helpers.setup_root_config {
                n_completions = 3,
                request_timeout = 1,
                curl_extra_args = {},
                fim_filter_context = false,
            }

            local base = helpers.reload 'minuet.backends.openai_base'
            local common = require 'minuet.backends.common'
            local utils = require 'minuet.utils'

            local original_make_tmp_file = utils.make_tmp_file
            local original_make_curl_args = utils.make_curl_args
            local original_stream_decode = utils.stream_decode
            local original_start_job = common.start_job
            local original_terminate_all_jobs = common.terminate_all_jobs

            local tmp_files = {}
            local curl_files = {}
            local decoded_files = {}
            local callbacks = {}

            local function restore()
                utils.make_tmp_file = original_make_tmp_file
                utils.make_curl_args = original_make_curl_args
                utils.stream_decode = original_stream_decode
                common.start_job = original_start_job
                common.terminate_all_jobs = original_terminate_all_jobs
            end

            local ok, err = pcall(function()
                utils.make_tmp_file = function(content)
                    local file = '/tmp/minuet-fim-body-' .. (#tmp_files + 1) .. '.json'
                    table.insert(tmp_files, {
                        file = file,
                        content = content,
                    })
                    return file
                end

                utils.make_curl_args = function(_, _, data_file)
                    table.insert(curl_files, data_file)
                    return { '-d', '@' .. data_file }
                end

                utils.stream_decode = function(_, data_file)
                    table.insert(decoded_files, data_file)
                    return 'completion ' .. #decoded_files
                end

                common.terminate_all_jobs = function() end
                common.start_job = function(_, _, handlers)
                    local job = { pid = #decoded_files + 1 }
                    handlers.on_exit(job, { code = 0, stdout = '' })
                    return job
                end

                base.complete_openai_fim_base({
                    name = 'Codestral',
                    model = 'codestral-latest',
                    end_point = 'https://example.test/v1/fim/completions',
                    api_key = function()
                        return 'test-key'
                    end,
                    stream = true,
                    optional = {},
                    transform = {},
                    template = {
                        prompt = function(before)
                            return before
                        end,
                        suffix = function(_, after)
                            return after
                        end,
                    },
                }, function(json)
                    return json.choices[1].delta.content
                end, {
                    lines_before = 'def add(a, b):',
                    lines_after = 'return a + b',
                    opts = {},
                }, function(items, done)
                    table.insert(callbacks, {
                        items = items,
                        done = done,
                    })
                end, root.config)

                helpers.expect_equal(#tmp_files, 3, 'each FIM request should get a separate temp file')
                helpers.expect_equal(#curl_files, 3, 'each FIM request should build curl args')
                helpers.expect_equal(#decoded_files, 3, 'each FIM request should decode its own response')
                helpers.expect_equal(
                    curl_files[1] ~= curl_files[2],
                    true,
                    'first two requests should not share body files'
                )
                helpers.expect_equal(
                    curl_files[2] ~= curl_files[3],
                    true,
                    'last two requests should not share body files'
                )
                helpers.expect_equal(callbacks[#callbacks].done, true, 'final callback should be marked done')
            end)

            restore()

            if not ok then
                error(err, 0)
            end
        end,
    },
}
