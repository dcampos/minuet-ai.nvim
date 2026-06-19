-- Treesitter foreground coloring for hypothetical (proposed) text.
--
-- Given the predicted text of a duet edit plus a language, this returns
-- extmark-style chunk lists ({ { text, hl_group }, ... } per line) where each
-- run carries the treesitter capture it would receive if the text were real
-- buffer content. Callers feed those chunks straight into `virt_text` /
-- `virt_lines`, so proposed code is syntax-highlighted instead of flat.
--
-- This is deliberately standalone (no buffer, no window, no plugin state): it
-- parses the text with a string parser and resolves the `highlights` query the
-- same way Neovim's highlighter does (priority, then later-capture-wins). That
-- makes it unit-testable end to end against the bundled `lua` parser.
--
-- Known limitation: an isolated snippet loses surrounding context, so
-- structure- or injection-sensitive captures can differ from in-buffer
-- rendering. Injected languages ARE followed (nested string parsers), but the
-- caller can pass `opts.scaffold` to wrap the snippet in synthetic context when
-- fidelity matters.

local M = {}

---@class minuet.DuetTsHighlightOpts
---@field dim? boolean derive dimmed (blended) variants of each capture group
---@field blend? integer blend amount (0-100) for dimmed groups (default 40)
---@field bg? integer|string background color for every chunk (the "added" tint)
---@field base_hl? string hl group for bytes no capture covers (default 'Normal')

local DEFAULT_BLEND = 40
local DERIVED_PREFIX = 'MinuetDuetTs_'

-- Cache of (source group, style) -> derived group name.
local derived_cache = {}

--- Derive a group from `src_group` with the requested style applied (dim via
--- `blend`, and/or a background tint). Returns `src_group` unchanged when no
--- style is requested. Derived groups keep the source fg, so colors stay tied
--- to the active colorscheme rather than being hard-coded.
---@param src_group string e.g. '@keyword.return'
---@param opts minuet.DuetTsHighlightOpts
---@return string group
local function resolve_group(src_group, opts)
    local want_dim = opts.dim == true
    local want_bg = opts.bg ~= nil
    if not want_dim and not want_bg then
        return src_group
    end

    local blend = opts.blend or DEFAULT_BLEND
    local key = string.format('%s|%s|%s', src_group, want_dim and blend or '-', want_bg and tostring(opts.bg) or '-')
    local cached = derived_cache[key]
    if cached then
        return cached
    end

    local base = vim.deepcopy(vim.api.nvim_get_hl(0, { name = src_group, link = false }) or {})
    base.link = nil
    if want_dim then
        -- `blend` softens virt_text toward the background without hard-coding fg.
        base.blend = math.max(base.blend or 0, blend)
    end
    if want_bg then
        base.bg = opts.bg
    end

    local name = (DERIVED_PREFIX .. key:gsub('[^%w]', '_')):sub(1, 200)
    vim.api.nvim_set_hl(0, name, base)
    derived_cache[key] = name
    return name
end

---@param ltree vim.treesitter.LanguageTree
---@param source string
---@param spans table[] accumulator
local function collect_spans(ltree, source, spans)
    local lang = ltree:lang()
    local query = vim.treesitter.query.get(lang, 'highlights')
    if query then
        for _, tree in ipairs(ltree:trees()) do
            local root = tree:root()
            local order = 0
            for id, node, meta in query:iter_captures(root, source, 0, -1) do
                order = order + 1
                local sr, sc, er, ec = node:range()
                local priority = tonumber(meta.priority or (meta[id] and meta[id].priority)) or 100
                spans[#spans + 1] = {
                    srow = sr,
                    scol = sc,
                    erow = er,
                    ecol = ec,
                    hl = '@' .. query.captures[id],
                    priority = priority,
                    order = order,
                }
            end
        end
    end
    for _, child in pairs(ltree:children()) do
        collect_spans(child, source, spans)
    end
end

---@param line string
---@param owners table<integer, table> 0-based byte col -> winning span
---@param opts minuet.DuetTsHighlightOpts
---@return table[] chunks list of { text, hl_group }
local function line_to_chunks(line, owners, opts)
    local chunks = {}
    local n = #line
    if n == 0 then
        return chunks
    end

    local function hl_at(col)
        local owner = owners[col]
        return resolve_group(owner and owner.hl or opts.base_hl, opts)
    end

    local col = 0
    while col < n do
        local hl = hl_at(col)
        local run_end = col + 1
        while run_end < n and hl_at(run_end) == hl do
            run_end = run_end + 1
        end
        chunks[#chunks + 1] = { line:sub(col + 1, run_end), hl }
        col = run_end
    end

    return chunks
end

--- Syntax-color `lines` as if they were `lang` code.
---@param lines string[]
---@param lang string
---@param opts? minuet.DuetTsHighlightOpts
---@return table[][] one chunk list per input line (suitable for virt_lines)
function M.highlight_lines(lines, lang, opts)
    opts = opts or {}
    local base_hl = opts.base_hl or 'Normal'
    opts = vim.tbl_extend('keep', { base_hl = base_hl }, opts)

    local source = table.concat(lines, '\n')
    local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
    if not ok or not parser then
        -- No parser for this language: degrade to flat base_hl.
        local out = {}
        for i, line in ipairs(lines) do
            out[i] = #line > 0 and { { line, base_hl } } or {}
        end
        return out
    end

    pcall(function()
        parser:parse(true)
    end)

    local spans = {}
    collect_spans(parser, source, spans)

    -- Resolve overlaps the way Neovim's highlighter does: higher priority wins,
    -- ties broken by capture order (later capture on top). Sorting ascending and
    -- letting later writes overwrite yields exactly that.
    table.sort(spans, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.order < b.order
    end)

    -- owners[row][col] = winning span (row/col 0-based).
    local owners = {}
    for _, span in ipairs(spans) do
        for row = span.srow, span.erow do
            owners[row] = owners[row] or {}
            local line = lines[row + 1] or ''
            local from = (row == span.srow) and span.scol or 0
            local to = (row == span.erow) and span.ecol or #line
            for col = from, to - 1 do
                owners[row][col] = span
            end
        end
    end

    local out = {}
    for i, line in ipairs(lines) do
        out[i] = line_to_chunks(line, owners[i - 1] or {}, opts)
    end
    return out
end

--- Convenience: color a single line, returning its chunk list.
---@param line string
---@param lang string
---@param opts? minuet.DuetTsHighlightOpts
---@return table[] chunks
function M.highlight_line(line, lang, opts)
    return M.highlight_lines({ line }, lang, opts)[1]
end

M._private = { resolve_group = resolve_group }

return M
