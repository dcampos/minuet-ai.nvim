-- Context gatherers for the Inception Mercury Edit 2 prompt's
-- `<|recently_viewed_code_snippets|>` section: treesitter scope, LSP diagnostics,
-- and related editor context. The exact text shapes mirror
-- the reference implementation in cursortab.nvim so we stay in-distribution with
-- what Mercury Edit 2 was trained on.

local M = {}

-- Node types that count as an enclosing scope / an import, by grammar.
-- Ported verbatim from cursortab.nvim's treesitter.lua so the same nodes are
-- surfaced across languages.
local scope_types = {
    function_declaration = true,
    function_definition = true,
    method_declaration = true,
    method_definition = true,
    class_declaration = true,
    class_definition = true,
    type_declaration = true,
    type_spec = true,
    impl_item = true,
    func_literal = true,
    arrow_function = true,
    function_item = true,
}

local import_types = {
    import_declaration = true,
    import_statement = true,
    use_declaration = true,
    preproc_include = true,
    import_spec = true,
    import_spec_list = true,
}

---@class minuet.DuetTSSibling
---@field name string
---@field signature string
---@field line integer 1-based

---@class minuet.DuetTSContext
---@field enclosing_signature string
---@field siblings minuet.DuetTSSibling[]
---@field imports string[]
---@field syntax_ranges { start_line: integer, end_line: integer }[] innermost to outermost, 1-based inclusive

--- Treesitter scope around the cursor: the enclosing-scope signature line,
--- sibling scope signatures, top-level imports, and the ancestor node line
--- ranges used to snap the editable region to syntax boundaries.
---@param bufnr integer
---@param row integer 1-based cursor row
---@param col integer 0-based cursor column
---@param max_siblings integer
---@return minuet.DuetTSContext?
function M.treesitter(bufnr, row, col, max_siblings)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or not parser then
        return nil
    end
    pcall(parser.parse, parser)

    local row0 = row - 1
    local cursor_node = vim.treesitter.get_node { bufnr = bufnr, pos = { row0, col } }
    if not cursor_node then
        return nil
    end

    local function first_line(start_row0)
        return vim.api.nvim_buf_get_lines(bufnr, start_row0, start_row0 + 1, false)[1] or ''
    end

    local enclosing
    local node = cursor_node
    while node do
        if scope_types[node:type()] then
            enclosing = node
            break
        end
        node = node:parent()
    end

    local enclosing_signature = enclosing and first_line(enclosing:start()) or ''

    local siblings = {}
    local parent = enclosing and enclosing:parent()
    if parent then
        for child in parent:iter_children() do
            if scope_types[child:type()] and child ~= enclosing then
                local s_row = child:start()
                local name = ''
                local name_node = child:field('name')[1]
                if name_node then
                    name = vim.treesitter.get_node_text(name_node, bufnr)
                end
                siblings[#siblings + 1] = { name = name, signature = first_line(s_row), line = s_row + 1 }
            end
        end
        if #siblings > max_siblings then
            table.sort(siblings, function(a, b)
                return math.abs(a.line - row) < math.abs(b.line - row)
            end)
            local trimmed = {}
            for i = 1, max_siblings do
                trimmed[i] = siblings[i]
            end
            siblings = trimmed
        end
    end

    local imports = {}
    local root = parser:trees()[1]:root()
    for child in root:iter_children() do
        if import_types[child:type()] then
            local lines = vim.api.nvim_buf_get_lines(bufnr, child:start(), child:end_() + 1, false)
            imports[#imports + 1] = table.concat(lines, '\n')
        end
    end

    -- Ancestor node line ranges, innermost to outermost, multi-line only.
    local syntax_ranges = {}
    node = cursor_node
    while node do
        local s_row, e_row = node:start(), node:end_()
        if e_row > s_row then
            syntax_ranges[#syntax_ranges + 1] = { start_line = s_row + 1, end_line = e_row + 1 }
        end
        node = node:parent()
    end

    if enclosing_signature == '' and #siblings == 0 and #imports == 0 and #syntax_ranges == 0 then
        return nil
    end
    return {
        enclosing_signature = enclosing_signature,
        siblings = siblings,
        imports = imports,
        syntax_ranges = syntax_ranges,
    }
end

local severity_name = { [1] = 'ERROR', [2] = 'WARNING', [3] = 'INFORMATION', [4] = 'HINT' }

--- treesitter_context snippet body, or '' when there is nothing to say.
---@param ts minuet.DuetTSContext?
---@return string
function M.treesitter_text(ts)
    if not ts then
        return ''
    end
    local parts = {}
    if ts.enclosing_signature ~= '' then
        parts[#parts + 1] = 'Enclosing scope: ' .. ts.enclosing_signature
    end
    for _, s in ipairs(ts.siblings) do
        parts[#parts + 1] = ('Sibling: line %d: %s'):format(s.line, s.signature)
    end
    for _, imp in ipairs(ts.imports) do
        parts[#parts + 1] = 'Import: ' .. imp
    end
    if #parts == 0 then
        return ''
    end
    return table.concat(parts, '\n') .. '\n'
end

--- diagnostics snippet body, or '' when the buffer has no diagnostics. Mirrors
--- cursortab: `line <lnum>: [SEVERITY] message (source: src)` with the 0-based
--- lnum returned by vim.diagnostic.get.
---@param bufnr integer
---@return string
function M.diagnostics_text(bufnr)
    local items = vim.diagnostic.get(bufnr)
    if not items or #items == 0 then
        return ''
    end
    local parts = {}
    for _, d in ipairs(items) do
        local line = ''
        if d.lnum ~= nil then
            line = ('line %d: '):format(d.lnum)
        end
        line = line .. ('[%s] %s'):format(severity_name[d.severity] or 'ERROR', d.message or '')
        if d.source and d.source ~= '' then
            line = line .. (' (source: %s)'):format(d.source)
        end
        parts[#parts + 1] = line
    end
    return table.concat(parts, '\n') .. '\n'
end

return M
