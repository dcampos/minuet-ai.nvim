-- In-memory token/cache accounting for FIM completions, plus a fancy floating
-- dashboard (:Minuet stats).
--
-- Every finished FIM request feeds M.record with its raw response; we pull the
-- usage block (prompt/completion/cached tokens) and keep a bounded ring of
-- per-request samples. Nothing is persisted -- this is a live look at the
-- current session, off the keystroke hot path (recording runs in curl's on_exit
-- callback). Recording never raises: a malformed response just yields no sample.
--
-- Scoped to FIM (openai_fim_compatible) for now, which is where the server-side
-- KV cache accounting that makes this interesting actually shows up.

local M = {}

local MAX_RECORDS = 2000

---@class minuet.StatSample
---@field name? string sub-provider name (e.g. 'Codestral')
---@field model? string
---@field input integer prompt tokens
---@field output integer completion tokens
---@field cached integer cached prompt tokens (server-side KV cache hit)
---@field elapsed_ms? number
---@field disposition? 'snap'|'pinned'|'slid' expected server-cache outcome at
---  fire time: 'snap' = reused a warm anchor (snap-back); 'pinned' = fresh
---  window whose prefix was already pinned at the buffer top (naturally warm);
---  'slid' = fresh window whose prefix slid, shedding its leading tokens -- a
---  basically-full KV miss. nil when the caller did not report it.
---@field ok boolean response decoded with a usage block
---@field ts integer os.time of the sample

---@type minuet.StatSample[]
local samples = {}

--- Wall-clock timestamp with millisecond precision (local time, no timezone),
--- matching minuet.log's structured-log format.
---@return string
local function now_ms()
    local s, us = vim.uv.gettimeofday()
    return os.date('%Y-%m-%dT%H:%M:%S', s) .. string.format('.%03d', math.floor((us or 0) / 1000))
end

--- Resolve the numbers-only stats log path from config.stats_log, or nil when
--- disabled (mirrors minuet.log's request_log resolution). Returns nil before
--- setup runs, so headless tests never touch the real cache dir by accident.
---@return string?
local function resolve_stats_path()
    local minuet = require 'minuet'
    local opt = minuet.config and minuet.config.stats_log
    if not opt then
        return nil
    end
    if opt == true then
        return vim.fs.joinpath(vim.fn.stdpath 'cache', 'minuet', 'stats.jsonl')
    end
    if type(opt) == 'string' and opt ~= '' then
        return opt
    end
    return nil
end

-- Cached append handle for the stats log, reopened when the path changes.
---@type { path: string, handle: file*? }?
local sink

--- Append one sample to the stats log as a compact JSON line. Numbers and
--- identifiers only -- never the prompt/suffix/response, so no source code ever
--- reaches disk. Wrapped by the caller's pcall; a write failure is swallowed.
---@param sample minuet.StatSample
local function persist(sample)
    local path = resolve_stats_path()
    if not path then
        return
    end
    if not (sink and sink.path == path) then
        if sink and sink.handle then
            pcall(function() sink.handle:close() end)
        end
        vim.fn.mkdir(vim.fs.dirname(path), 'p')
        sink = { path = path, handle = io.open(path, 'a') }
    end
    if not sink.handle then
        return
    end
    sink.handle:write(vim.json.encode {
        ts = now_ms(),
        name = sample.name,
        model = sample.model,
        input = sample.input,
        cached = sample.cached,
        output = sample.output,
        elapsed_ms = sample.elapsed_ms,
        disposition = sample.disposition,
    } .. '\n')
    sink.handle:flush()
end

--- Pull the cached-prompt-token count out of a usage block, across the field
--- names different servers use (OpenAI/Mistral nest it under
--- prompt_tokens_details; DeepSeek reports prompt_cache_hit_tokens).
---@param usage table
---@return integer
local function cached_tokens(usage)
    local details = usage.prompt_tokens_details
    if type(details) == 'table' and type(details.cached_tokens) == 'number' then
        return details.cached_tokens
    end
    if type(usage.prompt_cache_hit_tokens) == 'number' then
        return usage.prompt_cache_hit_tokens
    end
    if type(usage.cached_tokens) == 'number' then
        return usage.cached_tokens
    end
    return 0
end

--- Map the client's anchor/slide flags to a disposition (our expected server
--- cache outcome). nil when the caller reported neither flag (non-FIM callers).
---@param entry { anchored?: boolean, would_slide?: boolean }
---@return 'snap'|'pinned'|'slid'|nil
local function disposition_of(entry)
    if entry.anchored == nil and entry.would_slide == nil then
        return nil
    end
    if entry.anchored then
        return 'snap'
    end
    return entry.would_slide and 'slid' or 'pinned'
