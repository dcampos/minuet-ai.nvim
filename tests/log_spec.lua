local helpers = require 'tests.helpers'

local function read_lines(path)
    local f = assert(io.open(path, 'r'))
    local lines = {}
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()
    return lines
end

return {
    {
        name = 'request log is disabled by default and records nothing',
        run = function()
            helpers.setup_root_config { request_log = false }
            local log = helpers.reload 'minuet.log'

            helpers.expect_falsy(log.enabled(), 'log should be disabled when request_log is false')
            -- record must be a silent no-op, never raising
            log.record { kind = 'fim', provider = 'codestral', response = '{}' }
        end,
    },
    {
        name = 'request log writes one JSONL record with timing and request body',
        run = function()
            local path = vim.fn.tempname() .. '.jsonl'
            helpers.setup_root_config { request_log = path }
            local log = helpers.reload 'minuet.log'

            helpers.expect_truthy(log.enabled(), 'log should be enabled for a path')

            log.record {
                kind = 'fim',
                provider = 'openai_fim_compatible',
                name = 'Codestral',
                model = 'codestral-latest',
                endpoint = 'https://api.example/completions',
                request = { model = 'codestral-latest', prompt = 'p', suffix = 's' },
                response = vim.json.encode { choices = { { text = 'x' } } },
                code = 0,
                started = log.start(),
                request_idx = 1,
                n_requests = 3,
            }

            local lines = read_lines(path)
            helpers.expect_equal(#lines, 1, 'one line written')
            local rec = vim.json.decode(lines[1])
            helpers.expect_equal(rec.kind, 'fim')
            helpers.expect_equal(rec.request.prompt, 'p')
            helpers.expect_truthy(rec.elapsed_ms ~= nil, 'elapsed_ms is set from started token')
            helpers.expect_truthy(rec.started == nil, 'started token is stripped from output')
            helpers.expect_match(rec.ts, '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%d$')
            os.remove(path)
        end,
    },
    {
        name = 'request log extracts KV-cache usage from non-streamed and streamed responses',
        run = function()
            local path = vim.fn.tempname() .. '.jsonl'
            helpers.setup_root_config { request_log = path }
            local log = helpers.reload 'minuet.log'

            -- non-streamed body: usage at top level
            log.record {
                kind = 'duet_chat',
                provider = 'openrouter',
                response = vim.json.encode {
                    choices = { { message = { content = 'hi' } } },
                    usage = { prompt_tokens = 1200, prompt_tokens_details = { cached_tokens = 1024 } },
                },
                started = log.start(),
            }

            -- streamed body: usage only in the final chunk
            local stream = table.concat({
                'data: ' .. vim.json.encode { choices = { { delta = { content = 'a' } } } },
                'data: ' .. vim.json.encode {
                    choices = { { delta = { content = 'b' } } },
                    usage = { prompt_tokens = 800, prompt_tokens_details = { cached_tokens = 640 } },
                },
                'data: [DONE]',
            }, '\n')
            log.record { kind = 'fim', provider = 'codestral', response = stream, started = log.start() }

            -- curl failure: no body, no usage
            log.record { kind = 'fim', provider = 'codestral', response = '', code = 28, stderr = 'timeout' }

            local lines = read_lines(path)
            helpers.expect_equal(#lines, 3, 'three lines written')

            local nonstream = vim.json.decode(lines[1])
            helpers.expect_equal(nonstream.usage.prompt_tokens_details.cached_tokens, 1024)

            local streamed = vim.json.decode(lines[2])
            helpers.expect_equal(streamed.usage.prompt_tokens_details.cached_tokens, 640)

            local failed = vim.json.decode(lines[3])
            helpers.expect_equal(failed.code, 28)
            helpers.expect_truthy(failed.usage == nil, 'no usage on an empty/failed response')
            os.remove(path)
        end,
    },
}
