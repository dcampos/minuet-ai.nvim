local api = vim.api
local utils = require 'minuet.duet.utils'
local M = {}

M.ns_id = api.nvim_create_namespace 'minuet.duet'

local LINE_HL_PRIORITY = 100
local TEXT_HL_PRIORITY = 110

local default_highlights = {
    MinuetDuetAdd = { link = 'DiffAdd' },
    MinuetDuetAddText = { bg = 0x2f6f54 },
    MinuetDuetDelete = { link = 'DiffDelete' },
    MinuetDuetDeleteText = { bg = 0x9a3f55 },
    MinuetDuetComment = { link = 'Comment' },
    MinuetDuetCursor = { link = 'IncSearch' },
}

for hl_group, default_hl in pairs(default_highlights) do
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = hl_group })) then
        api.nvim_set_hl(0, hl_group, default_hl)
    end
end

---@diagnostic disable-next-line: deprecated
local diff = (vim.text and vim.text.diff) or vim.diff

---@alias MinuetDuetHunk integer[]

---@return MinuetDuetHunk[]
local function get_hunks(state)
    local original
    if not state.original_lines or #state.original_lines == 0 then
        original = ''
    else
        original = table.concat(state.original_lines, '\n') .. '\n'
    end

    local proposed
    if not state.proposed_lines or #state.proposed_lines == 0 then
        proposed = ''
    else
        proposed = table.concat(state.proposed_lines, '\n') .. '\n'
    end

    local hunks = diff(original, proposed, {
        result_type = 'indices',
        algorithm = 'histogram',
        linematch = true,
        ignore_whitespace = false,
        ignore_whitespace_change = false,
        ignore_whitespace_change_at_eol = false,
        ignore_blank_lines = false,
    })

    -- make the LSP type checking happy.
    if type(hunks) == 'string' or hunks == nil then
        return {}
    end
    return hunks
end

local function add_extmark(bufnr, state, row, opts, col)
    state.extmark_ids = state.extmark_ids or {}
    local extmark_id = api.nvim_buf_set_extmark(bufnr, M.ns_id, row, col or 0, opts)
    table.insert(state.extmark_ids, extmark_id)
end

--- Build styled chunks for a proposed line, inserting the cursor character
--- when the cursor falls on this line.
---@param text string the proposed line content
---@param hl_group string highlight group for the text
---@param cursor_col integer|nil byte column of cursor on this line, nil if cursor is elsewhere
---@param cursor_char string the cursor character to render
---@return table[] chunks list of {text, hl_group} pairs
local function make_chunks(text, hl_group, cursor_col, cursor_char)
    if not cursor_col then
        return { { text, hl_group } }
    end
    local before = text:sub(1, cursor_col)
    local after = text:sub(cursor_col + 1)
    local chunks = {}
    if #before > 0 then
        table.insert(chunks, { before, hl_group })
    end
    table.insert(chunks, { cursor_char, 'MinuetDuetCursor' })
    if #after > 0 then
        table.insert(chunks, { after, hl_group })
    end
    return chunks
end

local function preview_mode(config)
    local mode = ((config.preview or {}).mode or 'inline')
    if mode == 'side-to-side' or mode == 'side_by_side' or mode == 'side-by-side' then
        return 'side_by_side'
    end
    if mode == 'virtual' or mode == 'virtual_lines' or mode == 'virtual-lines' then
        return 'virtual_lines'
    end
    return 'inline'
end

local cursor_col_for

---@param text string
---@param i integer 1-based byte index
---@return integer
local function utf8_char_len(text, i)
    local b = text:byte(i) or 0
    if b < 0x80 then
        return 1
    elseif b < 0xe0 then
        return 2
    elseif b < 0xf0 then
        return 3
    end
    return 4
end

---@param ch string
---@return 'space'|'word'|'punct'
local function token_class(ch)
    if ch:match '^%s+$' then
        return 'space'
    end
    if ch:match '^[%w_]+$' then
        return 'word'
    end
    return 'punct'
end

---@param text string
---@return { text: string, start_col: integer, end_col: integer }[]
local function word_tokens(text)
    local tokens = {}
    local i = 1
    while i <= #text do
        local start = i
        local char_len = utf8_char_len(text, i)
        local class = token_class(text:sub(i, i + char_len - 1))
        i = i + char_len

        if class ~= 'punct' then
            while i <= #text do
                char_len = utf8_char_len(text, i)
                local next_char = text:sub(i, i + char_len - 1)
                if token_class(next_char) ~= class then
                    break
                end
                i = i + char_len
            end
        end

        table.insert(tokens, {
            text = text:sub(start, i - 1),
            start_col = start - 1,
            end_col = i - 1,
        })
    end
    return tokens