end

--- Record one finished request. `entry` is the same shape backends hand to
--- minuet.log (response is the raw stdout; usage is extracted if absent).
---@param entry { name?: string, model?: string, response?: string, usage?: table, elapsed_ms?: number, anchored?: boolean, would_slide?: boolean }
function M.record(entry)
    pcall(function()
        local usage = entry.usage or require('minuet.log').extract_usage(entry.response)
        if type(usage) ~= 'table' then
            return
        end
        local input = tonumber(usage.prompt_tokens) or 0
        local sample = {
            name = entry.name,
            model = entry.model,
            input = input,
            output = tonumber(usage.completion_tokens) or 0,
            cached = math.min(cached_tokens(usage), input),
            elapsed_ms = entry.elapsed_ms,
            disposition = disposition_of(entry),
            ok = true,
            ts = os.time(),
        }
        table.insert(samples, sample)
        while #samples > MAX_RECORDS do
            table.remove(samples, 1)
        end
        persist(sample)
    end)
end

function M.reset()
    samples = {}
end

-- ── rendering ───────────────────────────────────────────────────────────────

local BAR_FULL = '█'
local BAR_EMPTY = '░'
-- Eighth-block partials for sub-cell precision on the fractional last cell.
local BAR_PARTIALS = { '', '▏', '▎', '▍', '▌', '▋', '▊', '▉' }

--- A proportional bar of `width` cells for value/max, using eighth-block
--- partials so small differences still register.
---@param value number
---@param max number
---@param width integer
---@return string
local function bar(value, max, width)
    if max <= 0 then
        return string.rep(BAR_EMPTY, width)
    end
    local cells = (value / max) * width
    local full = math.floor(cells)
    local rem = cells - full
    local out = string.rep(BAR_FULL, math.min(full, width))
    if full < width then
        out = out .. BAR_PARTIALS[math.floor(rem * 8) + 1]
    end
    -- Pad to width with empty cells (count display cells, not bytes).
    local shown = vim.fn.strchars(out)
    if shown < width then
        out = out .. string.rep(BAR_EMPTY, width - shown)
    end
    return out
end

--- Group digits with thin separators, e.g. 45231 -> "45,231".
---@param n number
---@return string
local function commas(n)
    local s = tostring(math.floor(n + 0.5))
    local sign = ''
    if s:sub(1, 1) == '-' then
        sign, s = '-', s:sub(2)
    end
    while true do
        local rep
        s, rep = s:gsub('^(%d+)(%d%d%d)', '%1,%2')
        if rep == 0 then
            break
        end
    end
    return sign .. s
end

--- Compact token counts: 1234 -> "1.2k", 45231 -> "45k".
---@param n number
---@return string
local function short(n)
    if n >= 1000 then
        local k = n / 1000
        return (k >= 10 and string.format('%dk', math.floor(k + 0.5)) or string.format('%.1fk', k))
    end
    return tostring(math.floor(n + 0.5))
end

-- Context-size (input tokens) histogram buckets. Upper bound nil = open-ended.
local BUCKETS = {
    { label = '   ≤256', hi = 256 },
    { label = '256–512', hi = 512 },
    { label = ' 512–1k', hi = 1024 },
    { label = '  1k–2k', hi = 2048 },
    { label = '  2k–4k', hi = 4096 },
    { label = '    4k+', hi = nil },
}

-- Per-request cache-hit distribution: for each request, the fraction of its
-- prompt tokens the server served from KV cache. This is the granularity the
-- single token-weighted headline hides -- stone-cold misses (cold), the benign
-- partial hits where most of the prefix is reused (the mid bands, expected to be
-- the bulk), and literal-exact reuse (100%, near-unreachable with FIM since the
-- suffix is always fresh) all collapse into one mean otherwise. Bands are by
-- cached/input ratio in [0,1].
local CACHE_BUCKETS = {
    { label = '   cold', test = function(r) return r <= 0 end },
    { label = '  1–25%', test = function(r) return r > 0 and r <= 0.25 end },
    { label = ' 25–50%', test = function(r) return r > 0.25 and r <= 0.5 end },
    { label = ' 50–75%', test = function(r) return r > 0.5 and r <= 0.75 end },
    { label = ' 75–99%', test = function(r) return r > 0.75 and r < 1 end },
    { label = '   100%', test = function(r) return r >= 1 end },
}

