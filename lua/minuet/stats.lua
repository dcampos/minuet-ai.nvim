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
---@field ok boolean response decoded with a usage block
---@field ts integer os.time of the sample

---@type minuet.StatSample[]
local samples = {}

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

--- Record one finished request. `entry` is the same shape backends hand to
--- minuet.log (response is the raw stdout; usage is extracted if absent).
---@param entry { name?: string, model?: string, response?: string, usage?: table, elapsed_ms?: number }
function M.record(entry)
    pcall(function()
        local usage = entry.usage or require('minuet.log').extract_usage(entry.response)
        if type(usage) ~= 'table' then
            return
        end
        local input = tonumber(usage.prompt_tokens) or 0
        table.insert(samples, {
            name = entry.name,
            model = entry.model,
            input = input,
            output = tonumber(usage.completion_tokens) or 0,
            cached = math.min(cached_tokens(usage), input),
            elapsed_ms = entry.elapsed_ms,
            ok = true,
            ts = os.time(),
        })
        while #samples > MAX_RECORDS do
            table.remove(samples, 1)
        end
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
    for _ = 1, #BUCKETS do
        table.insert(counts, 0)
    end
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
    add(string.format('   cache hit  %s  %d%%', bar(hit_rate, 1, 24), math.floor(hit_rate * 100 + 0.5)))
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
    elseif line:find('☆', 1, true) then
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
