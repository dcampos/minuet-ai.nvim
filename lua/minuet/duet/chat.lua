-- Non-streaming OpenAI-compatible chat-completions request for duet NES.
-- Sends a message list + tools, returns the parsed assistant message (with
-- tool_calls / content / reasoning) via callback. Tool-call shape validated
-- live against gpt-oss-120b on OpenRouter.

local common = require 'minuet.duet.backends.common'
local utils = require 'minuet.duet.utils'

local M = {}

---@param messages table[]
---@param tools table[]
---@param callback fun(result: { message?: table, error?: string })
function M.request(messages, tools, callback)
    local root = require('minuet').config
    local duet = root.duet
    local provider = duet.provider
    local opts = duet.provider_options[provider]

    if not opts then
        callback { error = 'duet provider has no provider_options: ' .. tostring(provider) }
        return
    end

    local api_key = utils.get_api_key(opts.api_key)
    if not api_key then
        callback { error = 'duet API key is not set (env ' .. tostring(opts.api_key) .. ')' }
        return
    end

    local body = {
        model = opts.model,
        messages = messages,
        tools = tools,
        tool_choice = 'auto',
        stream = false,
    }
    body = vim.tbl_deep_extend('force', body, opts.optional or {})

    local headers = {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. api_key,
    }

    -- make_tmp_file json-encodes the table itself; pass the table, not a string.
    local data_file = utils.make_tmp_file(body)
    if not data_file then
        callback { error = 'failed to write request temp file' }
        return
    end

    local args = utils.make_curl_args(opts.end_point, headers, data_file, duet.request_timeout)

    common.start_job(root.curl_cmd, args, {
        on_exit = function(_, out)
            pcall(os.remove, data_file)
            if out.code ~= 0 then
                callback { error = ('curl exited %s: %s'):format(tostring(out.code), tostring(out.stderr or '')) }
                return
            end
            local ok, decoded = pcall(vim.json.decode, out.stdout or '')
            if not ok or type(decoded) ~= 'table' then
                callback { error = 'failed to decode response: ' .. tostring((out.stdout or ''):sub(1, 200)) }
                return
            end
            if decoded.error then
                callback { error = 'API error: ' .. vim.inspect(decoded.error) }
                return
            end
            local choice = decoded.choices and decoded.choices[1]
            local message = choice and choice.message
            if not message then
                callback { error = 'no message in response: ' .. tostring((out.stdout or ''):sub(1, 200)) }
                return
            end
            callback { message = message }
        end,
        on_spawn_error = function()
            pcall(os.remove, data_file)
            callback { error = 'failed to spawn curl' }
        end,
    })
end

return M
