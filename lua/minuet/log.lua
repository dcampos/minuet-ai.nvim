-- Request/response logger for minuet completions.
--
-- One JSON object per line (JSONL) so the log is greppable with jq. The HTTP
-- itself runs in a forked curl process (see backends/common.start_job), so the
-- only main-thread cost here is a small synchronous append in the curl on_exit
-- callback, which is off the keystroke hot path. Logging must never break a
-- completion, so every write is wrapped: failures are swallowed silently.
--
-- Enabled via the top-level `request_log` config option:
--   false / nil  -> disabled (default)
--   true         -> default path stdpath('cache')/minuet/requests.jsonl
--   "<path>"     -> that file
--
-- The request body is logged verbatim; the Authorization header is never
-- passed in, so API keys stay out of the log.

local M = {}

-- Cached append handle, reopened when the configured path changes.
---@type { path: string, handle: file*? }?
local sink

---@return string? path resolved log path, or nil when disabled
local function resolve_path()
    local opt = require('minuet').config.request_log
    if not opt then
        return nil
    end
    if opt == true then
        return vim.fs.joinpath(vim.fn.stdpath 'cache', 'minuet', 'requests.jsonl')
    end
    if type(opt) == 'string' and opt ~= '' then
        return opt
    end
    return nil
end

---@param path string
---@return file*?
local function open_sink(path)
    if sink and sink.path == path then
        return sink.handle
    end
    if sink and sink.handle then
        pcall(function() sink.handle:close() end)
    end
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local handle = io.open(path, 'a')
    sink = { path = path, handle = handle }
    return handle
end

--- Wall-clock timestamp with millisecond precision (local time, no timezone).
---@return string
local function now_ms()
    local s, us = vim.uv.gettimeofday()
    return os.date('%Y-%m-%dT%H:%M:%S', s) .. string.format('.%03d', math.floor((us or 0) / 1000))
end

--- Pull the `usage` block out of a response so KV-cache accounting is directly
--- queryable (this is where servers report cache hits: OpenAI/OpenRouter
--- `prompt_tokens_details.cached_tokens`, DeepSeek `prompt_cache_hit_tokens`,
--- Mistral cache fields, etc.). Handles both a single non-streamed JSON body
--- and an SSE stream (returns the last chunk that carries usage, which is where
--- `stream_options.include_usage` puts the totals).
---@param response string?
---@return table? usage
local function extract_usage(response)
    if type(response) ~= 'string' or response == '' then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, response)
    if ok and type(decoded) == 'table' and type(decoded.usage) == 'table' then
        return decoded.usage
    end
    local usage
    for _, line in ipairs(vim.split(response, '\n', { plain = true })) do
        line = line:gsub('^data:%s*', '')
        local chunk_ok, chunk = pcall(vim.json.decode, line)
        if chunk_ok and type(chunk) == 'table' and type(chunk.usage) == 'table' then
            usage = chunk.usage
        end
    end
    return usage
end

--- Public wrapper around the usage extractor so other modules (e.g. the stats
--- dashboard) can pull token/cache accounting out of a raw response.
---@param response string?
---@return table? usage
function M.extract_usage(response)
    return extract_usage(response)
end

---@return boolean
function M.enabled()
    return resolve_path() ~= nil
end

--- Current resolved log path, or nil when disabled.
---@return string?
function M.path()
    return resolve_path()
end

-- Remembers a configured string path across disable/enable so the :Minuet log
-- toggle does not forget a custom location set in the user's config.
---@type string?
local preferred_path

--- Turn request logging on at runtime. With no argument, restores a previously
--- configured string path or falls back to the default cache path.
---@param path? string explicit log file path
---@return string? path the now-active log path
function M.enable(path)
    local config = require('minuet').config
    if type(path) == 'string' and path ~= '' then
        config.request_log = path
    elseif not config.request_log then
        config.request_log = preferred_path or true
    end
    return resolve_path()
end

--- Turn request logging off at runtime, remembering a custom path for re-enable.
function M.disable()
    local config = require('minuet').config
    if type(config.request_log) == 'string' then
        preferred_path = config.request_log
    end
    config.request_log = false
end

--- Flip request logging. Returns the active path when it ends up enabled, nil
--- when it ends up disabled.
---@return string?
function M.toggle()
    if resolve_path() then
        M.disable()
        return nil
    end
    return M.enable()
end

--- Monotonic start token to hand back to M.record as `started`.
---@return integer
function M.start()
    return vim.uv.hrtime()
end

---@class minuet.LogEntry
---@field kind string 'fim' | 'duet_chat' | 'duet_inception'
---@field provider string
---@field name? string sub-provider name (e.g. 'Codestral')
---@field model? string
---@field endpoint? string
---@field request? table the request body (no auth header)
---@field response? string raw response stdout
---@field code? integer curl exit code
---@field stderr? string
---@field started? integer hrtime token from M.start(); becomes elapsed_ms
---@field request_idx? integer
---@field n_requests? integer
---@field ts? string set by M.record (wall-clock, ms precision)
---@field elapsed_ms? number set by M.record from `started`
---@field usage? table token/cache accounting, extracted from response if absent

--- Append one record. Computes ts/elapsed_ms and never raises.
---@param entry minuet.LogEntry
function M.record(entry)
    local path = resolve_path()
    if not path then
        return
    end
    pcall(function()
        local handle = open_sink(path)
        if not handle then
            return
        end
        if entry.started then
            entry.elapsed_ms = (vim.uv.hrtime() - entry.started) / 1e6
            entry.started = nil
        end
        if entry.usage == nil then
            entry.usage = extract_usage(entry.response)
        end
        entry.ts = now_ms()
        handle:write(vim.json.encode(entry) .. '\n')
        handle:flush()
    end)
end

return M
