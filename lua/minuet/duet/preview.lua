local api = vim.api
local diff = require 'minuet.duet.diff'
local ts_highlight = require 'minuet.duet.ts_highlight'
local utils = require 'minuet.duet.utils'

local M = {}

M.ns_id = api.nvim_create_namespace 'minuet.duet'

local LINE_HL_PRIORITY = 100
local TEXT_HL_PRIORITY = 110
local ACTIVE_HL_PRIORITY = 120

local default_highlights = {
    MinuetDuetAdd = { link = 'DiffAdd' },
    MinuetDuetAddText = { bg = 0x2f6f54 },
    MinuetDuetDelete = { link = 'DiffDelete' },
    MinuetDuetDeleteText = { bg = 0x9a3f55 },
    MinuetDuetComment = { link = 'Comment' },
    MinuetDuetCursor = { link = 'IncSearch' },
    MinuetDuetMarker = { bg = 0x2f5fba },
    MinuetDuetActive = { link = 'Visual' },
}

for hl_group, default_hl in pairs(default_highlights) do
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = hl_group })) then
        api.nvim_set_hl(0, hl_group, default_hl)
    end
end

local function preview_opts(config, state)
    local preview = config.preview or {}
    return {
        block_chunk_size = preview.block_chunk_size or 10,
        inline_max_groups = preview.inline_max_groups or 2,
        inline_max_edit_ratio = preview.inline_max_edit_ratio or 0.9,
        line_pair_min_similarity = preview.line_pair_min_similarity or 0.35,
        focus_kind = state.preview_focus,
    }
end

local function add_extmark(bufnr, state, row, opts, col)
    state.extmark_ids = state.extmark_ids or {}
    row = math.max(0, row)
    local line_count = math.max(api.nvim_buf_line_count(bufnr), 1)
    row = math.min(row, line_count - 1)
    local extmark_id = api.nvim_buf_set_extmark(bufnr, M.ns_id, row, col or 0, opts)
    table.insert(state.extmark_ids, extmark_id)
end