---@param p number percentile in [0,1]
---@param sorted number[]
---@return number
local function percentile(p, sorted)
    if #sorted == 0 then
        return 0
    end
    local idx = math.max(1, math.min(#sorted, math.ceil(p * #sorted)))
    return sorted[idx]
end

--- Build the dashboard lines. Returns the lines and the max display width.
---@return string[] lines, integer width
local function render()
    local n = #samples
    local model = 'Codestral'
    for i = n, 1, -1 do
        if samples[i].model then
            model = samples[i].model
            break
        end
    end

    local title = '  ✨  Minuet · ' .. model .. '  ✨'

    if n == 0 then
        local lines = {
            '',
            title,
            '',
            '   ☆  no completions recorded yet  ☆',
            '   make a few completions, then reopen.',
            '',
        }
        local w = 0
        for _, l in ipairs(lines) do
            w = math.max(w, vim.fn.strdisplaywidth(l))
        end
        return lines, w
    end

    local total_in, total_out, total_cached = 0, 0, 0
    local counts = {}
    local cache_counts = {}
    for _ = 1, #BUCKETS do
        table.insert(counts, 0)
    end
    for _ = 1, #CACHE_BUCKETS do
        table.insert(cache_counts, 0)
    end
    local n_rated, exact_hits = 0, 0
    -- Snap-back diagnostics: bucket each request by its fire-time disposition
    -- (our expected server-cache outcome) and count how many actually came back
    -- warm (server returned >0 cached tokens). This reveals whether the prefix-
    -- pin snap-backs are really being reused, and how often one we expected to
    -- reuse came back a basically-full miss (server eviction).
    local disp = {
        snap = { total = 0, warm = 0 },
        pinned = { total = 0, warm = 0 },
        slid = { total = 0, warm = 0 },
    }
    local latencies = {}
    for _, s in ipairs(samples) do
        total_in = total_in + s.input
        total_out = total_out + s.output
        total_cached = total_cached + s.cached
        for b, bucket in ipairs(BUCKETS) do
            if bucket.hi == nil or s.input <= bucket.hi then
                counts[b] = counts[b] + 1
                break
            end
        end
        if s.input > 0 then
            local ratio = s.cached / s.input
            n_rated = n_rated + 1
            if ratio >= 1 then
                exact_hits = exact_hits + 1
            end
            for b, bucket in ipairs(CACHE_BUCKETS) do
                if bucket.test(ratio) then
                    cache_counts[b] = cache_counts[b] + 1
                    break
                end
            end
        end
        local d = s.disposition and disp[s.disposition]
        if d then
            d.total = d.total + 1
            if s.cached > 0 then
                d.warm = d.warm + 1
            end
        end
        if s.elapsed_ms then
            table.insert(latencies, s.elapsed_ms)
        end
    end
    table.sort(latencies)

    local hit_rate = total_in > 0 and (total_cached / total_in) or 0
    local max_bucket = 0
    for _, c in ipairs(counts) do
        max_bucket = math.max(max_bucket, c)
    end
    local max_cache = 0
    for _, c in ipairs(cache_counts) do
        max_cache = math.max(max_cache, c)
    end

    local lines = {}
    local function add(s)
        table.insert(lines, s)
    end

    add('')
    add(title)
    add('')
    add(string.format('   requests       %s', commas(n)))
    add(string.format('   input tokens   %s   (cached %s)', commas(total_in), commas(total_cached)))
    add(string.format('   output tokens  %s', commas(total_out)))
    add('')
    -- Protagonist: token-weighted share of all prompt tokens served from cache.
    add(string.format('   prompt tokens from cache  %s  %d%%', bar(hit_rate, 1, 24), math.floor(hit_rate * 100 + 0.5)))
    add('')
    add('   cache hit / request')
    for b, bucket in ipairs(CACHE_BUCKETS) do
        add(string.format('   %s  %s %s', bucket.label, bar(cache_counts[b], max_cache, 16), commas(cache_counts[b])))
    end
    if n_rated > 0 then
        -- Secondary, de-emphasized: literal-exact reuse. Near-zero is expected
        -- with FIM (the suffix is always fresh), so it is not the protagonist.
        local exact_pct = math.floor(exact_hits / n_rated * 100 + 0.5)
        add(string.format('   exact 100%% reuse: %s req (%d%%)', commas(exact_hits), exact_pct))
    end

    -- Snap-back diagnostics. For each disposition, the bar is the share that came
    -- back warm; snap-back also calls out the cold count (expected reuse, server
    -- missed) and slid is the expected-miss baseline we should see stay cold.
    local disp_total = disp.snap.total + disp.pinned.total + disp.slid.total
    if disp_total > 0 then
        add('')
        add('   prefix KV reuse · server warm by disposition')
        local rows = {
            { key = 'snap', label = 'snap-back' },
            { key = 'pinned', label = 'pinned   ' },
            { key = 'slid', label = 'slid     ' },
        }
        for _, row in ipairs(rows) do
            local d = disp[row.key]
            if d.total > 0 then
                local rate = d.warm / d.total
                local detail
                if row.key == 'snap' then
                    detail = string.format('%s fired · %s cold', commas(d.total), commas(d.total - d.warm))
                elseif row.key == 'slid' then
                    detail = string.format('%s · expected miss', commas(d.total))
                else
                    detail = commas(d.total)
                end
                local pct = math.floor(rate * 100 + 0.5)
                add(string.format('   %s %s %3d%%  %s', row.label, bar(rate, 1, 10), pct, detail))
            end
        end
    end

    add('')
    add('   context size · prompt tokens / request')
    for b, bucket in ipairs(BUCKETS) do
        add(string.format('   %s  %s %s', bucket.label, bar(counts[b], max_bucket, 16), commas(counts[b])))
    end
    if #latencies > 0 then
        add('')
        add(string.format(
            '   latency    p50 %dms · p90 %dms · p99 %dms',
            math.floor(percentile(0.5, latencies) + 0.5),
            math.floor(percentile(0.9, latencies) + 0.5),
            math.floor(percentile(0.99, latencies) + 0.5)
        ))
    end
    add('')
    add('   ☆ tokens cached on the server save latency & cost ☆')
    add('')

    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    return lines, width
end

local HL_NS = vim.api.nvim_create_namespace 'minuet.stats'

--- Link the dashboard's highlight groups to standard ones so they track the
--- active colorscheme. Cheap and idempotent; only sets a group when unset.
local function ensure_highlights()
    local defaults = {
        MinuetStatsTitle = 'Title',
        MinuetStatsBar = 'String',
        MinuetStatsDim = 'Comment',
    }
    for group, link in pairs(defaults) do
        if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = group })) then
            vim.api.nvim_set_hl(0, group, { link = link, default = true })
        end
    end
