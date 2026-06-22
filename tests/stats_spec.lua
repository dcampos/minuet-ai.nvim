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
        name = 'stats buckets each request into a cache-hit band by cached/input ratio',
        run = function()
            stats.reset()
            rec(1000, 0, 5) -- cold       (0%)
            rec(1000, 400, 5) -- 25-50%   (40%)
            rec(1000, 700, 5) -- 50-75%   (70%)
            rec(1000, 1000, 5) -- exact   (100%)

            local text, win = dashboard()
            -- One request in cold, one in 25-50, one in 50-75, one exact.
            helpers.expect_match(text, 'cold%s+[█▏▎▍▌▋▊▉░]+%s+1')
            helpers.expect_match(text, '100%%%s+[█▏▎▍▌▋▊▉░]+%s+1')
            -- 1 of 4 rated requests is a literal-exact reuse.
            helpers.expect_match(text, 'exact 100%% reuse: 1 req %(25%%%)')

            vim.api.nvim_win_close(win, true)
            stats.reset()
        end,
    },
    {
        name = 'stats counts unreported requests as no-data, never as cold',
        run = function()
            stats.reset()
            rec(1000, 750, 5) -- server reported a real cache hit (75%)
            -- Two responses with a usage block but NO cache field at all: this is
            -- "no data", which must not be scored as a cold miss.
            local nodata = { prompt_tokens = 1000, completion_tokens = 5 }
            rec(nil, nil, 5, nodata)
            rec(nil, nil, 5, nodata)

            local text, win = dashboard()
            local bars = '[█▏▎▍▌▋▊▉░]+'
            -- Headline is weighted over reported tokens only: 750/1000 = 75%, not
            -- diluted to 750/3000 = 25% by the two unreported requests.
            helpers.expect_match(text, 'prompt tokens from cache%s+' .. bars .. '%s+75%%')
            helpers.expect_match(text, 'reported cache for 1 of 3 requests')
            -- The reported request is a hit, so cold stays empty; the two
            -- unreported land in their own no-data tally.
            helpers.expect_match(text, 'cold%s+' .. bars .. '%s+0')
            helpers.expect_match(text, 'no server data: 2 req')

            vim.api.nvim_win_close(win, true)
            stats.reset()
        end,
    },
    {
        name = 'stats classifies snap-back / pinned / slid and counts server-warm reuse',
        run = function()
            stats.reset()
            local function recd(anchored, would_slide, cached)
                stats.record {
                    name = 'Codestral',
                    model = 'codestral-2508',
                    elapsed_ms = 200,
                    anchored = anchored,
                    would_slide = would_slide,
                    response = vim.json.encode {
                        usage = {
                            prompt_tokens = 1000,
                            completion_tokens = 5,
                            prompt_tokens_details = { cached_tokens = cached },
                        },
                    },
                }
            end
            recd(true, false, 800) -- snap-back, server warm
            recd(true, false, 0) -- snap-back, server cold (expected reuse, missed)
            recd(false, false, 700) -- pinned, server warm
            recd(false, true, 0) -- slid, server cold (expected miss)

            local text, win = dashboard()
            helpers.expect_match(text, 'prefix KV reuse')
            local bars = '[█▏▎▍▌▋▊▉░]+'
            helpers.expect_match(text, 'snap%-back%s+' .. bars .. '%s+50%%%s+2 fired')
            helpers.expect_match(text, '2 fired · 1 cold')
            helpers.expect_match(text, 'pinned%s+' .. bars .. '%s+100%%%s+1')
            helpers.expect_match(text, 'slid%s+' .. bars .. '%s+0%%%s+1')

            vim.api.nvim_win_close(win, true)
            stats.reset()
        end,
    },
    {
        name = 'stats persists a numbers-only JSONL with no request/response bodies',
        run = function()
            stats.reset()
            local path = vim.fn.tempname() .. '.jsonl'
            local minuet = require 'minuet'
            minuet.config = minuet.config or {}
            local saved = minuet.config.stats_log
            minuet.config.stats_log = path

            stats.record {
                name = 'Codestral',
                model = 'codestral-2508',
                elapsed_ms = 321,
                anchored = true,
                would_slide = false,
                response = vim.json.encode {
                    choices = { { text = 'SECRET_SOURCE_abc' } },
                    usage = {
                        prompt_tokens = 300,
                        completion_tokens = 5,
                        prompt_tokens_details = { cached_tokens = 100 },
                    },
                },
            }

            local f = assert(io.open(path, 'r'))
            local body = f:read '*a'
            f:close()
            helpers.expect_falsy(body:find('SECRET_SOURCE', 1, true), 'no response/source text in the stats log')

            local rec = vim.json.decode(vim.split(vim.trim(body), '\n')[1])
            helpers.expect_equal(rec.input, 300)
            helpers.expect_equal(rec.cached, 100)
            helpers.expect_equal(rec.output, 5)
            helpers.expect_equal(rec.model, 'codestral-2508')
            helpers.expect_equal(rec.disposition, 'snap')
            helpers.expect_match(rec.ts, '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%d$')

            minuet.config.stats_log = saved
            os.remove(path)
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
