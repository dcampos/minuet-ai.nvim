-- Repro for the Typst plot()/mark:none Mercury prompt issue.
--
-- It does not call a model. It loads the copied task file, normalizes the first
-- lq.plot call to a base state, replays the user's described edits through the
-- real duet session tracker, then writes the exact Mercury prompt sections to a
-- timestamped repo-local tmp/ directory.
--
-- Run:
--   nvim --headless -u NONE -i NONE -n \
--     -c "luafile experiments/duet-nes/scripts/plot_mark_prompt_repro.lua" -c "qa!"

local dev = vim.fn.getcwd()
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')

require('minuet').setup {
    duet = {
        provider = 'inception_edit',
        provider_options = {
            inception_edit = {
                model = 'mercury-edit-2',
                api_key = 'INCEPTION_API_KEY',
                end_point = 'https://api.inceptionlabs.ai/v1/edit/completions',
                lines_before = 5,
                lines_after = 10,
                max_editable_lines = 25,
                snippet_count = 3,
                snippet_radius = 10,
                max_siblings = 4,
                git_diff_max_bytes = 8000,
            },
        },
    },
}

local session = require 'minuet.duet.session'

local fixture = dev .. '/experiments/duet-nes/fixtures/plot_mark_repro_main.typ'
local outdir = dev .. '/tmp/duet-plot-mark-repro_' .. os.date '%Y-%m-%d_%H-%M-%S'
vim.fn.mkdir(outdir, 'p')

local function read_fixture()
    return vim.fn.readfile(fixture)
end

local function first_plot_range(lines)
    local start
    for i, line in ipairs(lines) do
        if line:find('lq%.plot%(', 1) then
            start = i
            break
        end
    end
    assert(start, 'fixture has no lq.plot call')
    for i = start, #lines do
        if lines[i]:match '^%s*%),%s*$' then
            return start, i
        end
    end
    error 'could not find end of first lq.plot call'
end

local function with_first_plot(lines, block)
    local start, finish = first_plot_range(lines)
    local out = {}
    for i = 1, start - 1 do
        out[#out + 1] = lines[i]
    end
    vim.list_extend(out, block)
    for i = finish + 1, #lines do
        out[#out + 1] = lines[i]
    end
    return out, start
end

local single_plot = {
    '  lq.plot(x1, y1),',
}

local split_plot = {
    '  lq.plot(',
    '    x1,',
    '    y1,',
    '  ),',
}

local marked_plot = {
    '  lq.plot(',
    '    x1,',
    '    y1,',
    '    mark: none,',
    '  ),',
}

local function tag_body(prompt, tag)
    local open = '<|' .. tag .. '|>'
    local close = '<|/' .. tag .. '|>'
    return prompt:match(vim.pesc(open) .. '\n(.-)\n' .. vim.pesc(close)) or ''
end

local function run_case(name, start_block, edits)
    local base_lines, plot_start = with_first_plot(read_fixture(), start_block)
    local bufnr = vim.api.nvim_create_buf(true, true)
    vim.bo[bufnr].buftype = ''
    vim.api.nvim_buf_set_name(bufnr, fixture)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, base_lines)
    vim.api.nvim_win_set_cursor(0, { plot_start, 2 })

    session.clear(bufnr)
    session.rebase(bufnr)

    local current = base_lines
    for _, edit in ipairs(edits) do
        current, plot_start = with_first_plot(current, edit.block)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, current)
        vim.api.nvim_win_set_cursor(0, { plot_start + edit.cursor_offset, edit.cursor_col })
        session.capture(bufnr, 8)
    end

    local prompt, region = session.build_inception_edit_turn(bufnr, {
        lines_before = 5,
        lines_after = 10,
        max_editable_lines = 25,
        snippet_count = 3,
        snippet_radius = 10,
        max_siblings = 4,
        git_diff_max_bytes = 8000,
    })
    local code_to_edit = tag_body(prompt, 'code_to_edit')
    local edit_history = tag_body(prompt, 'edit_diff_history')
    local snippets = tag_body(prompt, 'recently_viewed_code_snippets')

    local dir = outdir .. '/' .. name
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile(vim.split(prompt, '\n', { plain = true }), dir .. '/prompt.txt')
    vim.fn.writefile(vim.split(code_to_edit, '\n', { plain = true }), dir .. '/code_to_edit.txt')
    vim.fn.writefile(vim.split(edit_history, '\n', { plain = true }), dir .. '/edit_diff_history.txt')
    vim.fn.writefile(vim.split(snippets, '\n', { plain = true }), dir .. '/recently_viewed_code_snippets.txt')

    local summary = {
        name = name,
        region = region,
        diff_entries = session.diff_entries(bufnr),
        has_staged_git_diff = prompt:find('code_snippet_file_path: staged_git_diff', 1, true) ~= nil,
        full_prompt_has_incomplete_tableau = prompt:find('x_5,', 1, true) ~= nil,
        code_to_edit_has_incomplete_tableau = code_to_edit:find('x_5,', 1, true) ~= nil,
        history_has_incomplete_tableau = edit_history:find('x_5,', 1, true) ~= nil,
        history_has_mark_addition = edit_history:find('+    mark: none,', 1, true) ~= nil,
        history_has_mark_deletion = edit_history:find('-    mark: none,', 1, true) ~= nil,
        history_has_join_deletion = edit_history:find('-    x1,', 1, true) ~= nil
            and edit_history:find('-    y1,', 1, true) ~= nil,
        history_has_join_addition = edit_history:find('+  lq.plot(x1, y1),', 1, true) ~= nil,
    }
    vim.fn.writefile({ vim.json.encode(summary) }, dir .. '/summary.json')
    vim.api.nvim_buf_delete(bufnr, { force = true })
    return summary
end

local cases = {
    run_case('split_then_mark', single_plot, {
        { block = split_plot, cursor_offset = 2, cursor_col = 6 },
        { block = marked_plot, cursor_offset = 3, cursor_col = 14 },
    }),
    run_case('delete_mark_then_join', marked_plot, {
        { block = split_plot, cursor_offset = 2, cursor_col = 6 },
        { block = single_plot, cursor_offset = 0, cursor_col = 16 },
    }),
}

vim.fn.writefile({ vim.json.encode(cases) }, outdir .. '/summary.json')

print('wrote ' .. vim.fn.fnamemodify(outdir, ':.'))
for _, s in ipairs(cases) do
    print(
        ('%s region=%d-%d entries=%d git=%s code_to_edit_tableau=%s history_tableau=%s mark_add=%s mark_del=%s join_del=%s join_add=%s'):format(
            s.name,
            s.region.start_row,
            s.region.end_row,
            #s.diff_entries,
            tostring(s.has_staged_git_diff),
            tostring(s.code_to_edit_has_incomplete_tableau),
            tostring(s.history_has_incomplete_tableau),
            tostring(s.history_has_mark_addition),
            tostring(s.history_has_mark_deletion),
            tostring(s.history_has_join_deletion),
            tostring(s.history_has_join_addition)
        )
    )
end