end

--- Highlight the contiguous run of bar glyphs (█ ░ and eighth-block partials,
--- all U+2580–U+2595, i.e. bytes E2 96 80–95) in a line, plus whole-line accent
--- for the ✨ title and ☆ footer rows.
---@param buf integer
---@param line_idx integer 0-based
---@param line string
local function highlight_line(buf, line_idx, line)
    if line:find('✨', 1, true) then
        vim.api.nvim_buf_set_extmark(buf, HL_NS, line_idx, 0, { end_col = #line, hl_group = 'MinuetStatsTitle' })
    elseif line:find('☆', 1, true) or line:find('exact 100', 1, true) then
        vim.api.nvim_buf_set_extmark(buf, HL_NS, line_idx, 0, { end_col = #line, hl_group = 'MinuetStatsDim' })
    end

    local first, last, i = nil, nil, 1
    while true do
        local s, e = line:find('\226\150[\128-\149]', i)
        if not s then
            break
        end
        first = first or s
        last = e
        i = e + 1
    end
    if first then
        vim.api.nvim_buf_set_extmark(buf, HL_NS, line_idx, first - 1, { end_col = last, hl_group = 'MinuetStatsBar' })
    end
end

--- Open the stats dashboard in a non-editable, centered floating window.
function M.show()
    ensure_highlights()
    local lines, width = render()
    width = math.max(width + 2, 40)
    local height = #lines

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    for idx, line in ipairs(lines) do
        highlight_line(buf, idx - 1, line)
    end
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype = 'minuet-stats'

    local editor_w = vim.o.columns
    local editor_h = vim.o.lines
    local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = math.min(width, editor_w - 4),
        height = math.min(height, editor_h - 4),
        row = math.max(0, math.floor((editor_h - height) / 2) - 1),
        col = math.floor((editor_w - width) / 2),
        style = 'minimal',
        border = 'rounded',
        title = ' minuet stats ',
        title_pos = 'center',
    })
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = false

    for _, key in ipairs { 'q', '<Esc>' } do
        vim.keymap.set('n', key, function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end, { buffer = buf, nowait = true, silent = true })
    end
end

return M
