local M = {}
local utils = require 'minuet.utils'

-- Currently running completion jobs, basically forked curl processes.
M.current_jobs = {}

---@param job vim.SystemObj
function M.register_job(job)
    table.insert(M.current_jobs, job)
    utils.notify('Registered completion job', 'debug')
end

---@param job vim.SystemObj
function M.remove_job(job)
    for i, j in ipairs(M.current_jobs) do
        if j.pid == job.pid then
            table.remove(M.current_jobs, i)
            utils.notify('Completion job ' .. job.pid .. ' finished and removed from current_jobs', 'debug')
            break
        end
    end
end

---@param job vim.SystemObj
local function terminate_job(job)
    local ok = pcall(job.kill, job, 'sigterm')
    if not ok then
        utils.notify('Failed to terminate completion job ' .. job.pid, 'warn', vim.log.levels.WARN)
        return false
    end

    utils.notify('Terminate completion job ' .. job.pid, 'debug')

    return true
end

function M.terminate_all_jobs()
    for _, job in ipairs(M.current_jobs) do
        terminate_job(job)
    end

    M.current_jobs = {}
end

---@class minuet.JobHandlers
---@field on_exit fun(job: vim.SystemObj, result: vim.SystemCompleted)
---@field on_spawn_error? fun()
---@field on_stdout? fun(chunk: string) incremental stdout, delivered on the main loop; result.stdout still carries the full output on exit

---@param command string
---@param args string[]
---@param handlers minuet.JobHandlers
---@return vim.SystemObj?
function M.start_job(command, args, handlers)
    local cmd = { command }
    vim.list_extend(cmd, args)

    ---@type vim.SystemObj?
    local job

    local opts = { text = true }
    local stdout_chunks
    if handlers.on_stdout then
        -- A custom stdout handler stops vim.system from collecting the output
        -- itself, so accumulate the chunks and hand the assembled result to
        -- on_exit. vim.schedule preserves delivery order, and the exit callback
        -- is queued after the last chunk, so on_exit still sees everything.
        stdout_chunks = {}
        opts.stdout = function(err, chunk)
            if err or chunk == nil then
                return
            end
            table.insert(stdout_chunks, chunk)
            vim.schedule(function()
                handlers.on_stdout(chunk)
            end)
        end
    end

    local ok, result = pcall(
        vim.system,
        cmd,
        opts,
        vim.schedule_wrap(function(out)
            if not job then
                return
            end

            if stdout_chunks then
                -- The text=true CRLF translation only applies to collected
                -- output; mirror it for the assembled stream.
                out.stdout = table.concat(stdout_chunks):gsub('\r\n', '\n')
            end

            M.remove_job(job)
            handlers.on_exit(job, out)
        end)
    )

    if not ok then
        utils.notify('Failed to start completion job: ' .. result, 'error', vim.log.levels.ERROR)
        if handlers.on_spawn_error then
            handlers.on_spawn_error()
        end
        return nil
    end

    job = result
    M.register_job(job)

    return job
end

---@param items_raw string?
---@param provider string
---@return table<string>
function M.parse_completion_items(items_raw, provider)
    local success, items_table = pcall(vim.split, items_raw, '<endCompletion>')
    if not success then
        utils.notify('Failed to parse ' .. provider .. "'s content text", 'error', vim.log.levels.INFO)
        return {}
    end

    return items_table
end

---@param items table
---@param context table
---@param cfg? table Effective config (defaults to global), threaded to filter_text.
function M.filter_context_sequences_in_items(items, context, cfg)
    items = vim.tbl_map(function(x)
        return utils.filter_text(x, context, cfg)
    end, items)

    return items
end

---@param str_list string[]
---@return table
function M.create_chat_messages_from_list(str_list)
    local result = {}
    local roles = { 'user', 'assistant' }
    for i, content in ipairs(str_list) do
        table.insert(result, { role = roles[(i - 1) % 2 + 1], content = content })
    end
    return result
end

---@param transform fun(data: { end_point: string, headers: table, body: table })[]?
---@param end_point string
---@param headers table
---@param body table
---@return { end_point: string, headers: table, body: table }
function M.apply_transforms(transform, end_point, headers, body)
    local transformed_data = {
        end_point = end_point,
        headers = headers,
        body = body,
    }

    for _, fun in ipairs(transform or {}) do
        transformed_data = fun(transformed_data)
    end

    return transformed_data
end

return M
