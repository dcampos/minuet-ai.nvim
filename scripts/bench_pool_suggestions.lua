-- Benchmark: pool_suggestions prefix-shift scan with a large lines_before.
--
-- Compares the OLD unbounded O(#lines_before) scan in match_prefix_to_cached_suffix
-- against the NEW bounded O(max_shift) version introduced to prevent CPU saturation
-- when the cache is warm and the cursor is near the end of a large file.
--
-- Run from repo root:
--   nvim --headless -u NONE -i NONE -n \
--     +"lua package.path = package.path .. ';./?.lua;./?/init.lua'" \
--     -l scripts/bench_pool_suggestions.lua

if not vim then
    io.stderr:write 'Must run inside nvim --headless\n'
    os.exit(1)
end

-- ── implementations ──────────────────────────────────────────────────────────

-- OLD: no shift bound, scans every suffix length down to 1
local function match_prefix_old(cached, current)
    if #cached == 0 then return 0 end
    if #current == 0 then return nil end
    local max_len = math.min(#cached, #current)
    for len = max_len, 1, -1 do
        if cached:sub(#cached - len + 1) == current:sub(1, len) then
            return len
        end
    end
    return nil
end

-- NEW: bails out when length delta or shift exceeds max_shift
local function match_prefix_new(cached, current, max_shift)
    if #cached == 0 then return 0 end
    if #current == 0 then return nil end
    if math.abs(#current - #cached) > max_shift then return nil end
    local max_len = math.min(#cached, #current)
    local min_len = math.max(1, #current - max_shift)
    for len = max_len, min_len, -1 do
        if cached:sub(#cached - len + 1) == current:sub(1, len) then
            return len
        end
    end
    return nil
end

local function truncate_at_stop_tokens(text, stop_tokens)
    if type(text) ~= 'string' or not stop_tokens or #stop_tokens == 0 then return text end
    local cutoff
    for _, token in ipairs(stop_tokens) do
        if type(token) == 'string' and token ~= '' then
            local idx = text:find(token, 1, true)
            if idx and (not cutoff or idx < cutoff) then cutoff = idx end
        end
    end
    return cutoff and text:sub(1, cutoff - 1) or text
end

local function norm_stops(t)
    return (t and #t > 0) and t or nil
end

local function pool_suggestions(match_fn, max_shift, ctx, params, cur_before, cur_after, cfg)
    local vt_cfg = cfg.virtualtext or {}
    local soft_limit = vt_cfg.cache_soft_chars_ahead or 20

    local results = {}
    local seen = {}
    local needs_refresh = false

    for _, entry in ipairs(ctx.cache or {}) do
        if entry.params.provider ~= params.provider then goto continue end
        if entry.params.model    ~= params.model    then goto continue end
        if not vim.deep_equal(entry.params.optional, params.optional) then goto continue end
        if not vim.deep_equal(norm_stops(entry.params.stop_tokens), norm_stops(params.stop_tokens)) then
            goto continue
        end
        if type(entry.lines_after) ~= 'string' or type(cur_after) ~= 'string' then goto continue end
        if not (
            entry.lines_after:sub(1, #cur_after) == cur_after
            or cur_after:sub(1, #entry.lines_after) == entry.lines_after
        ) then goto continue end
        if type(entry.lines_before) ~= 'string' or type(cur_before) ~= 'string' then goto continue end

        local typed_since_len
        if max_shift then
            typed_since_len = match_fn(entry.lines_before, cur_before, max_shift)
        else
            typed_since_len = match_fn(entry.lines_before, cur_before)
        end
        if typed_since_len == nil then goto continue end

        local typed_since = cur_before:sub(typed_since_len + 1)
        if #typed_since > soft_limit then needs_refresh = true end

        for _, comp in ipairs(entry.completions) do
            if comp:sub(1, #typed_since) == typed_since then
                local effective = comp:sub(#typed_since + 1)
                effective = truncate_at_stop_tokens(effective, entry.params.stop_tokens)
                if #effective > 0 and not seen[effective] then
                    seen[effective] = true
                    table.insert(results, effective)
                end
            end
        end

        ::continue::
    end

    return results, needs_refresh
end

-- ── fixture ───────────────────────────────────────────────────────────────────

local fh = io.open('README.md', 'r')
if not fh then
    io.stderr:write 'README.md not found; run from the repo root\n'
    os.exit(1)
end
local readme = fh:read '*a'
fh:close()

-- Position cursor near the end of the README (last 200 chars remain as suffix).
local base_before = readme:sub(1, #readme - 200)
local lines_after  = 'end of file\n'

local params = {
    provider    = 'test',
    model       = 'model-a',
    optional    = {},
    stop_tokens = { '\n' },
}

-- 32 cache entries recorded at varying offsets behind the current cursor position.
-- Offsets cover both the within-limit and beyond-limit zones.
local offsets = {}
for i = 1, 32 do
    -- Spread: 1..200 chars behind cursor, exponentially biased toward small offsets
    -- so most entries are within realistic typing distance.
    table.insert(offsets, math.floor(1 + (i - 1) * 6.4))
end
local completions = { 'hello world\n', 'foo bar\n', 'baz qux\n' }

local function make_ctx()
    local ctx = { cache = {} }
    for _, off in ipairs(offsets) do
        table.insert(ctx.cache, {
            lines_before = base_before:sub(1, #base_before - off),
            lines_after  = lines_after,
            params       = params,
            completions  = completions,
        })
    end
    return ctx
end

local cfg = {
    virtualtext = {
        cache_max_chars_ahead  = 40,
        cache_soft_chars_ahead = 20,
    },
}

local N = 5000

-- ── scenario 1: cursor within soft limit (typical warm-cache case) ────────────

local cur_before_near = base_before  -- typed 0 extra chars, entry[1] at -5 offset

local ctx1 = make_ctx()

local t0 = os.clock()
for _ = 1, N do
    pool_suggestions(match_prefix_old, nil, ctx1, params, cur_before_near, lines_after, cfg)
end
local t_old_near = os.clock() - t0

local ctx2 = make_ctx()
local t1 = os.clock()
for _ = 1, N do
    pool_suggestions(match_prefix_new, 40, ctx2, params, cur_before_near, lines_after, cfg)
end
local t_new_near = os.clock() - t1

-- ── scenario 2: cursor far ahead (all entries beyond hard limit) ──────────────

-- 200 chars typed since any cached entry => all should be rejected early in new impl
local cur_before_far = base_before .. string.rep('x', 200)

local ctx3 = make_ctx()
local t2 = os.clock()
for _ = 1, N do
    pool_suggestions(match_prefix_old, nil, ctx3, params, cur_before_far, lines_after, cfg)
end
local t_old_far = os.clock() - t2

local ctx4 = make_ctx()
local t3 = os.clock()
for _ = 1, N do
    pool_suggestions(match_prefix_new, 40, ctx4, params, cur_before_far, lines_after, cfg)
end
local t_new_far = os.clock() - t3

-- ── results ───────────────────────────────────────────────────────────────────

local function fmt(t_sec)
    return string.format('%.2f us/call  (%.0f ms total)', t_sec * 1e6 / N, t_sec * 1000)
end

io.write(string.format('\nlines_before: %d bytes   cache entries: %d   iterations: %d\n\n',
    #base_before, #offsets, N))

io.write('scenario 1: cursor within limit (some entries match)\n')
io.write(string.format('  old (unbounded):  %s\n', fmt(t_old_near)))
io.write(string.format('  new (max_shift=40): %s\n', fmt(t_new_near)))
io.write(string.format('  speedup: %.1fx\n\n', t_old_near / t_new_near))

io.write('scenario 2: cursor far ahead (all entries beyond hard limit)\n')
io.write(string.format('  old (unbounded):  %s\n', fmt(t_old_far)))
io.write(string.format('  new (max_shift=40): %s\n', fmt(t_new_far)))
io.write(string.format('  speedup: %.1fx\n', t_old_far / t_new_far))
