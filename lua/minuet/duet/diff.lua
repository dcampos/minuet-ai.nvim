local M = {}

---@alias minuet.DuetChunkKind '"inline"'|'"block"'

---@class minuet.DuetChunk
---@field kind minuet.DuetChunkKind
---@field anchor_row integer 0-based buffer row
---@field anchor_col integer 0-based byte column
---@field old_start integer 1-based index in original_lines
---@field old_count integer
---@field new_start integer 1-based index in proposed_lines
---@field new_count integer
---@field old_lines string[]
---@field new_lines string[]
---@field old_line? string
---@field new_line? string
---@field start_col? integer 0-based byte column
---@field end_col? integer 0-based byte column
---@field new_text? string
---@field old_text? string
---@field groups? minuet.DuetTextGroup[]
---@field group_index? integer
---@field visible_by_default boolean
---@field focus_kind? string

---@class minuet.DuetTextGroup
---@field old_text string
---@field new_text string
---@field old_start_col integer?
---@field old_end_col integer?
---@field new_start_col integer?
---@field new_end_col integer?
---@field insert_col integer

---@diagnostic disable-next-line: deprecated
local nvim_diff = (vim.text and vim.text.diff) or vim.diff

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

---@param text string
---@return { text: string, start_col: integer, end_col: integer }[]
local function codepoint_tokens(text)
    local tokens = {}
    local i = 1
    while i <= #text do
        local len = utf8_char_len(text, i)
        tokens[#tokens + 1] = {
            text = text:sub(i, i + len - 1),
            start_col = i - 1,
            end_col = i + len - 1,
        }
        i = i + len
    end
    return tokens
end

local NEG_INF = -1000000000

local function vget(v, k)
    local value = v[k]
    if value == nil then
        return NEG_INF
    end
    return value
end

local function copy_v(v)
    local out = {}
    for k, value in pairs(v) do
        out[k] = value
    end
    return out
end