end

---@param old_tokens { text: string }[]
---@param new_tokens { text: string }[]
---@return { old_idx: integer, new_idx: integer }[]
local function lcs_pairs(old_tokens, new_tokens)
    local old_n, new_n = #old_tokens, #new_tokens
    local dp = {}
    for i = old_n + 1, 1, -1 do
        dp[i] = {}
        for j = new_n + 1, 1, -1 do
            if i > old_n or j > new_n then
                dp[i][j] = 0
            elseif old_tokens[i].text == new_tokens[j].text then
                dp[i][j] = dp[i + 1][j + 1] + 1
            else
                dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
            end
        end
    end

    local pairs = {}
    local i, j = 1, 1
    while i <= old_n and j <= new_n do
        if old_tokens[i].text == new_tokens[j].text then
            table.insert(pairs, { old_idx = i, new_idx = j })
            i = i + 1
            j = j + 1
        elseif dp[i + 1][j] >= dp[i][j + 1] then
            i = i + 1
        else
            j = j + 1
        end
    end
    return pairs
end

---@param tokens { text: string }[]
---@param first integer
---@param last integer
---@return string
local function token_text(tokens, first, last)
    local parts = {}
    for i = first, last do
        table.insert(parts, tokens[i].text)
    end
    return table.concat(parts)
end

---@param tokens { start_col: integer, end_col: integer }[]
---@param first integer
---@param fallback_col integer
---@return integer
local function gap_col(tokens, first, fallback_col)
    if tokens[first] then
        return tokens[first].start_col
    end
    return fallback_col
end