local function push_chunk(chunks, text, hl_group)
    if #text > 0 then
        chunks[#chunks + 1] = { text, hl_group }
    end
end

local function push_chunk_range(chunks, text, start_col, end_col, hl_group, cursor_col, cursor_char)
    if cursor_col and cursor_col >= start_col and cursor_col <= end_col and start_col < end_col then
        push_chunk(chunks, text:sub(start_col + 1, cursor_col), hl_group)
        chunks[#chunks + 1] = { cursor_char, 'MinuetDuetCursor' }
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
        chunks[#chunks + 1] = { cursor_char, 'MinuetDuetCursor' }
    end
    if #chunks == 0 then
        chunks[#chunks + 1] = { text, base_hl_group }
    end
    return chunks
end

--- Return the cursor column if the proposed line at `proposed_idx` (0-based)
--- carries the cursor, otherwise nil.
local function cursor_col_for(state, proposed_idx)
    local c = state.proposed_cursor
    if not c then
        return nil
    end
    if proposed_idx == c.row_offset then
        return c.col
    end
    return nil
end

local function render_deleted_spans(bufnr, state, row, groups)
    for _, group in ipairs(groups or {}) do
        if group.old_start_col and group.old_end_col and group.old_end_col > group.old_start_col then
            add_extmark(bufnr, state, row, {
                end_col = group.old_end_col,
                hl_group = 'MinuetDuetDeleteText',
                priority = TEXT_HL_PRIORITY,
            }, group.old_start_col)
        end
    end
end

--- Treesitter-colored virt_text for an inline edit fragment, or nil when ts
--- coloring is off / unavailable. The fragment is colored in the context of the
--- whole proposed line (so a word changed inside a string inherits @string),
--- then only its changed span is returned.
---@param bufnr integer
---@param chunk minuet.DuetChunk
---@param group minuet.DuetTextGroup
---@return table[]|nil
local function inline_ts_virt_text(bufnr, chunk, group)
    local preview = require('minuet').config.duet.preview or {}
    if not preview.ts_highlight then
        return nil
    end
    if not (group.new_start_col and group.new_end_col and group.new_end_col > group.new_start_col) then
        return nil
    end
    local new_line = chunk.new_line or (chunk.new_lines or {})[1]
    if not new_line then
        return nil
    end
    local ft = vim.bo[bufnr].filetype
    if not ft or ft == '' then
        return nil
    end
    local lang = vim.treesitter.language.get_lang(ft) or ft
    local ok, parser = pcall(vim.treesitter.get_string_parser, new_line, lang)
    if not ok or not parser then
        return nil
    end
    return ts_highlight.highlight_line_range(new_line, lang, group.new_start_col, group.new_end_col, {
        dim = preview.ts_dim ~= false,
        blend = preview.ts_blend or 35,
        bg = preview.ts_add_bg or nil,
        base_hl = 'Normal',
    })
end

local function render_inline_chunk(bufnr, state, chunk, cursor_char, active)
    local row = chunk.anchor_row
    local groups = chunk.groups or diff.text_groups(chunk.old_line or '', chunk.new_line or '')
    local group = groups[chunk.group_index or 1]
    if not group then
        return
    end

    if group.old_start_col and group.old_end_col and group.old_end_col > group.old_start_col then
        add_extmark(bufnr, state, row, {
            end_col = group.old_end_col,
            hl_group = active and 'MinuetDuetActive' or 'MinuetDuetDeleteText',
            priority = active and ACTIVE_HL_PRIORITY or TEXT_HL_PRIORITY,
        }, group.old_start_col)
    end

    if group.new_text ~= '' then
        local col = group.old_end_col or group.insert_col
        local virt_text
        if active then
            virt_text = { { group.new_text, 'MinuetDuetActive' } }
        else
            virt_text = inline_ts_virt_text(bufnr, chunk, group) or { { group.new_text, 'MinuetDuetAddText' } }
        end
        add_extmark(bufnr, state, row, {
            virt_text = virt_text,
            virt_text_pos = 'inline',
            priority = active and ACTIVE_HL_PRIORITY or TEXT_HL_PRIORITY,
        }, col)
    end
end

--- Mark a collapsed (not-yet-revealed) hunk with a small blue square at its
--- first change: a background tint behind the changed glyph (MinuetDuetMarker is
--- bg-only, so the glyph keeps its syntax color). When the change sits at end of
--- line / on an empty line there is no glyph to tint, so fall back to a one-cell
--- inline blue square at the change column.
local function render_marker(bufnr, state, chunk)
    local line_count = math.max(api.nvim_buf_line_count(bufnr), 1)
    local row = math.min(math.max(0, chunk.anchor_row), line_count - 1)
    local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
    local col = math.max(0, math.min(chunk.anchor_col or 0, #line))
    local b = line:byte(col + 1)
    if not b then
        add_extmark(bufnr, state, chunk.anchor_row, {
            virt_text = { { ' ', 'MinuetDuetMarker' } },
            virt_text_pos = 'inline',
            priority = ACTIVE_HL_PRIORITY,
        }, col)
        return
    end
    local char_len = (b < 0x80 and 1) or (b < 0xe0 and 2) or (b < 0xf0 and 3) or 4
    add_extmark(bufnr, state, chunk.anchor_row, {
        end_col = col + char_len,
        hl_group = 'MinuetDuetMarker',
        priority = ACTIVE_HL_PRIORITY,
    }, col)
end

local function block_anchor(chunk)
    local render_above = false
    local anchor_row = chunk.anchor_row
    if chunk.old_count == 0 then
        render_above = chunk.old_start == 0
    end
    return anchor_row, render_above
end

local function line_chunks(text, hl_group, cursor_col, cursor_char)
    if not cursor_col then
        return { { text, hl_group } }
    end
    local before = text:sub(1, cursor_col)
    local after = text:sub(cursor_col + 1)
    local chunks = {}
    push_chunk(chunks, before, hl_group)
    chunks[#chunks + 1] = { cursor_char, 'MinuetDuetCursor' }
    push_chunk(chunks, after, hl_group)
    return chunks
end

local function proposed_line_chunks(chunk, offset, cursor_char)
    local new_line = chunk.new_lines[offset + 1] or ''
    local old_line = chunk.old_lines[offset + 1]
    local proposed_idx = chunk.new_start + offset - 1
    local cursor_col = cursor_col_for(chunk.state, proposed_idx)
    if not old_line then
        return line_chunks(new_line, 'MinuetDuetAdd', cursor_col, cursor_char)
    end

    local spans = {}
    for _, group in ipairs(diff.text_groups(old_line, new_line)) do
        if group.new_start_col and group.new_end_col and group.new_end_col > group.new_start_col then
            spans[#spans + 1] = {
                start_col = group.new_start_col,
                end_col = group.new_end_col,
                hl_group = 'MinuetDuetAddText',
            }
        end
    end
    return make_span_chunks(new_line, 'MinuetDuetAdd', spans, cursor_col, cursor_char)
end

--- Insert the cursor glyph into an existing chunk list at `cursor_col` (byte),
--- splitting whichever chunk straddles it. Used for treesitter-colored proposed
--- lines, where the cursor cannot be baked in at build time.
---@param chunks table[] list of { text, hl_group }
---@param cursor_col integer|nil
---@param cursor_char string
---@return table[]
local function inject_cursor(chunks, cursor_col, cursor_char)
    if not cursor_col then
        return chunks
    end
    local out = {}
    local pos = 0
    local inserted = false
    for _, ch in ipairs(chunks) do
        local text, hl = ch[1], ch[2]
        local len = #text
        if not inserted and cursor_col >= pos and cursor_col <= pos + len then
            local rel = cursor_col - pos
            push_chunk(out, text:sub(1, rel), hl)
            out[#out + 1] = { cursor_char, 'MinuetDuetCursor' }
            push_chunk(out, text:sub(rel + 1), hl)
            inserted = true
        else
            out[#out + 1] = ch
        end
        pos = pos + len
    end
    if not inserted then
        out[#out + 1] = { cursor_char, 'MinuetDuetCursor' }
    end
    return out
end

--- Treesitter-colored chunks for the whole proposed block, one chunk list per
--- new line, or nil when ts coloring is off / no parser is available (callers
--- then fall back to the flat word-diff rendering). The block is highlighted as
--- one snippet so multi-line constructs parse with their own context.
---@param bufnr integer
---@param chunk minuet.DuetChunk
---@return table[][]|nil
local function block_ts_chunks(bufnr, chunk)
    local preview = require('minuet').config.duet.preview or {}
    if not preview.ts_highlight then
        return nil
    end
    local ft = vim.bo[bufnr].filetype
    if not ft or ft == '' then
        return nil
    end
    local lang = vim.treesitter.language.get_lang(ft) or ft
    local ok, parser = pcall(vim.treesitter.get_string_parser, table.concat(chunk.new_lines, '\n'), lang)
    if not ok or not parser then
        return nil
    end
    return ts_highlight.highlight_lines(chunk.new_lines, lang, {
        dim = preview.ts_dim ~= false,
        blend = preview.ts_blend or 35,
        bg = preview.ts_add_bg or nil,
        base_hl = 'Normal',
    })
end

--- Render the full block diff (deleted lines + proposed virt_lines). The
--- caller decides whether the block is revealed or collapsed to a marker, so
--- this is only invoked for revealed blocks.
local function render_block_chunk(bufnr, state, chunk, cursor_char)
    for offset = 0, chunk.old_count - 1 do
        local row = chunk.anchor_row - chunk.old_count + 1 + offset
        local old_line = chunk.old_lines[offset + 1] or ''
        local opts = {
            priority = LINE_HL_PRIORITY,
        }
        if old_line == '' then
            opts.line_hl_group = 'MinuetDuetDelete'
        else
            opts.end_col = #old_line
            opts.hl_eol = true
            opts.hl_group = 'MinuetDuetDelete'
        end
        add_extmark(bufnr, state, row, opts)
        if offset < chunk.new_count then
            render_deleted_spans(bufnr, state, row, diff.text_groups(old_line, chunk.new_lines[offset + 1] or ''))
        end
    end

    if chunk.new_count == 0 then
        return
    end

    chunk.state = state
    local ts_lines = block_ts_chunks(bufnr, chunk)
    local virt_lines = {}
    for offset = 0, chunk.new_count - 1 do
        if ts_lines then
            local proposed_idx = chunk.new_start + offset - 1
            local cursor_col = cursor_col_for(state, proposed_idx)
            virt_lines[#virt_lines + 1] = inject_cursor(ts_lines[offset + 1] or {}, cursor_col, cursor_char)
        else
            virt_lines[#virt_lines + 1] = proposed_line_chunks(chunk, offset, cursor_char)
        end
    end
    chunk.state = nil

    local anchor_row, render_above = block_anchor(chunk)
    add_extmark(bufnr, state, anchor_row, {
        virt_lines = virt_lines,
        virt_lines_above = render_above,
    })
end

local function render_cursor_on_unchanged_line(bufnr, state, cursor_char)
    local c = state.proposed_cursor
    if not c then
        return
    end

    local proposed_row_1based = c.row_offset + 1
    for _, chunk in ipairs(state.preview_chunks or {}) do
        if proposed_row_1based >= chunk.new_start and proposed_row_1based < chunk.new_start + chunk.new_count then
            return
        end
    end

    local line_text = state.proposed_lines[proposed_row_1based] or ''
    local chunks = line_chunks(line_text, 'MinuetDuetComment', c.col, cursor_char)
    add_extmark(bufnr, state, state.range.start_row + proposed_row_1based - 1, {
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

function M.rebuild_chunks(state)
    local config = require('minuet').config.duet
    state.preview_chunks = diff.build_chunks(
        state.original_lines or {},
        state.proposed_lines or {},
        state.range or { start_row = 0 },
        preview_opts(config, state)
    )
    if state.preview_active and state.preview_active > #state.preview_chunks then
        state.preview_active = nil
    end
    return state.preview_chunks
end

function M.render(bufnr, state)
    local config = require('minuet').config.duet
    M.clear(bufnr, state)
    M.rebuild_chunks(state)

    local cursor_char = config.preview.cursor
    if #state.preview_chunks == 0 then
        render_cursor_on_unchanged_line(bufnr, state, cursor_char)
        if not state.proposed_cursor then
            utils.notify('Minuet duet predicts no text changes.', 'warn', vim.log.levels.WARN)
        end
        return
    end

    -- A diff hunk is one continuous block of changed lines and may hold several
    -- changes that Tab approves one at a time. Navigating to any change reveals
    -- the whole hunk's diff at once (stepping through each tiny change is too
    -- low-info), while approval stays per-chunk: only the active chunk is the
    -- accept target. A collapsed hunk shows a single blue square at its first
    -- change, not one square per change.
    local active_chunk = state.preview_active and state.preview_chunks[state.preview_active]
    local active_hunk = active_chunk and active_chunk.hunk_id
    local hunk_marked = {}

    for i, chunk in ipairs(state.preview_chunks) do
        local active = state.preview_active == i
        local reveal = chunk.visible_by_default or active or (active_hunk ~= nil and chunk.hunk_id == active_hunk)
        if reveal then
            if chunk.kind == 'inline' then
                render_inline_chunk(bufnr, state, chunk, cursor_char, active)
            else
                render_block_chunk(bufnr, state, chunk, cursor_char)
            end
        else
            local hunk_key = chunk.hunk_id or i
            if not hunk_marked[hunk_key] then
                hunk_marked[hunk_key] = true
                render_marker(bufnr, state, chunk)
            end
        end
    end

    render_cursor_on_unchanged_line(bufnr, state, cursor_char)
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

function M.current_chunk(state)
    if not state or not state.preview_chunks then
        return nil
    end
    return state.preview_chunks[state.preview_active or 0], state.preview_active
end

function M.chunk_at_cursor(state)
    if not state or not state.preview_chunks then
        return nil
    end
    local cursor = api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local col = cursor[2]
    for i, chunk in ipairs(state.preview_chunks) do
        if row == chunk.anchor_row and col == chunk.anchor_col then
            return chunk, i
        end
    end
    return nil
end

function M.select_next_chunk(bufnr, state)
    M.rebuild_chunks(state)
    if not state.preview_chunks or #state.preview_chunks == 0 then
        return nil
    end

    local cursor = api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local col = cursor[2]
    local selected = nil
    for i, chunk in ipairs(state.preview_chunks) do
        if chunk.anchor_row > row or (chunk.anchor_row == row and chunk.anchor_col > col) then
            selected = i
            break
        end
    end
    selected = selected or 1
    state.preview_active = selected

    local chunk = state.preview_chunks[selected]
    pcall(api.nvim_win_set_cursor, 0, { chunk.anchor_row + 1, chunk.anchor_col })
    M.render(bufnr, state)
    return chunk
end

function M.apply_chunk(lines, chunk)
    return diff.apply_chunk(lines, chunk)
end

function M.compatible_progress(original_lines, current_lines, proposed_lines, state, level)
    local config = require('minuet').config.duet
    return diff.compatible_progress(
        original_lines,
        current_lines,
        proposed_lines,
        state.range or { start_row = 0 },
        preview_opts(config, state),
        level
    )
end

return M
