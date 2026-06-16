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
        name = 'duet.preview side_by_side aligns replacement text after the widest original line',
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
                return a[2] < b[2]
            end)
            helpers.expect_equal(#extmarks, 2)
            helpers.expect_equal(extmarks[1][4].hl_group, 'MinuetDuetDelete')
            helpers.expect_equal(extmarks[1][4].virt_text, {
                { '    ', 'Normal' },
                { 'XX', 'MinuetDuetAdd' },
            })
            helpers.expect_equal(extmarks[2][4].virt_text, {
                { '  ', 'Normal' },
                { 'YY', 'MinuetDuetAdd' },
                { '|', 'MinuetDuetCursor' },
                { 'YY', 'MinuetDuetAdd' },
            })

            helpers.delete_buffer(bufnr)
        end,
    },
}
