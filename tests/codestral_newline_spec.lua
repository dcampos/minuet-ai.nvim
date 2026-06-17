local helpers = require 'tests.helpers'

-- Drive one FIM request through the shared base and return the items handed to
-- the paint callback. The decoded completion is fixed via a stubbed decoder.
local function run_fim(opts)
    local root = helpers.setup_root_config(vim.tbl_extend('force', {
        n_completions = 1,
        request_timeout = 1,
        curl_extra_args = {},
        fim_filter_context = false,
    }, opts.config or {}))

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

    local captured
    local ok, err = pcall(function()
        utils.make_tmp_file = function()
            return '/tmp/minuet-codestral-nl.json'
        end
        utils.make_curl_args = function(_, _, data_file)
            return { '-d', '@' .. data_file }
        end
        utils.stream_decode = function()
            return opts.completion
        end
        common.terminate_all_jobs = function() end
        common.start_job = function(_, _, handlers)
            handlers.on_exit({ pid = 1 }, { code = 0, stdout = '' })
            return { pid = 1 }
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
            strip_spurious_leading_newline = opts.strip,
            template = {
                prompt = function(before)
                    return before
                end,
                suffix = function(_, after)
                    return after
                end,
            },
        }

        base.complete_openai_fim_base(options, function(json)
            return json.choices[1].delta.content
        end, {
            lines_before = opts.before,
            lines_after = opts.after,
            opts = {},
        }, function(items)
            captured = items
        end, root.config)
    end)

    restore()
    if not ok then
        error(err, 0)
    end
    return captured
end

return {
    {
        name = 'strip_codestral_spurious_newline removes one leading newline only on empty/newline suffix at a fresh line',
        run = function()
            helpers.ensure_runtime()
            local utils = helpers.reload 'minuet.utils'
            local strip = utils.strip_codestral_spurious_newline

            -- prefix ends in '\n' and suffix carries no real content -> strip one
            helpers.expect_equal(strip('\nfoo', 'a\n', ''), 'foo', 'empty suffix strips')
            helpers.expect_equal(strip('\nfoo', 'a\n', nil), 'foo', 'nil suffix strips')
            helpers.expect_equal(strip('\nfoo', 'a\n', '\n\n'), 'foo', 'all-newline suffix strips')
            helpers.expect_equal(strip('\n\nfoo', 'a\n', ''), '\nfoo', 'strips exactly one newline')

            -- left untouched outside the quirk window
            helpers.expect_equal(strip('\nfoo', 'a\n', 'x'), '\nfoo', 'content suffix is left alone')
            helpers.expect_equal(strip('\nfoo', 'a\n', '\n\nx'), '\nfoo', 'content anywhere in suffix is left alone')
            helpers.expect_equal(strip('\nfoo', 'a', ''), '\nfoo', 'prefix not ending in newline is left alone')
            helpers.expect_equal(strip('foo', 'a\n', ''), 'foo', 'no leading newline is a no-op')
            helpers.expect_equal(strip(nil, 'a\n', ''), nil, 'nil completion is a no-op')
        end,
    },
    {
        name = 'codestral FIM base strips the spurious leading newline when enabled',
        run = function()
            local items = run_fim {
                strip = true,
                completion = '\nx_0 sale de la base.',
                before = 'por lo que\n', -- cursor at the start of a fresh line
                after = '', -- empty suffix
            }
            helpers.expect_equal(items[1], 'x_0 sale de la base.', 'leading newline stripped')
        end,
    },
    {
        name = 'codestral FIM base keeps the newline when the suffix has real content',
        run = function()
            local items = run_fim {
                strip = true,
                completion = '\nx_0 sale de la base.',
                before = 'por lo que\n',
                after = 'siguiente parrafo.',
            }
            helpers.expect_equal(items[1], '\nx_0 sale de la base.', 'content suffix leaves the newline')
        end,
    },
    {
        name = 'FIM base leaves the completion untouched when the fix is disabled',
        run = function()
            local items = run_fim {
                strip = false, -- e.g. another FIM provider, or flag turned off
                completion = '\nx_0 sale de la base.',
                before = 'por lo que\n',
                after = '',
            }
            helpers.expect_equal(items[1], '\nx_0 sale de la base.', 'disabled means no stripping')
        end,
    },
}
