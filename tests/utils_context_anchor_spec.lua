-- Tests for the optional `anchor` argument to utils.get_context. The anchor
-- keeps the FIM prompt prefix region byte-stable across consecutive requests
-- so the server's KV cache stays warm. See utils.get_context for the
-- mechanics. Each test sets up a buffer, captures a baseline context as the
-- "previous request", advances the cursor and/or edits the buffer to
-- simulate typing, then calls get_context with the captured anchor and
-- asserts how the new context relates to the previous one.
local helpers = require 'tests.helpers'

local function chars_of(n, ch)
    return string.rep(ch or 'x', n)
end

-- Build a buffer where the cursor sits at the very end of a single long line
-- composed of `before` filler chars + a fixed tail, then a newline and
-- `after` filler chars on the next line. Returns (bufnr, utils) so the test
-- can keep calling get_context.
local function setup_long_buffer(before_chars, after_chars, opts)
    opts = opts or {}
    helpers.setup_root_config(opts.config or {})

    local utils = helpers.reload 'minuet.utils'

    local line1 = chars_of(before_chars, opts.before_ch or 'a')
    local line2 = chars_of(after_chars, opts.after_ch or 'z')
    local bufnr = helpers.create_buffer({ line1, line2 }, { 1, before_chars })
    return bufnr, utils
end

