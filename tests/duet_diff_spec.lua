local helpers = require 'tests.helpers'

local opts = {
    block_chunk_size = 10,
    inline_max_groups = 2,
    inline_max_edit_ratio = 0.9,
    line_pair_min_similarity = 0.35,
}

local range = { start_row = 0 }

return {
    {
        name = 'duet.diff compatibility level 2 accepts chunk-prefix progress only',
        run = function()
            helpers.ensure_runtime()
            local diff = helpers.reload 'minuet.duet.diff'
            local original = { 'return alpha + beta' }
            local proposed = { 'return omega + gamma' }

            helpers.expect_truthy(
                diff.compatible_progress(original, { 'return omega + beta' }, proposed, range, opts, 2)
            )
            helpers.expect_falsy(
                diff.compatible_progress(original, { 'return omeha + beta' }, proposed, range, opts, 2)
            )
        end,
    },
    {
        name = 'duet.diff compatibility level 3 accepts partial insertions',
        run = function()
            helpers.ensure_runtime()
            local diff = helpers.reload 'minuet.duet.diff'
            local original = { 'return ' }
            local proposed = { 'return value' }

            helpers.expect_truthy(diff.compatible_progress(original, { 'return val' }, proposed, range, opts, 3))
        end,
    },
    {
        name = 'duet.diff compatibility level 4 accepts aligned partial replacements and deletions',
        run = function()
            helpers.ensure_runtime()
            local diff = helpers.reload 'minuet.duet.diff'

            helpers.expect_falsy(
                diff.compatible_progress({ 'return cat' }, { 'return dot' }, { 'return dog' }, range, opts, 3)
            )
            helpers.expect_truthy(
                diff.compatible_progress({ 'return cat' }, { 'return dot' }, { 'return dog' }, range, opts, 4)
            )
            helpers.expect_truthy(
                diff.compatible_progress({ 'return foobar' }, { 'return bar' }, { 'return ' }, range, opts, 4)
            )
            helpers.expect_falsy(
                diff.compatible_progress({ 'return cat' }, { 'return dox' }, { 'return dog' }, range, opts, 4)
            )
        end,
    },
}
