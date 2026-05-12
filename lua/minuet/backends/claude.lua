local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'

local M = {}

M.is_available = function()
    local config = require('minuet').config
    return utils.get_api_key(config.provider_options.claude.api_key) and true or false
end

if not M.is_available() then
    utils.notify('Anthropic API key is not set', 'error', vim.log.levels.ERROR)
end

local function make_request_data(cfg)
    local config = cfg or require('minuet').config
    local options = vim.deepcopy(config.provider_options.claude)
    local system = utils.make_system_prompt(options.system, config.n_completions)

    local request_data = {
        system = system,
        max_tokens = options.max_tokens,
        model = options.model,
        stream = options.stream,
    }

    request_data = vim.tbl_deep_extend('force', request_data, options.optional or {})

    return options, request_data
end

function M.get_text_fn_no_steam(json)
    return json.content[1].text
end

function M.get_text_fn_stream(json)
    return json.delta.text
end

---@param context table
---@param callback function
---@param cfg? table Effective config (defaults to global). Pass to override
---provider_options.claude per call.
M.complete = function(context, callback, cfg)
    local config = cfg or require('minuet').config
    common.terminate_all_jobs()

    local options, data = make_request_data(config)
    local ctx = utils.make_chat_llm_shot(context, options.chat_input)
    ctx = common.create_chat_messages_from_list(ctx)

    local few_shots = vim.deepcopy(utils.get_or_eval_value(options.few_shots))

    vim.list_extend(few_shots, ctx)

    data.messages = few_shots

    local headers = {
        ['Content-Type'] = 'application/json',
        ['x-api-key'] = utils.get_api_key(options.api_key),
        ['anthropic-version'] = '2023-06-01',
    }
    local transformed_data = common.apply_transforms(options.transform, options.end_point, headers, data)

    local data_file = utils.make_tmp_file(transformed_data.body)

    if data_file == nil then
        return
    end

    local args = utils.make_curl_args(transformed_data.end_point, transformed_data.headers, data_file, config)

    local provider_name = 'Claude'
    local timestamp = os.time()

    utils.run_event('MinuetRequestStartedPre', {
        provider = provider_name,
        name = provider_name,
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    local new_job = common.start_job(config.curl_cmd, args, {
        on_exit = function(_, result)
            utils.run_event('MinuetRequestFinished', {
                provider = provider_name,
                name = provider_name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            local items_raw

            if options.stream then
                items_raw = utils.stream_decode(result, data_file, provider_name, M.get_text_fn_stream)
            else
                items_raw = utils.no_stream_decode(result, data_file, provider_name, M.get_text_fn_no_steam)
            end

            if not items_raw then
                callback(nil, true)
                return
            end

            local items = common.parse_completion_items(items_raw, provider_name)

            items = common.filter_context_sequences_in_items(items, context, config)

            items = utils.remove_spaces(items)

            callback(items, true)
        end,
        on_spawn_error = function()
            os.remove(data_file)
            utils.run_event('MinuetRequestFinished', {
                provider = provider_name,
                name = provider_name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })
            callback(nil, true)
        end,
    })

    if not new_job then
        return
    end

    utils.run_event('MinuetRequestStarted', {
        provider = provider_name,
        name = options.name,
        model = options.model,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })
end

return M
