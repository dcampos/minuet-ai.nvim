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
    {
        name = 'openai FIM backend keeps in-flight jobs when context opts request it',
        run = function()
            local root = helpers.setup_root_config {
                n_completions = 1,
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

            local function restore()
                utils.make_tmp_file = original_make_tmp_file
                utils.make_curl_args = original_make_curl_args
                utils.stream_decode = original_stream_decode
                common.start_job = original_start_job
                common.terminate_all_jobs = original_terminate_all_jobs
            end

            local ok, err = pcall(function()
                utils.make_tmp_file = function()
                    return '/tmp/minuet-fim-keepjobs.json'
                end
                utils.make_curl_args = function(_, _, data_file)
                    return { '-d', '@' .. data_file }
                end
                utils.stream_decode = function()
                    return 'completion'
                end
                common.start_job = function(_, _, handlers)
                    handlers.on_exit({ pid = 1 }, { code = 0, stdout = '' })
                    return { pid = 1 }
                end

                local terminate_calls = 0
                common.terminate_all_jobs = function()
                    terminate_calls = terminate_calls + 1
                end

                local options = {
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
                }
                local get_text_fn = function(json)
                    return json.choices[1].delta.content
                end

                base.complete_openai_fim_base(options, get_text_fn, {
                    lines_before = 'x',
                    lines_after = 'y',
                    opts = { keep_existing_jobs = true },
                }, function() end, root.config)
                helpers.expect_equal(terminate_calls, 0, 'keep_existing_jobs must skip cancelling in-flight jobs')

                base.complete_openai_fim_base(options, get_text_fn, {
                    lines_before = 'x',
                    lines_after = 'y',
                    opts = {},
                }, function() end, root.config)
                helpers.expect_equal(terminate_calls, 1, 'without the flag the backend cancels the previous request')
            end)

            restore()

            if not ok then
                error(err, 0)
            end
        end,
    },
    {
        name = 'openai FIM backend shows the first-sent request ahead of a later one within the grace',
        run = function()
            local root = helpers.setup_root_config {
                n_completions = 2,
                request_timeout = 1,
                curl_extra_args = {},
                fim_filter_context = false,
                first_request_grace_ms = 10000,
            }

            local base = helpers.reload 'minuet.backends.openai_base'
            local common = require 'minuet.backends.common'
            local utils = require 'minuet.utils'

            local saved = {
                make_tmp_file = utils.make_tmp_file,
                make_curl_args = utils.make_curl_args,
                stream_decode = utils.stream_decode,
                start_job = common.start_job,
                terminate = common.terminate_all_jobs,
            }
            local function restore()
                utils.make_tmp_file = saved.make_tmp_file
                utils.make_curl_args = saved.make_curl_args
                utils.stream_decode = saved.stream_decode
                common.start_job = saved.start_job
                common.terminate_all_jobs = saved.terminate
            end

            local ok, err = pcall(function()
                local n = 0
                utils.make_tmp_file = function()
                    n = n + 1
                    return '/tmp/fim-' .. n
                end
                utils.make_curl_args = function(_, _, data_file)
                    return { '-d', '@' .. data_file }
                end
                -- Tag each completion with its request number (its body file).
                utils.stream_decode = function(_, data_file)
                    return 'comp-' .. data_file:match '(%d+)'
                end
                common.terminate_all_jobs = function() end
                local jobs = {}
                common.start_job = function(_, _, handlers)
                    table.insert(jobs, handlers)
                    return { pid = #jobs }
                end

                local options = {
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
                }
                local get_text_fn = function(json)
                    return json.choices[1].delta.content
                end

                local callbacks = {}
                base.complete_openai_fim_base(options, get_text_fn, {
                    lines_before = 'x',
                    lines_after = 'y',
                    opts = {},
                }, function(items, done)
                    table.insert(callbacks, { items = items, done = done })
                end, root.config)

                helpers.expect_equal(#jobs, 2, 'two parallel requests started')

                -- Request #2 settles first; with #1 still pending it is held.
                jobs[2].on_exit({ pid = 2 }, { code = 0, stdout = '' })
                helpers.expect_equal(#callbacks, 0, 'a later-sent request alone does not paint during the grace')

                -- Request #1 settles within the grace -> a single paint, #1 first.
                jobs[1].on_exit({ pid = 1 }, { code = 0, stdout = '' })
                helpers.expect_equal(#callbacks, 1, 'painted once #1 arrives')
                helpers.expect_equal(callbacks[1].items[1], 'comp-1', 'first-sent request is shown first')
                helpers.expect_equal(callbacks[1].items[2], 'comp-2')
                helpers.expect_equal(callbacks[1].done, true)
            end)

            restore()

            if not ok then
                error(err, 0)
            end
        end,
    },
    {
        name = 'openai FIM backend paints request #1 immediately without waiting on the grace or #2',
        run = function()
            local root = helpers.setup_root_config {
                n_completions = 2,
                request_timeout = 1,
                curl_extra_args = {},
                fim_filter_context = false,
                -- A huge grace: if we wrongly waited, the paint would not happen.
                first_request_grace_ms = 100000,
            }

            local base = helpers.reload 'minuet.backends.openai_base'
            local common = require 'minuet.backends.common'
            local utils = require 'minuet.utils'

            local saved = {
                make_tmp_file = utils.make_tmp_file,
                make_curl_args = utils.make_curl_args,
                stream_decode = utils.stream_decode,
                start_job = common.start_job,
                terminate = common.terminate_all_jobs,
            }
            local function restore()
                utils.make_tmp_file = saved.make_tmp_file
                utils.make_curl_args = saved.make_curl_args
                utils.stream_decode = saved.stream_decode
                common.start_job = saved.start_job
                common.terminate_all_jobs = saved.terminate
            end

            local ok, err = pcall(function()
                local n = 0
                utils.make_tmp_file = function()
                    n = n + 1
                    return '/tmp/fim-' .. n
                end
                utils.make_curl_args = function(_, _, data_file)
                    return { '-d', '@' .. data_file }
                end
                utils.stream_decode = function(_, data_file)
                    return 'comp-' .. data_file:match '(%d+)'
                end
                common.terminate_all_jobs = function() end
                local jobs = {}
                common.start_job = function(_, _, handlers)
                    table.insert(jobs, handlers)
                    return { pid = #jobs }
                end

                local options = {
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
                }
                local get_text_fn = function(json)
                    return json.choices[1].delta.content
                end

                local callbacks = {}
                base.complete_openai_fim_base(options, get_text_fn, {
                    lines_before = 'x',
                    lines_after = 'y',
                    opts = {},
                }, function(items, done)
                    table.insert(callbacks, { items = items, done = done })
                end, root.config)

                -- Request #1 settles first: painted synchronously, right now,
                -- without waiting for the grace or for request #2.
                jobs[1].on_exit({ pid = 1 }, { code = 0, stdout = '' })
                helpers.expect_equal(#callbacks, 1, 'request #1 paints immediately, no grace wait')
                helpers.expect_equal(callbacks[1].items[1], 'comp-1')
                helpers.expect_equal(callbacks[1].done, false, 'not done yet -- #2 is still in flight')
            end)

            restore()

            if not ok then
                error(err, 0)
            end
        end,
    },
    {
        name = 'openai FIM backend paints a later request after the grace, then #1 jumps to the front',
        run = function()
            local root = helpers.setup_root_config {
                n_completions = 2,
                request_timeout = 1,
                curl_extra_args = {},
                fim_filter_context = false,
                first_request_grace_ms = 20,
            }

            local base = helpers.reload 'minuet.backends.openai_base'
            local common = require 'minuet.backends.common'
            local utils = require 'minuet.utils'

            local saved = {
                make_tmp_file = utils.make_tmp_file,
                make_curl_args = utils.make_curl_args,
                stream_decode = utils.stream_decode,
                start_job = common.start_job,
                terminate = common.terminate_all_jobs,
            }
            local function restore()
                utils.make_tmp_file = saved.make_tmp_file
                utils.make_curl_args = saved.make_curl_args
                utils.stream_decode = saved.stream_decode
                common.start_job = saved.start_job
                common.terminate_all_jobs = saved.terminate
            end

            local ok, err = pcall(function()
                local n = 0
                utils.make_tmp_file = function()
                    n = n + 1
                    return '/tmp/fim-' .. n
                end
                utils.make_curl_args = function(_, _, data_file)
                    return { '-d', '@' .. data_file }
                end
                utils.stream_decode = function(_, data_file)
                    return 'comp-' .. data_file:match '(%d+)'
                end
                common.terminate_all_jobs = function() end
                local jobs = {}
                common.start_job = function(_, _, handlers)
                    table.insert(jobs, handlers)
                    return { pid = #jobs }
                end

                local options = {
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
                }
                local get_text_fn = function(json)
                    return json.choices[1].delta.content
                end

                local callbacks = {}
                base.complete_openai_fim_base(options, get_text_fn, {
                    lines_before = 'x',
                    lines_after = 'y',
                    opts = {},
                }, function(items, done)
                    table.insert(callbacks, { items = items, done = done })
                end, root.config)

                -- Request #2 settles first; #1 still pending so it is held.
                jobs[2].on_exit({ pid = 2 }, { code = 0, stdout = '' })
                helpers.expect_equal(#callbacks, 0, 'held synchronously during the grace')

                -- After the grace expires the later request is painted (not done).
                helpers.wait_until(function()
                    return #callbacks >= 1
                end, 1000, 'grace expiry should paint the later request')
                helpers.expect_equal(callbacks[#callbacks].items[1], 'comp-2', 'after grace, the later request shows')
                helpers.expect_equal(callbacks[#callbacks].done, false, 'not done while #1 is still pending')

                -- When #1 finally lands it jumps to the front.
                jobs[1].on_exit({ pid = 1 }, { code = 0, stdout = '' })
                helpers.expect_equal(callbacks[#callbacks].items[1], 'comp-1', '#1 jumps to the front when it lands')
                helpers.expect_equal(callbacks[#callbacks].done, true)
            end)

            restore()

            if not ok then
                error(err, 0)
            end
        end,
    },
    {
        -- A generation cut by the token limit (finish_reason == 'length') ends
        -- in a truncated line. When the caller walks completions line by line
        -- (context.opts.trim_incomplete_tail_line) that tail must be trimmed
        -- before the result is delivered; other callers keep the raw text.
        name = 'openai FIM backend trims the token-limit-truncated tail line when the context asks for it',
        run = function()
            local root = helpers.setup_root_config {
                n_completions = 1,
                request_timeout = 1,
                curl_extra_args = {},
                fim_filter_context = false,
            }

            local length_stdout = table.concat({
                'data: {"choices":[{"delta":{"content":"foo"},"finish_reason":null}]}',
                'data: {"choices":[{"delta":{"content":""},"finish_reason":"length"}]}',
                'data: [DONE]',
            }, '\n')
            local stop_stdout = table.concat({
                'data: {"choices":[{"delta":{"content":"foo"},"finish_reason":null}]}',
                'data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}]}',
                'data: [DONE]',
            }, '\n')

            local cases = {
                { trim = true, stdout = length_stdout, decoded = 'foo\nbar_trunc', expected = 'foo' },
                { trim = true, stdout = stop_stdout, decoded = 'foo\nbar', expected = 'foo\nbar' },
                { trim = false, stdout = length_stdout, decoded = 'foo\nbar_trunc', expected = 'foo\nbar_trunc' },
                -- Cut inside the first line: nothing complete remains.
                { trim = true, stdout = length_stdout, decoded = 'trunc_only', expected = nil },
            }

            local base = helpers.reload 'minuet.backends.openai_base'
            local common = require 'minuet.backends.common'
            local utils = require 'minuet.utils'

            local original_make_tmp_file = utils.make_tmp_file
            local original_make_curl_args = utils.make_curl_args
            local original_stream_decode = utils.stream_decode
            local original_start_job = common.start_job
            local original_terminate_all_jobs = common.terminate_all_jobs

            local function restore()
                utils.make_tmp_file = original_make_tmp_file
                utils.make_curl_args = original_make_curl_args
                utils.stream_decode = original_stream_decode
                common.start_job = original_start_job
                common.terminate_all_jobs = original_terminate_all_jobs
            end

            local ok, err = pcall(function()
                for i, case in ipairs(cases) do
                    utils.make_tmp_file = function()
                        return '/tmp/minuet-fim-trim-' .. i .. '.json'
                    end
                    utils.make_curl_args = function(_, _, data_file)
                        return { '-d', '@' .. data_file }
                    end
                    utils.stream_decode = function()
                        return case.decoded
                    end
                    common.terminate_all_jobs = function() end
                    common.start_job = function(_, _, handlers)
                        local job = { pid = i }
                        handlers.on_exit(job, { code = 0, stdout = case.stdout })
                        return job
                    end

                    local received
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
                        lines_before = 'x = ',
                        lines_after = '',
                        opts = { trim_incomplete_tail_line = case.trim },
                    }, function(items)
                        received = items
                    end, root.config)

                    helpers.expect_equal(
                        received[1],
                        case.expected,
                        ('case %d: trim=%s finish=%s'):format(i, tostring(case.trim), case.stdout:match '"finish_reason":"(%w+)"')
                    )
                end
            end)

            restore()

            if not ok then
                error(err, 0)
            end
        end,
    },
}
