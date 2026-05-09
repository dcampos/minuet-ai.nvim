local base = require 'minuet.backends.openai_base'
local utils = require 'minuet.utils'

local M = {}

M.is_available = function()
    local config = require('minuet').config
    return utils.get_api_key(config.provider_options.openai.api_key) and true or false
end

if not M.is_available() then
    utils.notify('OpenAI API key is not set', 'error', vim.log.levels.ERROR)
end

---@param context table
---@param callback function
---@param cfg? table Effective config (defaults to global). Pass to override
---provider_options.openai (model, max_tokens, optional, ...) per call.
M.complete = function(context, callback, cfg)
    local config = cfg or require('minuet').config
    local options = vim.deepcopy(config.provider_options.openai)
    options.name = 'OpenAI'

    base.complete_openai_base(options, context, callback, config)
end

return M
