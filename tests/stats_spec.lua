local helpers = require 'tests.helpers'
local stats = require 'minuet.stats'

--- Open the dashboard, read it back, and return (text, win, modifiable).
local function dashboard()
    stats.show()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    return text, win, vim.bo[buf].modifiable
end

---@param input integer?
---@param cached integer?
---@param output integer?
---@param usage table? full usage override
local function rec(input, cached, output, usage)
    usage = usage or {
        prompt_tokens = input,
        completion_tokens = output or 10,
        prompt_tokens_details = { cached_tokens = cached },
    }
    stats.record {
        name = 'Codestral',
        model = 'codestral-2508',
        response = vim.json.encode { usage = usage },
        elapsed_ms = 200,
    }
end

return {
    {
        name = 'stats dashboard aggregates input/output/cached tokens',
        run = function()
            stats.reset()
            rec(300, 256, 12)
            rec(700, 640, 8)

            local text, win = dashboard()
            helpers.expect_match(text, 'requests%s+2')
            helpers.expect_match(text, 'input tokens%s+1,000')
            helpers.expect_match(text, 'cached 896')
            helpers.expect_match(text, 'output tokens%s+20')

            vim.api.nvim_win_close(win, true)
            stats.reset()
        end,
    },
    {
        name = 'stats counts deepseek-style prompt_cache_hit_tokens as cached',
        run = function()
            stats.reset()
            rec(nil, nil, 5, { prompt_tokens = 400, completion_tokens = 5, prompt_cache_hit_tokens = 384 })

            local text, win = dashboard()
            helpers.expect_match(text, 'cached 384')

            vim.api.nvim_win_close(win, true)
            stats.reset()
        end,
    },
    {
        name = 'stats clamps cached tokens to the input total',
        run = function()
            stats.reset()
            -- A bogusly large cached count must never exceed input.
            rec(200, 999, 3)

            local text, win = dashboard()
            helpers.expect_match(text, 'input tokens%s+200%s+%(cached 200%)')

            vim.api.nvim_win_close(win, true)
            stats.reset()
        end,
    },
    {
        name = 'stats dashboard buffer is read-only and shows an empty state',
        run = function()
            stats.reset()

            local text, win, modifiable = dashboard()
            helpers.expect_match(text, 'no completions recorded yet')
            helpers.expect_falsy(modifiable, 'the stats buffer must not be editable')

            vim.api.nvim_win_close(win, true)
        end,
    },
    {
        name = 'stats ignores responses without a usage block',
        run = function()
            stats.reset()
            stats.record { name = 'Codestral', response = '{"choices":[{"text":"x"}]}' }

            local text, win = dashboard()
            helpers.expect_match(text, 'no completions recorded yet')

            vim.api.nvim_win_close(win, true)
        end,
    },
}
