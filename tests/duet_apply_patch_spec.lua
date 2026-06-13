local helpers = require 'tests.helpers'

local ap = require 'minuet.duet.apply_patch'

local function patch(body)
    return '*** Begin Patch\n' .. body .. '\n*** End Patch'
end

return {
    {
        name = 'apply_patch.parse rejects a missing Begin marker',
        run = function()
            local hunks, err = ap.parse 'bad'
            helpers.expect_falsy(hunks)
            helpers.expect_equal(err, "invalid patch: The first line of the patch must be '*** Begin Patch'")
        end,
    },
    {
        name = 'apply_patch.parse rejects a missing End marker',
        run = function()
            local hunks, err = ap.parse '*** Begin Patch\nbad'
            helpers.expect_falsy(hunks)
            helpers.expect_equal(err, "invalid patch: The last line of the patch must be '*** End Patch'")
        end,
    },
    {
        name = 'apply_patch.parse reads a context + move update hunk (Codex vector)',
        run = function()
            local hunks, err = ap.parse(patch(
                '*** Update File: path/update.py\n'
                    .. '*** Move to: path/update2.py\n'
                    .. '@@ def f():\n'
                    .. '-    pass\n'
                    .. '+    return 123'
            ))
            helpers.expect_falsy(err)
            helpers.expect_equal(#hunks, 1)
            local h = hunks[1]
            helpers.expect_equal(h.kind, 'update')
            helpers.expect_equal(h.path, 'path/update.py')
            helpers.expect_equal(h.move_path, 'path/update2.py')
            helpers.expect_equal(#h.chunks, 1)
            helpers.expect_equal(h.chunks[1].change_context, 'def f():')
            helpers.expect_equal(h.chunks[1].old_lines, { '    pass' })
            helpers.expect_equal(h.chunks[1].new_lines, { '    return 123' })
            helpers.expect_equal(h.chunks[1].is_end_of_file, false)
        end,
    },
    {
        name = 'apply_patch.parse accepts an update hunk without a @@ header (context line)',
        run = function()
            local hunks, err = ap.parse(patch '*** Update File: file2.py\n import foo\n+bar')
            helpers.expect_falsy(err)
            helpers.expect_equal(hunks[1].chunks[1].change_context, nil)
            helpers.expect_equal(hunks[1].chunks[1].old_lines, { 'import foo' })
            helpers.expect_equal(hunks[1].chunks[1].new_lines, { 'import foo', 'bar' })
        end,
    },
    {
        name = 'apply_patch.parse preserves the End of File marker',
        run = function()
            local hunks, err = ap.parse(patch '*** Update File: file.txt\n@@\n+quux\n*** End of File')
            helpers.expect_falsy(err)
            helpers.expect_equal(hunks[1].chunks[1].is_end_of_file, true)
            helpers.expect_equal(hunks[1].chunks[1].new_lines, { 'quux' })
        end,
    },
    {
        name = 'apply_patch.parse reports an empty update hunk with the Codex message',
        run = function()
            local hunks, err = ap.parse(patch '*** Update File: test.py')
            helpers.expect_falsy(hunks)
            helpers.expect_equal(err, "invalid hunk at line 2, Update file hunk for path 'test.py' is empty")
        end,
    },
    {
        name = 'apply_patch.parse rejects two consecutive context markers',
        run = function()
            local hunks, err = ap.parse(patch '*** Update File: file.txt\n@@\n@@')
            helpers.expect_falsy(hunks)
            helpers.expect_match(err, '^invalid hunk at line 4, Unexpected line found in update hunk')
        end,
    },
    {
        name = 'apply_patch.parse rejects a stray line after a removal',
        run = function()
            local hunks, err = ap.parse(patch '*** Update File: file.txt\n@@\n-old\nbad')
            helpers.expect_falsy(hunks)
            helpers.expect_equal(
                err,
                "invalid hunk at line 5, Expected update hunk to start with a @@ context marker, got: 'bad'"
            )
        end,
    },

    -- Applier ----------------------------------------------------------------
    {
        name = 'apply_patch.apply replaces a line located by @@ context',
        run = function()
            local ok, lines = ap.apply(
                { 'def f():', '    pass' },
                patch '*** Update File: x.py\n@@ def f():\n-    pass\n+    return 123'
            )
            helpers.expect_truthy(ok)
            helpers.expect_equal(lines, { 'def f():', '    return 123' })
        end,
    },
    {
        name = 'apply_patch.apply replaces a line located by a context line',
        run = function()
            local ok, lines = ap.apply({ 'import foo' }, patch '*** Update File: x.py\n import foo\n+bar')
            helpers.expect_truthy(ok)
            helpers.expect_equal(lines, { 'import foo', 'bar' })
        end,
    },
    {
        name = 'apply_patch.apply appends a pure addition at end of file',
        run = function()
            local ok, lines = ap.apply({ 'a', 'b' }, patch '*** Update File: x\n@@\n+c')
            helpers.expect_truthy(ok)
            helpers.expect_equal(lines, { 'a', 'b', 'c' })
        end,
    },
    {
        name = 'apply_patch.apply fails clearly when context is missing',
        run = function()
            local ok, lines, err = ap.apply({ 'a', 'b' }, patch '*** Update File: x\n@@ nope\n-a\n+z')
            helpers.expect_falsy(ok)
            helpers.expect_falsy(lines)
            helpers.expect_match(err, "^Failed to find context 'nope' in x")
        end,
    },
    {
        name = 'apply_patch.apply fails clearly when old lines are missing',
        run = function()
            local ok, _, err = ap.apply({ 'a', 'b' }, patch '*** Update File: x\n@@\n-zzz\n+q')
            helpers.expect_falsy(ok)
            helpers.expect_match(err, '^Failed to find expected lines in x:\nzzz')
        end,
    },
    {
        name = 'apply_patch.apply rejects Add File hunks (Update File only in v1)',
        run = function()
            local ok, _, err = ap.apply({ 'a' }, patch '*** Add File: new.txt\n+hello')
            helpers.expect_falsy(ok)
            helpers.expect_match(err, 'supports only')
        end,
    },
    {
        name = 'apply_patch.apply renames only the next occurrence (NES single small edit)',
        run = function()
            local ok, lines = ap.apply(
                { 'local x = old_name', 'local y = old_name' },
                patch '*** Update File: x.lua\n@@\n-local x = old_name\n+local x = new_name'
            )
            helpers.expect_truthy(ok)
            helpers.expect_equal(lines, { 'local x = new_name', 'local y = old_name' })
        end,
    },
    {
        name = 'apply_patch.seek_sequence honours exact / rstrip / trim tiers',
        run = function()
            helpers.expect_equal(ap.seek_sequence({ 'foo', 'bar', 'baz' }, { 'bar', 'baz' }, 0, false), 1)
            helpers.expect_equal(ap.seek_sequence({ 'foo   ', 'bar\t\t' }, { 'foo', 'bar' }, 0, false), 0)
            helpers.expect_equal(ap.seek_sequence({ '    foo   ', '   bar\t' }, { 'foo', 'bar' }, 0, false), 0)
            helpers.expect_equal(ap.seek_sequence({ 'one' }, { 'a', 'b', 'c' }, 0, false), nil)
        end,
    },
}