---@param old_line string
---@param new_line string
---@return table[]
local function word_diff_groups(old_line, new_line)
    local old_tokens = word_tokens(old_line)
    local new_tokens = word_tokens(new_line)
    local pairs = lcs_pairs(old_tokens, new_tokens)
    local groups = {}
    local old_idx, new_idx = 1, 1

    local function add_group(old_last, new_last)
        if old_idx > old_last and new_idx > new_last then
            return
        end

        local old_text = old_idx <= old_last and token_text(old_tokens, old_idx, old_last) or ''
        local new_text = new_idx <= new_last and token_text(new_tokens, new_idx, new_last) or ''
        local old_start_col = old_idx <= old_last and old_tokens[old_idx].start_col or nil
        local old_end_col = old_idx <= old_last and old_tokens[old_last].end_col or nil
        local new_start_col = new_idx <= new_last and new_tokens[new_idx].start_col or nil
        local new_end_col = new_idx <= new_last and new_tokens[new_last].end_col or nil
        local insert_col = gap_col(old_tokens, old_idx, #old_line)

        table.insert(groups, {
            old_text = old_text,
            new_text = new_text,
            old_start_col = old_start_col,
            old_end_col = old_end_col,
            new_start_col = new_start_col,
            new_end_col = new_end_col,
            insert_col = insert_col,
        })
    end

    for _, pair in ipairs(pairs) do
        add_group(pair.old_idx - 1, pair.new_idx - 1)
        old_idx = pair.old_idx + 1
        new_idx = pair.new_idx + 1
    end
    add_group(#old_tokens, #new_tokens)

    return groups
end

---@param text string
---@param text_start_col integer
---@param cursor_col integer|nil
---@param cursor_char string
---@return table[] chunks
---@return boolean cursor_rendered
local function add_chunks_with_cursor(text, text_start_col, cursor_col, cursor_char)
    if not cursor_col or cursor_col < text_start_col or cursor_col > text_start_col + #text then
        return { { text, 'MinuetDuetAdd' } }, false
    end

    local rel = cursor_col - text_start_col
    local before = text:sub(1, rel)
    local after = text:sub(rel + 1)
    local chunks = {}
    if #before > 0 then
        table.insert(chunks, { before, 'MinuetDuetAdd' })
    end
    table.insert(chunks, { cursor_char, 'MinuetDuetCursor' })
    if #after > 0 then
        table.insert(chunks, { after, 'MinuetDuetAdd' })
    end
    return chunks, true
end

local function render_side_by_side_line(bufnr, state, row, old_line, new_line, proposed_idx, cursor_char)
    local cursor_col = cursor_col_for(state, proposed_idx)
    local cursor_rendered = false

    for _, group in ipairs(word_diff_groups(old_line, new_line)) do
        if group.old_start_col and group.old_end_col and group.old_end_col > group.old_start_col then
            add_extmark(bufnr, state, row, {
                end_col = group.old_end_col,
                hl_group = 'MinuetDuetDelete',
            }, group.old_start_col)
        end

        if group.new_text ~= '' then
            local text_start_col = group.new_start_col or 0
            local chunks, has_cursor = add_chunks_with_cursor(group.new_text, text_start_col, cursor_col, cursor_char)
            cursor_rendered = cursor_rendered or has_cursor
            add_extmark(bufnr, state, row, {
                virt_text = chunks,
                virt_text_pos = 'inline',
            }, group.old_end_col or group.insert_col)
        end
    end

    if cursor_col and not cursor_rendered then
        add_extmark(bufnr, state, row, {
            virt_text = { { cursor_char, 'MinuetDuetCursor' } },
            virt_text_pos = 'inline',
        }, math.min(cursor_col, #old_line))
    end
end

--- Return the cursor column if the proposed line at `proposed_idx` (0-based)
--- carries the cursor, otherwise nil.
function cursor_col_for(state, proposed_idx)
    local c = state.proposed_cursor
    if not c then
        return nil
    end
    if proposed_idx == c.row_offset then
        return c.col
    end
    return nil
end

local function render_inserted_lines(bufnr, state, row, lines, proposed_indices, cursor_char, above)
    if #lines == 0 then
        return
    end

    local virt_lines = {}
    for i, line in ipairs(lines) do
        local col = cursor_col_for(state, proposed_indices[i])
        local chunks = make_chunks(line, 'MinuetDuetAdd', col, cursor_char)
        table.insert(virt_lines, chunks)
    end

    add_extmark(bufnr, state, row, {
        virt_lines = virt_lines,
        virt_lines_above = above or false,
    })
end

local function push_chunk(chunks, text, hl_group)
    if #text > 0 then
        table.insert(chunks, { text, hl_group })
    end
end

local function push_chunk_range(chunks, text, start_col, end_col, hl_group, cursor_col, cursor_char)
    if cursor_col and cursor_col >= start_col and cursor_col <= end_col and start_col < end_col then
        push_chunk(chunks, text:sub(start_col + 1, cursor_col), hl_group)
        table.insert(chunks, { cursor_char, 'MinuetDuetCursor' })
        push_chunk(chunks, text:sub(cursor_col + 1, end_col), hl_group)
        return true
    end

    push_chunk(chunks, text:sub(start_col + 1, end_col), hl_group)
    return false
end

---@param spans { start_col: integer, end_col: integer, hl_group: string }[]
local function make_span_chunks(text, base_hl_group, spans, cursor_col, cursor_char)
    local chunks = {}
    local pos = 0
    local cursor_rendered = false

    table.sort(spans, function(a, b)
        if a.start_col ~= b.start_col then
            return a.start_col < b.start_col
        end
        return a.end_col < b.end_col
    end)

    for _, span in ipairs(spans) do
        local start_col = math.max(pos, math.min(span.start_col, #text))
        local end_col = math.max(start_col, math.min(span.end_col, #text))
        cursor_rendered = push_chunk_range(chunks, text, pos, start_col, base_hl_group, cursor_col, cursor_char)
            or cursor_rendered
        cursor_rendered = push_chunk_range(chunks, text, start_col, end_col, span.hl_group, cursor_col, cursor_char)
            or cursor_rendered
        pos = end_col
    end

    cursor_rendered = push_chunk_range(chunks, text, pos, #text, base_hl_group, cursor_col, cursor_char)
        or cursor_rendered

    if cursor_col and not cursor_rendered then
        table.insert(chunks, { cursor_char, 'MinuetDuetCursor' })
    end
    if #chunks == 0 then
        table.insert(chunks, { text, base_hl_group })
    end
    return chunks
end

local function proposed_line_chunks(old_line, new_line, cursor_col, cursor_char)
    local spans = {}
    for _, group in ipairs(word_diff_groups(old_line, new_line)) do
        if group.new_start_col and group.new_end_col and group.new_end_col > group.new_start_col then
            table.insert(spans, {
                start_col = group.new_start_col,
                end_col = group.new_end_col,
                hl_group = 'MinuetDuetAddText',
            })
        end
    end

    return make_span_chunks(new_line, 'MinuetDuetAdd', spans, cursor_col, cursor_char)
end

local function render_deleted_line_spans(bufnr, state, row, old_line, new_line)
    for _, group in ipairs(word_diff_groups(old_line, new_line)) do
        if group.old_start_col and group.old_end_col and group.old_end_col > group.old_start_col then
            add_extmark(bufnr, state, row, {
                end_col = group.old_end_col,
                hl_group = 'MinuetDuetDeleteText',
                priority = TEXT_HL_PRIORITY,
            }, group.old_start_col)
        end
    end
end

local function hunk_insertion_anchor(state, original_start, original_count)
    local anchor_row = state.range.start_row + original_start - 1 + math.max(original_count - 1, 0)
    local render_above = false

    if original_count == 0 then
        anchor_row = state.range.start_row
        render_above = original_start == 0
        if original_start > 0 then
            anchor_row = anchor_row + original_start - 1
        end
    end

    return anchor_row, render_above
end

---@param hunk MinuetDuetHunk
local function render_virtual_lines_hunk(bufnr, state, hunk, cursor_char)
    local original_start, original_count, proposed_start, proposed_count = unpack(hunk)
    local pair_count = math.min(original_count, proposed_count)
    local first_buffer_row = state.range.start_row + original_start - 1

    for offset = 0, original_count - 1 do
        local buffer_row = first_buffer_row + offset
        local old_line = state.original_lines[original_start + offset] or ''

        add_extmark(bufnr, state, buffer_row, {
            line_hl_group = 'MinuetDuetDelete',
            priority = LINE_HL_PRIORITY,
        })

        if offset < pair_count then
            local new_line = state.proposed_lines[proposed_start + offset] or ''
            render_deleted_line_spans(bufnr, state, buffer_row, old_line, new_line)
        end
    end

    if proposed_count == 0 then
        return
    end

    local virt_lines = {}
    for offset = 0, proposed_count - 1 do
        local proposed_idx = proposed_start + offset - 1 -- 0-based index into proposed_lines
        local new_line = state.proposed_lines[proposed_start + offset] or ''
        local cursor_col = cursor_col_for(state, proposed_idx)

        if offset < pair_count then
            local old_line = state.original_lines[original_start + offset] or ''
            table.insert(virt_lines, proposed_line_chunks(old_line, new_line, cursor_col, cursor_char))
        else
            table.insert(virt_lines, make_chunks(new_line, 'MinuetDuetAdd', cursor_col, cursor_char))
        end
    end

    local anchor_row, render_above = hunk_insertion_anchor(state, original_start, original_count)
    add_extmark(bufnr, state, anchor_row, {
        virt_lines = virt_lines,
        virt_lines_above = render_above,
    })
end

---@param hunks MinuetDuetHunk[]
---@return MinuetDuetHunk[]
local function coalesce_virtual_line_hunks(hunks)
    local out = {}
    for _, hunk in ipairs(hunks) do
        local last = out[#out]
        if last and hunk[1] <= last[1] + last[2] and hunk[3] <= last[3] + last[4] then
            local original_end = math.max(last[1] + last[2], hunk[1] + hunk[2])
            local proposed_end = math.max(last[3] + last[4], hunk[3] + hunk[4])
            last[2] = original_end - last[1]
            last[4] = proposed_end - last[3]
        else
            table.insert(out, { hunk[1], hunk[2], hunk[3], hunk[4] })
        end
    end
    return out
end

---@param hunk MinuetDuetHunk
local function render_hunk(bufnr, state, hunk, cursor_char, mode)
    local original_start, original_count, proposed_start, proposed_count = unpack(hunk)
    local pair_count = math.min(original_count, proposed_count)
    local first_buffer_row = state.range.start_row + original_start - 1

    if mode == 'virtual_lines' then
        render_virtual_lines_hunk(bufnr, state, hunk, cursor_char)
        return
    end

    for offset = 0, pair_count - 1 do
        local buffer_row = first_buffer_row + offset
        local buffer_line = api.nvim_buf_get_lines(bufnr, buffer_row, buffer_row + 1, false)[1] or ''
        local proposed_line = state.proposed_lines[proposed_start + offset] or ''
        local proposed_idx = proposed_start + offset - 1 -- 0-based index into proposed_lines

        if mode == 'side_by_side' then
            render_side_by_side_line(bufnr, state, buffer_row, buffer_line, proposed_line, proposed_idx, cursor_char)
        else
            local col = cursor_col_for(state, proposed_idx)
            local chunks = make_chunks(proposed_line, 'MinuetDuetAdd', col, cursor_char)
            add_extmark(bufnr, state, buffer_row, {
                end_col = #buffer_line,
                hl_group = 'MinuetDuetDelete',
                virt_text = chunks,
                virt_text_pos = 'eol',
            })
        end
    end

    for offset = pair_count, original_count - 1 do
        local buffer_row = first_buffer_row + offset
        local buffer_line = api.nvim_buf_get_lines(bufnr, buffer_row, buffer_row + 1, false)[1] or ''
        add_extmark(bufnr, state, buffer_row, {
            end_col = #buffer_line,
            hl_group = 'MinuetDuetDelete',
        })
    end

    if proposed_count > pair_count then
        local inserted_lines = {}
        local proposed_indices = {}
        for offset = pair_count, proposed_count - 1 do
            table.insert(inserted_lines, state.proposed_lines[proposed_start + offset] or '')
            table.insert(proposed_indices, proposed_start + offset - 1) -- 0-based
        end

        local insertion_anchor_row, render_above = hunk_insertion_anchor(state, original_start, original_count)

        render_inserted_lines(
            bufnr,
            state,
            insertion_anchor_row,
            inserted_lines,
            proposed_indices,
            cursor_char,
            render_above
        )
    end
end

--- Render the cursor on an unchanged line (not covered by any hunk).
---@param hunks MinuetDuetHunk[]
local function render_cursor_on_unchanged_line(bufnr, state, hunks, cursor_char)
    local c = state.proposed_cursor
    if not c then
        return
    end

    local proposed_row_1based = c.row_offset + 1

    -- If the cursor falls inside a hunk it was already rendered there.
    for _, hunk in ipairs(hunks) do
        local _, _, ps, pc = unpack(hunk)
        if proposed_row_1based >= ps and proposed_row_1based < ps + pc then
            return
        end
    end

    -- Map proposed row → original row by undoing the cumulative insert/delete shift.
    local shift = 0
    for _, hunk in ipairs(hunks) do
        local _, oc, ps, pc = unpack(hunk)
        if ps + pc <= proposed_row_1based then
            shift = shift + (pc - oc)
        end
    end

    local original_row_1based = proposed_row_1based - shift
    local buffer_row = state.range.start_row + original_row_1based - 1

    local line_text = state.proposed_lines[proposed_row_1based] or ''
    local chunks = make_chunks(line_text, 'MinuetDuetComment', c.col, cursor_char)

    add_extmark(bufnr, state, buffer_row, {
        virt_text = chunks,
        virt_text_pos = 'eol',
    })
end

function M.clear(bufnr, state)
    if not state then
        return
    end

    for _, extmark_id in ipairs(state.extmark_ids or {}) do
        pcall(api.nvim_buf_del_extmark, bufnr, M.ns_id, extmark_id)
    end

    state.extmark_ids = nil
end

function M.render(bufnr, state)
    local config = require('minuet').config.duet
    M.clear(bufnr, state)

    ---@type MinuetDuetHunk[]
    local hunks = get_hunks(state)
    local cursor_char = config.preview.cursor
    local mode = preview_mode(config)

    if #hunks == 0 then
        render_cursor_on_unchanged_line(bufnr, state, hunks, cursor_char)
        if not state.proposed_cursor then
            utils.notify('Minuet duet predicts no text changes.', 'warn', vim.log.levels.WARN)
        end
        return
    end

    if mode == 'virtual_lines' then
        hunks = coalesce_virtual_line_hunks(hunks)
    end

    for _, hunk in ipairs(hunks) do
        render_hunk(bufnr, state, hunk, cursor_char, mode)
    end

    render_cursor_on_unchanged_line(bufnr, state, hunks, cursor_char)
end

function M.is_visible(bufnr, state)
    if not state then
        return false
    end

    for _, extmark_id in ipairs(state.extmark_ids or {}) do
        local extmark = api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, extmark_id, {})
        if extmark[1] ~= nil then
            return true
        end
    end
    return false
end

return M
