-- Deterministic scenarios for the duet NES (next-edit-suggestion) demo.
--
-- Each scenario is a tiny coding moment: a starting code block plus an ordered
-- list of `steps`. A step is the full replacement for that scenario's code
-- block; the demo returns it as a real duet direct_edit region while all other
-- examples remain visible in the same buffer. No model, no network -- the
-- mocked chat backend just serves the next step.
--
-- Fields:
--   name     : stable id
--   title    : short label (shown in the winbar)
--   blurb    : one-line description (echoed when the scenario loads)
--   filetype : drives base-buffer + proposed treesitter highlighting (use a
--              filetype with a bundled parser -- lua is always safe)
--   lines    : starting buffer
--   cursor   : optional { row (1-based), col (0-based byte) } start position
--   steps    : ordered list of { note, after } where `after` is the proposed
--              code block for that step
--
-- The steps are authored so that accepting step k leaves the buffer equal to
-- step k's `after`, which is the diff base for step k+1. Keep each step a small,
-- believable next edit.
return {
    {
        name = 'finish_at_cursor',
        title = 'Finish the edit at the cursor',
        blurb = 'A single inline fix the model finishes for you (one <Tab> accepts).',
        filetype = 'lua',
        cursor = { 2, 0 },
        lines = {
            'local function area(w, h)',
            '    return w * w',
            'end',
        },
        steps = {
            {
                note = 'Typo on the return line: NES rewrites `w * w` as `w * h`.',
                after = {
                    'local function area(w, h)',
                    '    return w * h',
                    'end',
                },
            },
        },
    },

    {
        name = 'rename_propagation',
        title = 'Rename propagates to every use',
        blurb = 'You renamed the local once; NES carries it to the remaining sites.',
        filetype = 'lua',
        cursor = { 1, 6 },
        -- The definition on line 1 was already renamed count -> total (the user's
        -- own edit). The two remaining uses (lines 3 and 5, separated by an
        -- unchanged line) are a two-hunk prediction: <Tab> jumps to the first,
        -- accepting it auto-advances to the second.
        lines = {
            'local total = 0',
            'log("start")',
            'count = count + 1',
            'log("mid")',
            'print(count)',
        },
        steps = {
            {
                note = 'Two remaining uses of `count`: <Tab> jumps to the first, accept auto-advances to the next.',
                after = {
                    'local total = 0',
                    'log("start")',
                    'total = total + 1',
                    'log("mid")',
                    'print(total)',
                },
            },
        },
    },

    {
        name = 'block_insert',
        title = 'Insert a guard block',
        blurb = 'A multi-line insertion stays collapsed to a blue square until you navigate in.',
        filetype = 'lua',
        cursor = { 1, 0 },
        lines = {
            'local function div(a, b)',
            '    return a / b',
            'end',
        },
        steps = {
            {
                note = 'Collapsed as a blue square: first <Tab> reveals the inserted lines, second accepts.',
                after = {
                    'local function div(a, b)',
                    '    if b == 0 then',
                    '        return 0',
                    '    end',
                    '    return a / b',
                    'end',
                },
            },
        },
    },

    {
        name = 'block_rewrite',
        title = 'Rewrite a stub body',
        blurb = 'A stub replacement with mixed inline/body changes; proposed code is treesitter-colored.',
        filetype = 'lua',
        cursor = { 2, 0 },
        lines = {
            'local function handler(req)',
            '    -- TODO: implement',
            'end',
        },
        steps = {
            {
                note = 'Stub rewrite: signature and body changes render together with syntax-colored additions.',
                after = {
                    'local function handler(req, res)',
                    '    return res:json({ ok = true, body = decode(req.body) })',
                    'end',
                },
            },
        },
    },

    {
        name = 'string_and_number',
        title = 'Edits inside strings and numbers',
        blurb = 'Two steps: a word changed inside a string, then a numeric literal.',
        filetype = 'lua',
        cursor = { 1, 0 },
        -- The numeric edit keeps a trailing comment so the change is mid-line:
        -- an end-of-line insertion would anchor one column past the line end,
        -- where the cursor clamps short and <Tab> can't land on it to accept.
        lines = {
            'print("hello world")',
            'local timeout = 30 -- ms',
        },
        steps = {
            {
                note = 'Inline change inside a string -- the fragment still reads as @string.',
                after = {
                    'print("hello there")',
                    'local timeout = 30 -- ms',
                },
            },
            {
                note = 'Press <CR> for the next edit: a numeric literal (distinct @number color).',
                after = {
                    'print("hello there")',
                    'local timeout = 3000 -- ms',
                },
            },
        },
    },

    {
        name = 'line_continuations',
        title = 'Append line continuations at end of line',
        blurb = 'End-of-line `\\` inserts: <Tab> jumps to each and accepting auto-advances to the next.',
        filetype = 'lua',
        cursor = { 1, 0 },
        -- Every change here is an insertion at the very END of a line (a trailing
        -- ` \`), which anchors one column past the line end -- exactly where the
        -- normal-mode cursor clamps short. Two lines already carry the `\`; NES
        -- proposes the rest (including turning the blank separator into a bare
        -- `\`) so you can <Tab> through and accept each end-of-line insert in turn.
        lines = {
            '$',
            "x' = 0 \\",
            '=> 2x - 2x^2 + x y = 0 \\',
            '=> x(2 - 2x + y) = 0',
            '=> x = 0 "ó" 2x - y = +2',
            '',
            "y' = 0",
            '=> 2y - 2y^2 + x y = 0',
            '=> y(2 - 2y + x) = 0',
            '=> y = 0 "ó" 2y - x = +2',
            '$',
        },
        steps = {
            {
                note = 'Trailing `\\` inserts: <Tab> jumps to the first, accept auto-advances through the rest.',
                after = {
                    '$',
                    "x' = 0 \\",
                    '=> 2x - 2x^2 + x y = 0 \\',
                    '=> x(2 - 2x + y) = 0 \\',
                    '=> x = 0 "ó" 2x - y = +2 \\',
                    '\\',
                    "y' = 0 \\",
                    '=> 2y - 2y^2 + x y = 0 \\',
                    '=> y(2 - 2y + x) = 0 \\',
                    '=> y = 0 "ó" 2y - x = +2',
                    '$',
                },
            },
        },
    },

    {
        name = 'deletions',
        title = 'Delete a line, then trim arguments',
        blurb = 'Two steps showing whole-line deletion then an inline deletion.',
        filetype = 'lua',
        cursor = { 1, 0 },
        lines = {
            'debug_print("trace")',
            'local x = compute(a, b, c, d)',
        },
        steps = {
            {
                note = 'Whole-line deletion: the removed line is highlighted before you accept it.',
                after = {
                    'local x = compute(a, b, c, d)',
                },
            },
            {
                note = 'Press <CR> for the next edit: an inline deletion of the extra arguments.',
                after = {
                    'local x = compute(a, b)',
                },
            },
        },
    },
}