return {
    {
        name = 'utils.get_context without anchor preserves the legacy fresh-window output',
        run = function()
            -- 200 chars before, 200 after, budget 100, ratio 0.5 => 50/50 split.
            local bufnr, utils = setup_long_buffer(200, 200, {
                config = {
                    context_window = 100,
                    context_ratio = 0.5,
                },
            })

            local cmp_ctx = utils.make_cmp_context()
            local context = utils.get_context(cmp_ctx)

            helpers.expect_equal(vim.fn.strchars(context.lines_before), 50)
            helpers.expect_equal(vim.fn.strchars(context.lines_after), 50)
            helpers.expect_truthy(context.opts.is_incomplete_before)
            helpers.expect_truthy(context.opts.is_incomplete_after)
            helpers.expect_falsy(context.opts.anchored)

            helpers.delete_buffer(bufnr)
        end,
    },

    {
        name = 'utils.get_context with a fresh matching anchor extends the prefix beyond budget',
        run = function()
            -- Budget keeps the legacy window small; the anchor lets the
            -- prefix grow by up to growth_slack chars before re-anchoring.
            local bufnr, utils = setup_long_buffer(200, 200, {
                config = {
                    context_window = 100,
                    context_ratio = 0.5,
                },
            })

            -- Baseline: legacy window of 50 chars before cursor.
            local cmp_ctx = utils.make_cmp_context()
            local baseline = utils.get_context(cmp_ctx)
            local prev_before = baseline.lines_before
            local prev_after = baseline.lines_after

            -- Simulate typing 8 chars at the cursor.
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { 'NEWTEXT8' })
            vim.api.nvim_win_set_cursor(0, { row, col + 8 })

            local anchor = {
                prev_lines_before = prev_before,
                prev_lines_after = prev_after,
                growth_slack = 1024,
            }

            local context = utils.get_context(utils.make_cmp_context(), nil, anchor)

            -- Prefix should be prev (50) + the 8 typed chars => 58 chars,
            -- exceeding the nominal 50-char budget. opts.anchored signals
            -- the SPM-friendly reuse path was taken.
            helpers.expect_equal(vim.fn.strchars(context.lines_before), 58)
            helpers.expect_truthy(context.opts.anchored)
            helpers.expect_equal(context.lines_before:sub(1, #prev_before), prev_before)
            helpers.expect_equal(context.lines_before:sub(-8), 'NEWTEXT8')

            -- Suffix must be byte-identical to the previous request — that is
            -- the whole reason SPM stays cache-warm.
            helpers.expect_equal(context.lines_after, prev_after)

            helpers.delete_buffer(bufnr)
        end,
    },

    {
        name = 'utils.get_context falls back to the fresh window when growth exceeds slack',
        run = function()
            local bufnr, utils = setup_long_buffer(200, 200, {
                config = {
                    context_window = 100,
                    context_ratio = 0.5,
                },
            })

            local baseline = utils.get_context(utils.make_cmp_context())
            local prev_before = baseline.lines_before
            local prev_after = baseline.lines_after

            -- Type 40 chars but allow only 16 chars of slack: the anchor
            -- extension would exceed slack, forcing re-anchor.
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { string.rep('B', 40) })
            vim.api.nvim_win_set_cursor(0, { row, col + 40 })

            local anchor = {
                prev_lines_before = prev_before,
                prev_lines_after = prev_after,
                growth_slack = 16,
            }

            local context = utils.get_context(utils.make_cmp_context(), nil, anchor)

            -- Re-anchored: back to a budget-sized window centered on cursor.
            helpers.expect_equal(vim.fn.strchars(context.lines_before), 50)
            helpers.expect_falsy(context.opts.anchored)

            helpers.delete_buffer(bufnr)
        end,
    },

    {
        name = 'utils.get_context prefix-only snaps when only the suffix changed',
        run = function()
            local bufnr, utils = setup_long_buffer(200, 200, {
                config = {
                    context_window = 100,
                    context_ratio = 0.5,
                },
            })

            local baseline = utils.get_context(utils.make_cmp_context())
            local prev_before = baseline.lines_before
            local prev_after = baseline.lines_after

            -- Type a few chars at the cursor (prefix grows, still anchor-OK)…
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { 'GROW' })
            vim.api.nvim_win_set_cursor(0, { row, col + 4 })
            -- …but ALSO mutate text well after the cursor so the pinned suffix
            -- no longer matches the buffer (an edit below / a jump downward).
            local last_line = vim.api.nvim_buf_line_count(bufnr) - 1
            vim.api.nvim_buf_set_lines(bufnr, last_line, last_line + 1, false, { 'TOTALLY DIFFERENT SUFFIX' })

            local anchor = {
                prev_lines_before = prev_before,
                prev_lines_after = prev_after,
                growth_slack = 1024,
            }

            local context = utils.get_context(utils.make_cmp_context(), nil, anchor)

            -- The warm prefix start is still reused (its KV is unaffected by an
            -- edit below the cursor), but the stale suffix is dropped for a
            -- fresh one cut from the live buffer.
            helpers.expect_truthy(context.opts.anchored, 'prefix is still warm, so we anchor')
            helpers.expect_truthy(context.opts.suffix_fresh, 'suffix was rebuilt fresh')
            helpers.expect_equal(
                context.lines_before:sub(1, #prev_before),
                prev_before,
                'reused prefix keeps the anchored start'
            )
            helpers.expect_falsy(
                context.lines_after == prev_after,
                'stale suffix must not be reused after a change below the cursor'
            )

            helpers.delete_buffer(bufnr)
        end,
    },

    {
        name = 'utils.get_context snaps back to a warm prefix after a forward jump',
        run = function()
            -- Long single-block buffer so the cursor sits deep enough that the
            -- prefix is truncated (anchor engages). 600 before / 600 after with
            -- a 200 window keeps both sides over budget.
            local bufnr, utils = setup_long_buffer(600, 600, {
                config = {
                    context_window = 200,
                    context_ratio = 0.5,
                },
            })

            local baseline = utils.get_context(utils.make_cmp_context())
            local anchor = {
                prev_lines_before = baseline.lines_before,
                prev_lines_after = baseline.lines_after,
                growth_slack = 12000,
            }

            -- Jump the cursor forward into the next line (a paragraph-down style
            -- move): the prefix above is unchanged content, but the cursor now
            -- sits inside the old suffix region, so the pinned suffix no longer
            -- matches and must be rebuilt fresh.
            local prev_after = anchor.prev_lines_after
            vim.api.nvim_win_set_cursor(0, { 2, 100 })

            local context = utils.get_context(utils.make_cmp_context(), nil, anchor)

            helpers.expect_truthy(context.opts.anchored, 'forward jump still reuses the warm prefix')
            helpers.expect_truthy(context.opts.suffix_fresh, 'fresh suffix at the new cursor')
            helpers.expect_falsy(
                context.lines_after == prev_after,
                'the stale pre-jump suffix is not reused'
            )

            helpers.delete_buffer(bufnr)
        end,
    },

    {
        name = 'utils.get_context with growth_slack=0 only reuses anchor when cursor has not moved',
        run = function()
            local bufnr, utils = setup_long_buffer(200, 200, {
                config = {
                    context_window = 100,
                    context_ratio = 0.5,
                },
            })

            local baseline = utils.get_context(utils.make_cmp_context())
            local anchor_zero_slack = {
                prev_lines_before = baseline.lines_before,
                prev_lines_after = baseline.lines_after,
                growth_slack = 0,
            }

            -- No edit, no cursor move: still anchored.
            local same = utils.get_context(utils.make_cmp_context(), nil, anchor_zero_slack)
            helpers.expect_truthy(same.opts.anchored)
            helpers.expect_equal(same.lines_before, baseline.lines_before)

            -- One typed char with zero slack must NOT anchor.
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { 'q' })
            vim.api.nvim_win_set_cursor(0, { row, col + 1 })

            local moved = utils.get_context(utils.make_cmp_context(), nil, anchor_zero_slack)
            helpers.expect_falsy(moved.opts.anchored)

            helpers.delete_buffer(bufnr)
        end,
    },

    {
        name = 'utils.get_context falls back when the buffer was edited above the anchor',
        run = function()
            local bufnr, utils = setup_long_buffer(200, 200, {
                config = {
                    context_window = 100,
                    context_ratio = 0.5,
                },
            })

            local baseline = utils.get_context(utils.make_cmp_context())
            local prev_before = baseline.lines_before
            local prev_after = baseline.lines_after

            -- Mutate the first line BEFORE the anchored window: this is what
            -- happens when the user pastes or refactors text earlier in the
            -- file. Anchor lookup should fail because prev_lines_before is
            -- no longer present in the buffer up to the cursor.
            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { string.rep('Q', 200) })
            -- Cursor was at end of line 1; rewriting line 1 changes col, but
            -- we want it back at the end so the basic geometry holds.
            local new_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
            vim.api.nvim_win_set_cursor(0, { 1, #new_line })

            local anchor = {
                prev_lines_before = prev_before,
                prev_lines_after = prev_after,
                growth_slack = 1024,
            }

            local context = utils.get_context(utils.make_cmp_context(), nil, anchor)
            helpers.expect_falsy(context.opts.anchored)

            helpers.delete_buffer(bufnr)
        end,
    },

    {
        name = 'utils.get_context does not anchor when the whole file fits in the context window',
        run = function()
            -- ~120 chars total against a 16000 budget never truncates, so the
            -- fresh window is already prefix-stable and the anchor must stay
            -- out of the way -- there is no KV cache to save and pinning could
            -- only clip text inserted above the cursor.
            local bufnr, utils = setup_long_buffer(60, 60, {
                config = {
                    context_window = 16000,
                    context_ratio = 0.75,
                },
            })

            local baseline = utils.get_context(utils.make_cmp_context())
            local anchor = {
                prev_lines_before = baseline.lines_before,
                prev_lines_after = baseline.lines_after,
                growth_slack = 1024,
            }

            -- Even with no edit and no cursor move, a short file must not take
            -- the anchored path.
            local same = utils.get_context(utils.make_cmp_context(), nil, anchor)
            helpers.expect_falsy(same.opts.anchored)

            helpers.delete_buffer(bufnr)
        end,
    },

    {
        name = 'utils.get_context keeps a title inserted above the cursor in a short file',
        run = function()
            local bufnr, utils = setup_long_buffer(60, 60, {
                config = {
                    context_window = 16000,
                    context_ratio = 0.75,
                },
            })

            local baseline = utils.get_context(utils.make_cmp_context())
            local anchor = {
                prev_lines_before = baseline.lines_before,
                prev_lines_after = baseline.lines_after,
                growth_slack = 1024,
            }

            -- User jumps to the top, adds a title, then returns to the same
            -- content spot (now one row lower) with the stale middle anchor
            -- still in hand. The freshly added title must survive into
            -- lines_before instead of being clipped by the anchor.
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { 'TITLE_INSERTED_ABOVE' })
            vim.api.nvim_win_set_cursor(0, { row + 1, col })

            local context = utils.get_context(utils.make_cmp_context(), nil, anchor)
            helpers.expect_falsy(context.opts.anchored)
            helpers.expect_truthy(context.lines_before:find('TITLE_INSERTED_ABOVE', 1, true) ~= nil)

            helpers.delete_buffer(bufnr)
        end,
    },
}
