-- Before/after fixtures for the duet NES preview renderer, used by the visual
-- harness to produce screenshots without any model/API call.
--
-- Each fixture:
--   filetype : buffer filetype (drives base-buffer treesitter highlighting)
--   original : current buffer lines (the "before" state)
--   proposed : predicted lines (the "after" state)
--   cursor   : optional { row_offset = <0-based proposed row>, col = <byte col> }
--   opts     : optional overrides merged into config.duet.preview
--   select   : if true, call select_next_chunk once (reveals a hidden block)
--   focus    : optional state.preview_focus value
--   note     : human description of what this case stresses
return {
    word_swap = {
        note = 'two inline word changes on one line',
        filetype = 'lua',
        original = { 'return alpha + beta' },
        proposed = { 'return omega + gamma' },
    },

    snake_case = {
        note = 'snake_case partial change (user_id -> user_name)',
        filetype = 'lua',
        original = { 'local user_id = row.user_id' },
        proposed = { 'local user_name = row.user_name' },
    },

    camel_case = {
        note = 'camelCase subword change (getUserId -> getUserName)',
        filetype = 'lua',
        original = { 'local id = getUserId()' },
        proposed = { 'local id = getUserName()' },
    },

    block_insert = {
        note = 'inserted line inside a replacement block',
        filetype = 'lua',
        original = { 'foo(1)', 'bar(2)' },
        proposed = { 'log()', 'foo(1)', 'bar(3)' },
        select = true,
    },

    block_rewrite = {
        note = 'multi-line block replacement (treesitter foreground color demo)',
        filetype = 'lua',
        original = { 'x()', 'y()', 'z()' },
        proposed = {
            'local function handler(req, res)',
            '    local body = decode(req.body)',
            '    return res:json({ ok = true, id = body.id })',
            'end',
        },
        select = true,
    },

    func_rewrite = {
        note = 'multi-line function body change with strings/keywords (TS color demo)',
        filetype = 'lua',
        original = {
            'local function greet(name)',
            '    return "hi " .. name',
            'end',
        },
        proposed = {
            'local function greet(name, punct)',
            '    punct = punct or "!"',
            '    return "hello, " .. name .. punct',
            'end',
        },
        select = true,
    },
}
