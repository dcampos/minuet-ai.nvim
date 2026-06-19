local helpers = require 'tests.helpers'

-- Concatenate chunk texts back into the original line.
local function chunk_text(chunks)
    local parts = {}
    for _, c in ipairs(chunks) do
        parts[#parts + 1] = c[1]
    end
    return table.concat(parts)
end

-- Find the hl group of the chunk whose text equals `needle`.
local function hl_of(chunks, needle)
    for _, c in ipairs(chunks) do
        if c[1] == needle then
            return c[2]
        end
    end
    return nil
end

return {
    {
        name = 'ts_highlight colors a lua line by treesitter capture',
        run = function()
            helpers.ensure_runtime()
            local ts = helpers.reload 'minuet.duet.ts_highlight'

            local line = 'local greet = 42'
            local chunks = ts.highlight_line(line, 'lua')

            -- Lossless: chunks reconstruct the exact line.
            helpers.expect_equal(chunk_text(chunks), line)

            -- Robust to query wording: assert the capture family, not exact name.
            local kw = hl_of(chunks, 'local')
            helpers.expect_truthy(
                kw and kw:find('keyword', 1, true),
                'local should be a @keyword*, got ' .. tostring(kw)
            )

            local num = hl_of(chunks, '42')
            helpers.expect_truthy(num and num:find('number', 1, true), '42 should be a @number*, got ' .. tostring(num))
        end,
    },
    {
        name = 'ts_highlight resolves overlapping captures (later wins)',
        run = function()
            helpers.ensure_runtime()
            local ts = helpers.reload 'minuet.duet.ts_highlight'

            -- `name` gets both @variable and @variable.parameter; the more
            -- specific later capture must win.
            local line = 'local f = function(name) return name end'
            local chunks = ts.highlight_line(line, 'lua')
            helpers.expect_equal(chunk_text(chunks), line)

            -- The parameter occurrence is the one inside the arg list.
            local param_hl = hl_of(chunks, 'name')
            helpers.expect_truthy(
                param_hl and param_hl:find('variable', 1, true),
                'name should be a @variable*, got ' .. tostring(param_hl)
            )
        end,
    },
    {
        name = 'ts_highlight multi-line returns one chunk list per line',
        run = function()
            helpers.ensure_runtime()
            local ts = helpers.reload 'minuet.duet.ts_highlight'

            local lines = { 'local function f()', '    return 1', 'end' }
            local out = ts.highlight_lines(lines, 'lua')
            helpers.expect_equal(#out, 3)
            for i, line in ipairs(lines) do
                helpers.expect_equal(chunk_text(out[i]), line)
            end
        end,
    },
    {
        name = 'ts_highlight dim derives a blended group with same base color',
        run = function()
            helpers.ensure_runtime()
            local ts = helpers.reload 'minuet.duet.ts_highlight'

            local line = 'local x = 1'
            local plain = ts.highlight_line(line, 'lua')
            local dimmed = ts.highlight_line(line, 'lua', { dim = true, blend = 50 })

            helpers.expect_equal(chunk_text(dimmed), line)

            -- A dimmed chunk's group differs from the plain capture group...
            local plain_kw = hl_of(plain, 'local')
            local dim_kw = hl_of(dimmed, 'local')
            helpers.expect_truthy(dim_kw ~= plain_kw, 'dim should remap the capture group')

            -- ...and the derived group carries blend and the base fg.
            local plain_hl = vim.api.nvim_get_hl(0, { name = plain_kw, link = false })
            local dim_hl = vim.api.nvim_get_hl(0, { name = dim_kw, link = false })
            helpers.expect_equal(dim_hl.blend, 50)
            helpers.expect_equal(dim_hl.fg, plain_hl.fg)
        end,
    },
    {
        name = 'ts_highlight degrades to base_hl for an unknown language',
        run = function()
            helpers.ensure_runtime()
            local ts = helpers.reload 'minuet.duet.ts_highlight'

            local out = ts.highlight_lines({ 'whatever text' }, 'no_such_language_xyz', { base_hl = 'MinuetDuetAdd' })
            helpers.expect_equal(out, { { { 'whatever text', 'MinuetDuetAdd' } } })
        end,
    },
}