--- Myers shortest edit script over token arrays. Tokens are equal when their
--- `.text` fields match. Returns operations in forward order.
---@param old_tokens { text: string }[]
---@param new_tokens { text: string }[]
---@return { kind: '"equal"'|'"delete"'|'"insert"', old_idx?: integer, new_idx?: integer }[]
local function myers(old_tokens, new_tokens)
    local n, m = #old_tokens, #new_tokens
    if n == 0 then
        local ops = {}
        for j = 1, m do
            ops[#ops + 1] = { kind = 'insert', new_idx = j }
        end
        return ops
    elseif m == 0 then
        local ops = {}
        for i = 1, n do
            ops[#ops + 1] = { kind = 'delete', old_idx = i }
        end
        return ops
    end

    local trace = {}
    local v = { [1] = 0 }
    local found_d

    for d = 0, n + m do
        for k = -d, d, 2 do
            local x
            if k == -d or (k ~= d and vget(v, k - 1) < vget(v, k + 1)) then
                x = vget(v, k + 1)
            else
                x = vget(v, k - 1) + 1
            end
            if x < 0 then
                x = 0
            end
            local y = x - k
            while x < n and y < m and old_tokens[x + 1].text == new_tokens[y + 1].text do
                x = x + 1
                y = y + 1
            end
            v[k] = x
            if x >= n and y >= m then
                trace[d] = copy_v(v)
                found_d = d
                break
            end
        end
        trace[d] = trace[d] or copy_v(v)
        if found_d then
            break
        end
    end

    local ops = {}
    local x, y = n, m
    for d = found_d or (n + m), 1, -1 do
        local k = x - y
        local prev_v = trace[d - 1] or {}
        local prev_k
        if k == -d or (k ~= d and vget(prev_v, k - 1) < vget(prev_v, k + 1)) then
            prev_k = k + 1
        else
            prev_k = k - 1
        end
        local prev_x = math.max(0, vget(prev_v, prev_k))
        local prev_y = prev_x - prev_k

        while x > prev_x and y > prev_y do
            table.insert(ops, 1, { kind = 'equal', old_idx = x, new_idx = y })
            x = x - 1
            y = y - 1
        end

        if x == prev_x then
            table.insert(ops, 1, { kind = 'insert', new_idx = y })
            y = y - 1
        else
            table.insert(ops, 1, { kind = 'delete', old_idx = x })
            x = x - 1
        end
    end

    while x > 0 and y > 0 do
        table.insert(ops, 1, { kind = 'equal', old_idx = x, new_idx = y })
        x = x - 1
        y = y - 1
    end
    while x > 0 do
        table.insert(ops, 1, { kind = 'delete', old_idx = x })
        x = x - 1
    end
    while y > 0 do
        table.insert(ops, 1, { kind = 'insert', new_idx = y })
        y = y - 1
    end

    return ops
end

---@param tokens { text: string }[]
---@param indices integer[]
---@return string
local function concat_token_indices(tokens, indices)
    local parts = {}
    for _, idx in ipairs(indices) do
        parts[#parts + 1] = tokens[idx].text
    end
    return table.concat(parts)
end

---@param line string
---@param start_col integer?
---@param end_col integer?
---@return string
local function byte_slice(line, start_col, end_col)
    if not start_col or not end_col or end_col <= start_col then
        return ''
    end
    return line:sub(start_col + 1, end_col)
end

---@param old_tokens { start_col: integer, end_col: integer }[]
---@param old_indices integer[]
---@param fallback_col integer
---@return integer
local function insert_col(old_tokens, old_indices, fallback_col)
    local first = old_indices[1]
    if first and old_tokens[first] then
        return old_tokens[first].start_col
    end
    return fallback_col
end

---@param old_line string
---@param new_line string
---@return minuet.DuetTextGroup[] groups
---@return integer edit_count
---@return integer equal_count
function M.text_groups(old_line, new_line)
    local old_tokens = codepoint_tokens(old_line)
    local new_tokens = codepoint_tokens(new_line)
    local ops = myers(old_tokens, new_tokens)
    local groups = {}
    local edit_count, equal_count = 0, 0
    local old_run, new_run = {}, {}
    local last_old_col = 0

    local function flush()
        if #old_run == 0 and #new_run == 0 then
            return
        end
        local old_first = old_run[1]
        local old_last = old_run[#old_run]
        local new_first = new_run[1]
        local new_last = new_run[#new_run]
        local old_start_col = old_first and old_tokens[old_first].start_col or nil
        local old_end_col = old_last and old_tokens[old_last].end_col or nil
        local new_start_col = new_first and new_tokens[new_first].start_col or nil
        local new_end_col = new_last and new_tokens[new_last].end_col or nil

        groups[#groups + 1] = {
            old_text = concat_token_indices(old_tokens, old_run),
            new_text = concat_token_indices(new_tokens, new_run),
            old_start_col = old_start_col,
            old_end_col = old_end_col,
            new_start_col = new_start_col,
            new_end_col = new_end_col,
            insert_col = insert_col(old_tokens, old_run, last_old_col),
        }
        old_run, new_run = {}, {}
    end

    for _, op in ipairs(ops) do
        if op.kind == 'equal' then
            flush()
            equal_count = equal_count + 1
            last_old_col = old_tokens[op.old_idx].end_col
        elseif op.kind == 'delete' then
            edit_count = edit_count + 1
            old_run[#old_run + 1] = op.old_idx
        elseif op.kind == 'insert' then
            edit_count = edit_count + 1
            new_run[#new_run + 1] = op.new_idx
        end
    end
    flush()

    local coalesced = {}
    for _, group in ipairs(groups) do
        local last = coalesced[#coalesced]
        local last_old_end = last and (last.old_end_col or last.insert_col) or nil
        local group_old_start = group.old_start_col or group.insert_col
        local old_gap = last_old_end and (group_old_start - last_old_end) or nil
        if last and old_gap and old_gap >= 0 and old_gap <= 1 then
            local old_start = last.old_start_col or last.insert_col
            local old_end = group.old_end_col or group.insert_col
            local new_start = last.new_start_col or group.new_start_col
            local new_end = group.new_end_col or last.new_end_col
            if not group.new_end_col and last.new_end_col then
                new_end = last.new_end_col + old_gap
            elseif not last.new_start_col and group.new_start_col then
                new_start = math.max(0, group.new_start_col - old_gap)
            end
            last.old_start_col = old_start
            last.old_end_col = old_end > old_start and old_end or nil
            last.new_start_col = new_start
            last.new_end_col = new_start and new_end and new_end > new_start and new_end or nil
            last.insert_col = old_start
            last.old_text = byte_slice(old_line, last.old_start_col, last.old_end_col)
            last.new_text = byte_slice(new_line, last.new_start_col, last.new_end_col)
        else
            coalesced[#coalesced + 1] = vim.deepcopy(group)
        end
    end

    return coalesced, edit_count, equal_count
end

---@param old_line string
---@param new_line string
---@return number
local function line_similarity(old_line, new_line)
    if old_line == new_line then
        return 1
    end
    local _, edit_count, equal_count = M.text_groups(old_line, new_line)
    local total = edit_count + equal_count
    if total == 0 then
        return 0
    end
    return equal_count / total
end

---@param old_lines string[]
---@param new_lines string[]
---@param min_similarity number
---@return { old_idx: integer, new_idx: integer }[]
local function pair_lines(old_lines, new_lines, min_similarity)
    local n, m = #old_lines, #new_lines
    local dp = {}
    local choice = {}
    for i = 0, n do
        dp[i] = {}
        choice[i] = {}
        for j = 0, m do
            dp[i][j] = NEG_INF
        end
    end
    dp[0][0] = 0

    for i = 0, n do
        for j = 0, m do
            local cur = dp[i][j]
            if cur > NEG_INF / 2 then
                if i < n and cur - 0.35 > dp[i + 1][j] then
                    dp[i + 1][j] = cur - 0.35
                    choice[i + 1][j] = { i, j, 'delete' }
                end
                if j < m and cur - 0.35 > dp[i][j + 1] then
                    dp[i][j + 1] = cur - 0.35
                    choice[i][j + 1] = { i, j, 'insert' }
                end
                if i < n and j < m then
                    local score = line_similarity(old_lines[i + 1], new_lines[j + 1])
                    if score >= min_similarity and cur + score > dp[i + 1][j + 1] then
                        dp[i + 1][j + 1] = cur + score
                        choice[i + 1][j + 1] = { i, j, 'pair' }
                    end
                end
            end
        end
    end

    local pairs = {}
    local i, j = n, m
    while i > 0 or j > 0 do
        local c = choice[i] and choice[i][j]
        if not c then
            break
        end
        if c[3] == 'pair' then
            table.insert(pairs, 1, { old_idx = i, new_idx = j })
        end
        i, j = c[1], c[2]
    end
    return pairs
end

local function full_text(lines)
    if not lines or #lines == 0 then
        return ''
    end
    return table.concat(lines, '\n') .. '\n'
end

---@param original_lines string[]
---@param proposed_lines string[]
---@return integer[][]
local function get_hunks(original_lines, proposed_lines)
    local hunks = nvim_diff(full_text(original_lines), full_text(proposed_lines), {
        result_type = 'indices',
        algorithm = 'histogram',
        linematch = true,
        ignore_whitespace = false,
        ignore_whitespace_change = false,
        ignore_whitespace_change_at_eol = false,
        ignore_blank_lines = false,
    })
    if type(hunks) == 'string' or not hunks then
        return {}
    end
    return hunks
end

---@param old_count integer
---@param new_count integer
---@param old_start integer
---@param new_start integer
---@param range_start integer
---@param original_lines string[]
---@param proposed_lines string[]
---@param opts table
---@param chunks minuet.DuetChunk[]
local function push_block_chunks(
    old_count,
    new_count,
    old_start,
    new_start,
    range_start,
    original_lines,
    proposed_lines,
    opts,
    chunks
)
    if old_count == 0 and new_count == 0 then
        return
    end

    local max_lines = math.max(1, tonumber(opts.block_chunk_size) or 10)
    local old_done, new_done = 0, 0
    while old_done < old_count or new_done < new_count do
        local remaining_old = old_count - old_done
        local remaining_new = new_count - new_done
        local take_old = math.min(remaining_old, max_lines)
        local take_new = math.min(remaining_new, max_lines)
        if remaining_old > 0 and remaining_new == 0 then
            take_old = math.min(remaining_old, max_lines)
        elseif remaining_new > 0 and remaining_old == 0 then
            take_new = math.min(remaining_new, max_lines)
        end

        local old_lines = vim.list_slice(original_lines, old_start + old_done, old_start + old_done + take_old - 1)
        local new_lines = vim.list_slice(proposed_lines, new_start + new_done, new_start + new_done + take_new - 1)
        local anchor_row = range_start + old_start + old_done - 2 + math.max(take_old, 1)
        if take_old == 0 then
            anchor_row = range_start + old_start + old_done - 1
        end

        chunks[#chunks + 1] = {
            kind = 'block',
            anchor_row = math.max(0, anchor_row),
            anchor_col = 0,
            old_start = old_start + old_done,
            old_count = take_old,
            new_start = new_start + new_done,
            new_count = take_new,
            old_lines = old_lines,
            new_lines = new_lines,
            visible_by_default = math.max(take_old, take_new) <= 1,
            focus_kind = opts.focus_kind,
        }

        old_done = old_done + take_old
        new_done = new_done + take_new
    end
end

local function inline_ok(groups, edit_count, old_line, new_line, opts)
    local max_groups = tonumber(opts.inline_max_groups) or 2
    if #groups == 0 or #groups > max_groups then
        return false
    end
    local max_ratio = tonumber(opts.inline_max_edit_ratio) or 0.9
    local denom = math.max(vim.fn.strchars(old_line), vim.fn.strchars(new_line), 1)
    return (edit_count / denom) <= max_ratio
end

---@param old_index integer 1-based index in original_lines
---@param new_index integer 1-based index in proposed_lines
---@param range_start integer
---@param original_lines string[]
---@param proposed_lines string[]
---@param opts table
---@param chunks minuet.DuetChunk[]
local function push_paired_line(old_index, new_index, range_start, original_lines, proposed_lines, opts, chunks)
    local old_line = original_lines[old_index] or ''
    local new_line = proposed_lines[new_index] or ''
    if old_line == new_line then
        return
    end

    local groups, edit_count = M.text_groups(old_line, new_line)
    if not inline_ok(groups, edit_count, old_line, new_line, opts) then
        push_block_chunks(1, 1, old_index, new_index, range_start, original_lines, proposed_lines, opts, chunks)
        return
    end

    for group_index, group in ipairs(groups) do
        local start_col = group.old_start_col or group.insert_col
        local end_col = group.old_end_col or group.insert_col
        chunks[#chunks + 1] = {
            kind = 'inline',
            anchor_row = range_start + old_index - 1,
            anchor_col = start_col,
            old_start = old_index,
            old_count = 1,
            new_start = new_index,
            new_count = 1,
            old_lines = { old_line },
            new_lines = { new_line },
            old_line = old_line,
            new_line = new_line,
            start_col = start_col,
            end_col = end_col,
            old_text = group.old_text,
            new_text = group.new_text,
            groups = groups,
            group_index = group_index,
            visible_by_default = opts.focus_kind ~= 'diagnostic',
            focus_kind = opts.focus_kind,
        }
    end
end

---@param original_lines string[]
---@param proposed_lines string[]
---@param range { start_row: integer }
---@param opts? table
---@return minuet.DuetChunk[]
function M.build_chunks(original_lines, proposed_lines, range, opts)
    opts = opts or {}
    local chunks = {}
    for _, hunk in ipairs(get_hunks(original_lines, proposed_lines)) do
        local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]
        local old_hunk = vim.list_slice(original_lines, old_start, old_start + old_count - 1)
        local new_hunk = vim.list_slice(proposed_lines, new_start, new_start + new_count - 1)
        local pairs = pair_lines(old_hunk, new_hunk, tonumber(opts.line_pair_min_similarity) or 0.35)
        local old_cursor, new_cursor = 1, 1

        for _, pair in ipairs(pairs) do
            local old_idx = old_start + pair.old_idx - 1
            local new_idx = new_start + pair.new_idx - 1
            push_block_chunks(
                old_idx - (old_start + old_cursor - 1),
                new_idx - (new_start + new_cursor - 1),
                old_start + old_cursor - 1,
                new_start + new_cursor - 1,
                range.start_row,
                original_lines,
                proposed_lines,
                opts,
                chunks
            )
            push_paired_line(old_idx, new_idx, range.start_row, original_lines, proposed_lines, opts, chunks)
            old_cursor = pair.old_idx + 1
            new_cursor = pair.new_idx + 1
        end

        push_block_chunks(
            old_count - old_cursor + 1,
            new_count - new_cursor + 1,
            old_start + old_cursor - 1,
            new_start + new_cursor - 1,
            range.start_row,
            original_lines,
            proposed_lines,
            opts,
            chunks
        )
    end

    table.sort(chunks, function(a, b)
        if a.anchor_row ~= b.anchor_row then
            return a.anchor_row < b.anchor_row
        end
        if a.anchor_col ~= b.anchor_col then
            return a.anchor_col < b.anchor_col
        end
        return (a.new_start or 0) < (b.new_start or 0)
    end)
    return chunks
end

---@param lines string[]
---@param chunk minuet.DuetChunk
---@return string[]
function M.apply_chunk(lines, chunk)
    local out = vim.deepcopy(lines)
    if chunk.kind == 'inline' then
        local row = chunk.anchor_row + 1
        local line = out[row] or ''
        out[row] = line:sub(1, (chunk.start_col or 0))
            .. (chunk.new_text or '')
            .. line:sub((chunk.end_col or chunk.start_col or 0) + 1)
        return out
    end

    local start = chunk.anchor_row + 1
    if chunk.old_count == 0 then
        start = math.max(1, math.min(#out + 1, chunk.old_start + 1))
    else
        start = math.max(1, math.min(#out + 1, chunk.anchor_row - chunk.old_count + 2))
    end
    for _ = 1, chunk.old_count do
        if start <= #out then
            table.remove(out, start)
        end
    end
    for i, line in ipairs(chunk.new_lines or {}) do
        table.insert(out, start + i - 1, line)
    end
    return out
end

---@param a string[]
---@param b string[]
---@return boolean
function M.same_lines(a, b)
    return vim.deep_equal(a, b)
end

---@param tokens { text: string }[]
---@param first integer
---@param last integer
---@return string
local function concat_token_range(tokens, first, last)
    if first > last then
        return ''
    end
    local parts = {}
    for i = math.max(1, first), math.min(#tokens, last) do
        parts[#parts + 1] = tokens[i].text
    end
    return table.concat(parts)
end

local function has_suffix(text, suffix)
    return suffix == '' or text:sub(-#suffix) == suffix
end

local function line_can_be_partial_insert(old_line, cur_line, new_line)
    if cur_line == old_line or cur_line == new_line then
        return true
    end

    local groups = M.text_groups(old_line, new_line)
    if #groups ~= 1 then
        return false
    end
    local group = groups[1]
    local start_col = group.old_start_col or group.insert_col
    local end_col = group.old_end_col or group.insert_col
    local before = old_line:sub(1, start_col)
    local after = old_line:sub(end_col + 1)

    if group.old_text == '' and vim.startswith(cur_line, before) and has_suffix(cur_line, after) then
        local inserted = cur_line:sub(#before + 1, #cur_line - #after)
        return vim.startswith(group.new_text, inserted)
    end

    return false
end

local function line_can_be_partial_fancy(old_line, cur_line, new_line)
    if cur_line == old_line or cur_line == new_line then
        return true
    end

    local groups = M.text_groups(old_line, new_line)
    if #groups ~= 1 then
        return false
    end

    local group = groups[1]
    local start_col = group.old_start_col or group.insert_col
    local end_col = group.old_end_col or group.insert_col
    local before = old_line:sub(1, start_col)
    local after = old_line:sub(end_col + 1)
    if not vim.startswith(cur_line, before) or not has_suffix(cur_line, after) then
        return false
    end

    local middle = cur_line:sub(#before + 1, #cur_line - #after)
    local old_tokens = codepoint_tokens(group.old_text or '')
    local new_tokens = codepoint_tokens(group.new_text or '')
    for new_taken = 0, #new_tokens do
        local new_prefix = concat_token_range(new_tokens, 1, new_taken)
        if vim.startswith(middle, new_prefix) then
            local rest = middle:sub(#new_prefix + 1)
            for old_kept = 0, #old_tokens do
                local old_suffix = concat_token_range(old_tokens, #old_tokens - old_kept + 1, #old_tokens)
                if rest == old_suffix and (new_taken > 0 or old_kept < #old_tokens) then
                    return true
                end
            end
        end
    end

    return false
end

---@param original_lines string[]
---@param current_lines string[]
---@param proposed_lines string[]
---@param range { start_row: integer }
---@param opts table
---@param level integer
---@return boolean
function M.compatible_progress(original_lines, current_lines, proposed_lines, range, opts, level)
    if level <= 1 then
        return false
    end
    if M.same_lines(current_lines, proposed_lines) then
        return true
    end

    local simulated = vim.deepcopy(original_lines)
    for _, chunk in ipairs(M.build_chunks(original_lines, proposed_lines, range, opts)) do
        simulated = M.apply_chunk(simulated, chunk)
        if M.same_lines(simulated, current_lines) then
            return true
        end
    end

    if level <= 2 or #current_lines ~= #original_lines or #current_lines ~= #proposed_lines then
        return false
    end

    for i, old_line in ipairs(original_lines) do
        local new_line = proposed_lines[i]
        local cur_line = current_lines[i]
        if old_line == new_line then
            if cur_line ~= old_line then
                return false
            end
        elseif level >= 4 and not line_can_be_partial_fancy(old_line, cur_line, new_line) then
            return false
        elseif level < 4 and not line_can_be_partial_insert(old_line, cur_line, new_line) then
            return false
        end
    end

    return true
end

M._private = {
    codepoint_tokens = codepoint_tokens,
    myers = myers,
    pair_lines = pair_lines,
    line_similarity = line_similarity,
}

return M
