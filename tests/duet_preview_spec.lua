local helpers = require 'tests.helpers'

local function get_extmarks(bufnr, ns_id)
    return vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
end

return {
    {
        name = 'duet.preview renders the cursor on an unchanged line',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({ 'alpha', 'beta' }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 2,
                },
                original_lines = { 'alpha', 'beta' },
                proposed_lines = { 'alpha', 'beta' },
                proposed_cursor = {
                    row_offset = 1,
                    col = 2,
                },
            }

            preview.render(bufnr, state)

            local extmarks = get_extmarks(bufnr, preview.ns_id)
            helpers.expect_equal(#extmarks, 1)
            helpers.expect_equal(extmarks[1][4].virt_text, {
                { 'be', 'MinuetDuetComment' },
                { '|', 'MinuetDuetCursor' },
                { 'ta', 'MinuetDuetComment' },
            })
            helpers.expect_truthy(preview.is_visible(bufnr, state))

            preview.clear(bufnr, state)

            helpers.expect_equal(get_extmarks(bufnr, preview.ns_id), {})
            helpers.expect_falsy(preview.is_visible(bufnr, state))

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview renders inserted lines as virtual lines',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 1,
                },
                original_lines = { 'alpha' },
                proposed_lines = { 'alpha', 'bravo' },
                proposed_cursor = {
                    row_offset = 1,
                    col = 3,
                },
            }

            preview.render(bufnr, state)

            local extmarks = get_extmarks(bufnr, preview.ns_id)
            helpers.expect_equal(#extmarks, 1)
            helpers.expect_equal(extmarks[1][4].virt_lines, {
                {
                    { 'bra', 'MinuetDuetAdd' },
                    { '|', 'MinuetDuetCursor' },
                    { 'vo', 'MinuetDuetAdd' },
                },
            })
            helpers.expect_truthy(preview.is_visible(bufnr, state))

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview renders two word changes inline',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local old_line = 'return alpha + beta'
            local new_line = 'return omega + gamma'
            local bufnr = helpers.create_buffer({ old_line }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 1,
                },
                original_lines = { old_line },
                proposed_lines = { new_line },
            }

            preview.render(bufnr, state)

            local extmarks = get_extmarks(bufnr, preview.ns_id)
            table.sort(extmarks, function(a, b)
                if a[3] ~= b[3] then
                    return a[3] < b[3]
                end
                return a[1] < b[1]
            end)

            local alpha_col = old_line:find('alpha', 1, true) - 1
            local beta_col = old_line:find('beta', 1, true) - 1
            helpers.expect_equal(#extmarks, 4)
            helpers.expect_equal(extmarks[1][3], alpha_col)
            helpers.expect_equal(extmarks[1][4].hl_group, 'MinuetDuetDeleteText')
            helpers.expect_equal(extmarks[1][4].end_col, alpha_col + #'alpha')
            helpers.expect_equal(extmarks[2][3], alpha_col + #'alpha')
            helpers.expect_equal(extmarks[2][4].virt_text, {
                { 'omega', 'MinuetDuetAddText' },
            })
            helpers.expect_equal(extmarks[3][3], beta_col)
            helpers.expect_equal(extmarks[3][4].hl_group, 'MinuetDuetDeleteText')
            helpers.expect_equal(extmarks[3][4].end_col, beta_col + #'beta')
            helpers.expect_equal(extmarks[4][3], beta_col + #'beta')
            helpers.expect_equal(extmarks[4][4].virt_text, {
                { 'gamma', 'MinuetDuetAddText' },
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview renders repeated same-segment additions inline',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({
                'vim.nvim_creat',
                'vim.nvim_buf',
                'vim.nvim_win',
            }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 3,
                },
                original_lines = {
                    'vim.nvim_creat',
                    'vim.nvim_buf',
                    'vim.nvim_win',
                },
                proposed_lines = {
                    'vim.api.nvim_creat',
                    'vim.api.nvim_buf',
                    'vim.api.nvim_win',
                },
            }

            preview.render(bufnr, state)

            local extmarks = get_extmarks(bufnr, preview.ns_id)
            table.sort(extmarks, function(a, b)
                if a[2] ~= b[2] then
                    return a[2] < b[2]
                end
                if a[3] ~= b[3] then
                    return a[3] < b[3]
                end
                return a[1] < b[1]
            end)
            helpers.expect_equal(#extmarks, 3)
            for i, extmark in ipairs(extmarks) do
                helpers.expect_equal(extmark[2], i - 1)
                helpers.expect_equal(extmark[3], #'vim.')
                helpers.expect_equal(extmark[4].virt_text, {
                    { 'api.', 'MinuetDuetAddText' },
                })
            end

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview renders unrelated one-line replacements as blocks',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 1,
                },
                original_lines = { 'alpha' },
                proposed_lines = { 'omega' },
                proposed_cursor = {
                    row_offset = 0,
                    col = 2,
                },
            }

            preview.render(bufnr, state)

            local extmarks = get_extmarks(bufnr, preview.ns_id)
            local line_mark
            local virt_mark
            for _, extmark in ipairs(extmarks) do
                if extmark[4].hl_group == 'MinuetDuetDelete' then
                    line_mark = extmark
                elseif extmark[4].virt_lines then
                    virt_mark = extmark
                end
            end
            helpers.expect_equal(line_mark[4].end_col, #'alpha')
            helpers.expect_equal(virt_mark[4].virt_lines, {
                {
                    { 'om', 'MinuetDuetAddText' },
                    { '|', 'MinuetDuetCursor' },
                    { 'ega', 'MinuetDuetAddText' },
                },
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview hides multiline blocks behind a marker until selected',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({ 'one', 'two', 'three' }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 3,
                },
                original_lines = { 'one', 'two', 'three' },
                proposed_lines = { 'alpha', 'beta', 'gamma' },
            }

            preview.render(bufnr, state)
            local extmarks = get_extmarks(bufnr, preview.ns_id)
            helpers.expect_equal(#extmarks, 1)
            -- The collapsed marker is a background tint behind the anchor line's
            -- first character (a blue square that does not cover the glyph), not
            -- an overlay virt_text. Anchor here is 'three', so end_col == 1.
            helpers.expect_equal(extmarks[1][2], 2)
            helpers.expect_equal(extmarks[1][3], 0)
            helpers.expect_equal(extmarks[1][4].hl_group, 'MinuetDuetMarker')
            helpers.expect_equal(extmarks[1][4].end_col, 1)
            helpers.expect_falsy(extmarks[1][4].virt_text)
            helpers.expect_falsy(extmarks[1][4].virt_lines)

            preview.select_next_chunk(bufnr, state)
            extmarks = get_extmarks(bufnr, preview.ns_id)
            local virt_mark
            for _, extmark in ipairs(extmarks) do
                if extmark[4].virt_lines then
                    virt_mark = extmark
                end
            end
            helpers.expect_truthy(virt_mark, 'selected multiline block should render virtual lines')
            helpers.expect_equal(#virt_mark[4].virt_lines, 3)

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview collapses a multi-change hunk to one marker, reveals all on select',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local line = 'vec = [y_1, y_5, y_6]'
            local bufnr = helpers.create_buffer({ line }, { 1, 0 })
            local state = {
                range = { start_row = 0, end_row = 1 },
                original_lines = { line },
                proposed_lines = { 'vec = [y_1, y_2, y_3]' },
                -- Diagnostic focus collapses inline changes; the line carries two
                -- word-diff groups (y_5->y_2, y_6->y_3) that are one diff hunk.
                preview_focus = 'diagnostic',
            }

            preview.render(bufnr, state)
            local extmarks = get_extmarks(bufnr, preview.ns_id)
            local markers = 0
            for _, extmark in ipairs(extmarks) do
                if extmark[4].hl_group == 'MinuetDuetMarker' then
                    markers = markers + 1
                end
            end
            helpers.expect_equal(markers, 1, 'two changes in one hunk should show a single blue square')

            preview.select_next_chunk(bufnr, state)
            extmarks = get_extmarks(bufnr, preview.ns_id)
            local active_virt, sibling_virt, post_markers = nil, nil, 0
            for _, extmark in ipairs(extmarks) do
                local d = extmark[4]
                if d.hl_group == 'MinuetDuetMarker' then
                    post_markers = post_markers + 1
                elseif d.virt_text then
                    if vim.deep_equal(d.virt_text, { { '2', 'MinuetDuetActive' } }) then
                        active_virt = true
                    elseif vim.deep_equal(d.virt_text, { { '3', 'MinuetDuetAddText' } }) then
                        sibling_virt = true
                    end
                end
            end
            -- Selecting one change reveals the whole hunk: the active group is
            -- emphasized, its sibling shows as a normal add, and no marker remains.
            helpers.expect_equal(post_markers, 0, 'revealing the hunk should drop its marker')
            helpers.expect_truthy(active_virt, 'active change should render with the active highlight')
            helpers.expect_truthy(sibling_virt, 'sibling change in the same hunk should also be revealed')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview keeps strong whitespace highlights in block diffs',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                        inline_max_groups = 0,
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local old_line = 'local x=1'
            local new_line = 'local x = 1'
            local bufnr = helpers.create_buffer({ old_line }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 1,
                },
                original_lines = { old_line },
                proposed_lines = { new_line },
            }

            preview.render(bufnr, state)

            local extmarks = get_extmarks(bufnr, preview.ns_id)
            local virt_mark
            for _, extmark in ipairs(extmarks) do
                if extmark[4].virt_lines then
                    virt_mark = extmark
                end
            end
            helpers.expect_equal(virt_mark[4].virt_lines, {
                {
                    { 'local x', 'MinuetDuetAdd' },
                    { ' = ', 'MinuetDuetAddText' },
                    { '1', 'MinuetDuetAdd' },
                },
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview treesitter-colors a proposed block when ts_highlight is on',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                        ts_highlight = true,
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({ 'one', 'two' }, { 1, 0 })
            vim.bo[bufnr].filetype = 'lua'
            local state = {
                range = { start_row = 0, end_row = 2 },
                original_lines = { 'one', 'two' },
                proposed_lines = { 'local a = 1', 'local b = 2' },
            }

            preview.render(bufnr, state)
            -- Multi-line blocks are hidden behind a marker until selected.
            preview.select_next_chunk(bufnr, state)

            local virt
            for _, extmark in ipairs(get_extmarks(bufnr, preview.ns_id)) do
                if extmark[4].virt_lines then
                    virt = extmark[4].virt_lines
                end
            end
            helpers.expect_truthy(virt, 'selected block should render virtual lines')

            -- At least one proposed chunk must carry a treesitter-derived group
            -- (the derived dim/tint group, or a raw @capture) rather than the
            -- flat add color.
            local found_ts = false
            for _, line in ipairs(virt) do
                for _, ch in ipairs(line) do
                    local hl = ch[2] or ''
                    if hl:find('MinuetDuetTs', 1, true) or hl:sub(1, 1) == '@' then
                        found_ts = true
                    end
                end
            end
            helpers.expect_truthy(found_ts, 'expected treesitter-derived groups in the proposed block')

            helpers.delete_buffer(bufnr)
        end,
    },
}
