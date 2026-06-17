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
        name = 'duet.preview renders replacements inline by default',
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
            helpers.expect_equal(#extmarks, 1)
            helpers.expect_equal(extmarks[1][4].hl_group, 'MinuetDuetDelete')
            helpers.expect_equal(extmarks[1][4].virt_text_pos, 'eol')
            helpers.expect_equal(extmarks[1][4].virt_text, {
                { 'om', 'MinuetDuetAdd' },
                { '|', 'MinuetDuetCursor' },
                { 'ega', 'MinuetDuetAdd' },
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview side_by_side renders replacements as inline spans',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                        mode = 'side_by_side',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({ 'aa', 'bbbb' }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 2,
                },
                original_lines = { 'aa', 'bbbb' },
                proposed_lines = { 'XX', 'YYYY' },
                proposed_cursor = {
                    row_offset = 1,
                    col = 2,
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
            helpers.expect_equal(#extmarks, 4)
            helpers.expect_equal(extmarks[1][4].hl_group, 'MinuetDuetDelete')
            helpers.expect_equal(extmarks[1][4].end_col, 2)
            helpers.expect_equal(extmarks[2][3], 2)
            helpers.expect_equal(extmarks[2][4].virt_text_pos, 'inline')
            helpers.expect_equal(extmarks[2][4].virt_text, {
                { 'XX', 'MinuetDuetAdd' },
            })
            helpers.expect_equal(extmarks[3][4].hl_group, 'MinuetDuetDelete')
            helpers.expect_equal(extmarks[3][4].end_col, 4)
            helpers.expect_equal(extmarks[4][3], 4)
            helpers.expect_equal(extmarks[4][4].virt_text_pos, 'inline')
            helpers.expect_equal(extmarks[4][4].virt_text, {
                { 'YY', 'MinuetDuetAdd' },
                { '|', 'MinuetDuetCursor' },
                { 'YY', 'MinuetDuetAdd' },
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview side_by_side shows each changed word as a red-green pair',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                        mode = 'side_by_side',
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
            helpers.expect_equal(extmarks[1][4].hl_group, 'MinuetDuetDelete')
            helpers.expect_equal(extmarks[1][4].end_col, alpha_col + #'alpha')
            helpers.expect_equal(extmarks[2][3], alpha_col + #'alpha')
            helpers.expect_equal(extmarks[2][4].virt_text, {
                { 'omega', 'MinuetDuetAdd' },
            })
            helpers.expect_equal(extmarks[3][3], beta_col)
            helpers.expect_equal(extmarks[3][4].hl_group, 'MinuetDuetDelete')
            helpers.expect_equal(extmarks[3][4].end_col, beta_col + #'beta')
            helpers.expect_equal(extmarks[4][3], beta_col + #'beta')
            helpers.expect_equal(extmarks[4][4].virt_text, {
                { 'gamma', 'MinuetDuetAdd' },
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview side_by_side renders insert-only and delete-only spans locally',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                        mode = 'side_by_side',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({
                'tags: article.tags',
                'if (article.tags == null) {',
            }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 2,
                },
                original_lines = {
                    'tags: article.tags',
                    'if (article.tags == null) {',
                },
                proposed_lines = {
                    'tags: article.tags ?? []',
                    'if (article.tags) {',
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

            helpers.expect_equal(#extmarks, 2)
            helpers.expect_equal(extmarks[1][2], 0)
            helpers.expect_equal(extmarks[1][3], #'tags: article.tags')
            helpers.expect_equal(extmarks[1][4].virt_text, {
                { ' ?? []', 'MinuetDuetAdd' },
            })
            helpers.expect_equal(extmarks[2][2], 1)
            helpers.expect_equal(extmarks[2][3], ('if (article.tags'):len())
            helpers.expect_equal(extmarks[2][4].hl_group, 'MinuetDuetDelete')
            helpers.expect_equal(extmarks[2][4].end_col, ('if (article.tags == null'):len())

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview virtual_lines renders red source lines and green proposed virtual lines',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                        mode = 'virtual_lines',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local old_line = [[content_suffix = "\n" + "\n".join(lines[13:16]) + "\n"]]
            local new_line = [[content_suffix = "\n" + "\n".join(lines[14:19]) + "\n"]]
            local inserted_line = [[assert content_suffix.strip(), "content suffix is empty -- doc too short"]]
            local bufnr = helpers.create_buffer({ old_line }, { 1, 0 })
            local state = {
                range = {
                    start_row = 0,
                    end_row = 1,
                },
                original_lines = { old_line },
                proposed_lines = { new_line, inserted_line },
            }

            preview.render(bufnr, state)

            local extmarks = get_extmarks(bufnr, preview.ns_id)
            local line_mark
            local virt_mark
            local deleted_spans = {}
            for _, extmark in ipairs(extmarks) do
                local details = extmark[4]
                if details.line_hl_group then
                    line_mark = extmark
                elseif details.virt_lines then
                    virt_mark = extmark
                elseif details.hl_group == 'MinuetDuetDeleteText' then
                    table.insert(deleted_spans, extmark)
                end
            end
            table.sort(deleted_spans, function(a, b)
                return a[3] < b[3]
            end)

            local first_old_col = old_line:find('13', 1, true) - 1
            local second_old_col = old_line:find('16', 1, true) - 1
            helpers.expect_equal(#extmarks, 4)
            helpers.expect_equal(line_mark[4].line_hl_group, 'MinuetDuetDelete')
            helpers.expect_equal(line_mark[4].priority, 100)
            helpers.expect_equal(#deleted_spans, 2)
            helpers.expect_equal(deleted_spans[1][3], first_old_col)
            helpers.expect_equal(deleted_spans[1][4].end_col, first_old_col + #'13')
            helpers.expect_equal(deleted_spans[1][4].priority, 110)
            helpers.expect_equal(deleted_spans[2][3], second_old_col)
            helpers.expect_equal(deleted_spans[2][4].end_col, second_old_col + #'16')
            helpers.expect_equal(deleted_spans[2][4].priority, 110)
            helpers.expect_equal(virt_mark[4].virt_lines, {
                {
                    { [[content_suffix = "\n" + "\n".join(lines[]], 'MinuetDuetAdd' },
                    { '14', 'MinuetDuetAddText' },
                    { ':', 'MinuetDuetAdd' },
                    { '19', 'MinuetDuetAddText' },
                    { ']) + "\\n"', 'MinuetDuetAdd' },
                },
                {
                    { inserted_line, 'MinuetDuetAdd' },
                },
            })
            helpers.expect_equal(virt_mark[4].virt_lines_above, false)

            helpers.delete_buffer(bufnr)
        end,
    },
}
