-- Faithful Lua port of Codex's apply_patch (`codex-rs/apply-patch`).
--
-- Scope for Minuet duet v1: parse the full `*** Begin Patch` grammar (so the
-- error messages the model sees match what gpt-oss was trained on), but only
-- *apply* `*** Update File` hunks against a single buffer's lines. Add/Delete/
-- Move are parsed and then rejected by `apply` with a clear message.
--
-- Matching mirrors Codex `seek_sequence`: exact -> rstrip -> trim. (Codex has a
-- 4th unicode-normalisation tier; omitted here, see TODO.)

local M = {}

local BEGIN_MARKER = '*** Begin Patch'
local END_MARKER = '*** End Patch'
local ADD_MARKER = '*** Add File: '
local DELETE_MARKER = '*** Delete File: '
local UPDATE_MARKER = '*** Update File: '
local MOVE_MARKER = '*** Move to: '
local EOF_MARKER = '*** End of File'
local CTX_MARKER = '@@ '
local CTX_EMPTY_MARKER = '@@'
local ENV_MARKER = '*** Environment ID:'

local function rtrim(s)
    return (s:gsub('%s+$', ''))
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

local function invalid_patch(msg)
    return ('invalid patch: %s'):format(msg)
end

local function invalid_hunk(line_number, msg)
    return ('invalid hunk at line %d, %s'):format(line_number, msg)
end

--- Mirrors `check_start_and_end_lines_strict`.
---@param first string?
---@param last string?
---@return string? err
local function check_boundaries_strict(first, last)
    first = first and trim(first) or nil
    last = last and trim(last) or nil
    if first == BEGIN_MARKER and last == END_MARKER then
        return nil
    end
    if first ~= BEGIN_MARKER then
        return invalid_patch("The first line of the patch must be '*** Begin Patch'")
    end
    return invalid_patch("The last line of the patch must be '*** End Patch'")
end

--- Mirrors `check_patch_boundaries_lenient`: accept a Codex heredoc wrapper
--- (`<<'EOF' ... EOF`) by stripping it, otherwise enforce strict boundaries.
---@param lines string[]
---@return string[]? lines, string? err
local function check_boundaries(lines)
    local strict_err = check_boundaries_strict(lines[1], lines[#lines])
    if not strict_err then
        return lines, nil
    end
    local first, last = lines[1], lines[#lines]
    if
        #lines >= 4
        and (first == '<<EOF' or first == "<<'EOF'" or first == '<<"EOF"')
        and last:sub(-3) == 'EOF'
    then
        local inner = vim.list_slice(lines, 2, #lines - 1)
        local inner_err = check_boundaries_strict(inner[1], inner[#inner])
        if inner_err then
            return nil, inner_err
        end
        return inner, nil
    end
    return nil, strict_err
end

-- ---------------------------------------------------------------------------
-- Parser (mirrors streaming_parser.rs)
-- ---------------------------------------------------------------------------

local Parser = {}
Parser.__index = Parser

local function new_parser()
    return setmetatable({
        mode = 'not_started',
        hunks = {},
        line_number = 0,
        update_hunk_line = 0,
        environment_id = nil,
    }, Parser)
end

local UNEXPECTED_LINE_FMT =
    "Unexpected line found in update hunk: '%s'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)"
local INVALID_HEADER_FMT =
    "'%s' is not a valid hunk header. Valid hunk headers: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'"

function Parser:last_hunk()
    return self.hunks[#self.hunks]
end

--- Mirrors `ensure_update_hunk_is_not_empty`: called when a header / End Patch
--- closes the current update hunk.
---@param line string trimmed line that triggered the close
---@return string? err
function Parser:ensure_update_not_empty(line)
    local hunk = self:last_hunk()
    if not hunk or hunk.kind ~= 'update' then
        return nil
    end
    if #hunk.chunks == 0 and self.mode == 'update' then
        return invalid_hunk(
            self.update_hunk_line,
            ("Update file hunk for path '%s' is empty"):format(hunk.path)
        )
    end
    local last = hunk.chunks[#hunk.chunks]
    if last and #last.old_lines == 0 and #last.new_lines == 0 then
        if line == END_MARKER then
            return invalid_hunk(self.line_number, 'Update hunk does not contain any lines')
        end
        return invalid_hunk(self.line_number, UNEXPECTED_LINE_FMT:format(line))
    end
    return nil
end

--- Mirrors `handle_hunk_headers_and_end_patch`.
---@param trimmed string
---@return boolean handled, string? err
function Parser:handle_headers(trimmed)
    if self.mode == 'started' and starts_with(trimmed, ENV_MARKER) then
        if self.environment_id ~= nil then
            return true, invalid_patch('apply_patch environment_id cannot be specified more than once')
        end
        local env = trim(trimmed:sub(#ENV_MARKER + 1))
        if env == '' then
            return true, invalid_patch('apply_patch environment_id cannot be empty')
        end
        self.environment_id = env
        return true, nil
    end
    if trimmed == END_MARKER then
        local err = self:ensure_update_not_empty(trimmed)
        if err then
            return true, err
        end
        self.mode = 'ended'
        return true, nil
    end
    if starts_with(trimmed, ADD_MARKER) then
        local err = self:ensure_update_not_empty(trimmed)
        if err then
            return true, err
        end
        table.insert(self.hunks, { kind = 'add', path = trimmed:sub(#ADD_MARKER + 1), contents = '' })
        self.mode = 'add'
        return true, nil
    end
    if starts_with(trimmed, DELETE_MARKER) then
        local err = self:ensure_update_not_empty(trimmed)
        if err then
            return true, err
        end
        table.insert(self.hunks, { kind = 'delete', path = trimmed:sub(#DELETE_MARKER + 1) })
        self.mode = 'delete'
        return true, nil
    end
    if starts_with(trimmed, UPDATE_MARKER) then
        local err = self:ensure_update_not_empty(trimmed)
        if err then
            return true, err
        end
        table.insert(self.hunks, {
            kind = 'update',
            path = trimmed:sub(#UPDATE_MARKER + 1),
            move_path = nil,
            chunks = {},
        })
        self.mode = 'update'
        self.update_hunk_line = self.line_number
        return true, nil
    end
    return false, nil
end

local function push_chunk(hunk, chunk)
    table.insert(hunk.chunks, chunk)
end

local function ensure_chunk(hunk)
    if #hunk.chunks == 0 then
        push_chunk(hunk, { change_context = nil, old_lines = {}, new_lines = {}, is_end_of_file = false })
    end
    return hunk.chunks[#hunk.chunks]
end

--- Mirrors the UpdateFile arm of `process_line`.
---@param line string the original (only \r-stripped) line
---@return string? err
function Parser:process_update_line(line)
    local update_line = rtrim(line)

    local handled, err = self:handle_headers(update_line)
    if err then
        return err
    end
    if handled then
        return nil
    end

    local hunk = self:last_hunk()
    local last = hunk.chunks[#hunk.chunks]

    if last and last.is_end_of_file then
        if update_line == '' then
            return nil
        end
        if update_line ~= CTX_EMPTY_MARKER and not starts_with(update_line, CTX_MARKER) then
            return invalid_hunk(
                self.line_number,
                ("Expected update hunk to start with a @@ context marker, got: '%s'"):format(line)
            )
        end
    end

    if #hunk.chunks == 0 and hunk.move_path == nil and starts_with(update_line, MOVE_MARKER) then
        hunk.move_path = update_line:sub(#MOVE_MARKER + 1)
        return nil
    end

    local is_ctx = update_line == CTX_EMPTY_MARKER or starts_with(update_line, CTX_MARKER)
    if is_ctx and last and #last.old_lines == 0 and #last.new_lines == 0 then
        return invalid_hunk(self.line_number, UNEXPECTED_LINE_FMT:format(line))
    end

    if update_line == CTX_EMPTY_MARKER then
        push_chunk(hunk, { change_context = nil, old_lines = {}, new_lines = {}, is_end_of_file = false })
        return nil
    end

    if starts_with(update_line, CTX_MARKER) then
        push_chunk(hunk, {
            change_context = update_line:sub(#CTX_MARKER + 1),
            old_lines = {},
            new_lines = {},
            is_end_of_file = false,
        })
        return nil
    end

    if update_line == EOF_MARKER then
        if last and #last.old_lines == 0 and #last.new_lines == 0 then
            return invalid_hunk(self.line_number, 'Update hunk does not contain any lines')
        end
        if last then
            last.is_end_of_file = true
        end
        return nil
    end

    if line == '' then
        local chunk = ensure_chunk(hunk)
        table.insert(chunk.old_lines, '')
        table.insert(chunk.new_lines, '')
        return nil
    end

    local first = line:sub(1, 1)
    if first == ' ' then
        local content = line:sub(2)
        local chunk = ensure_chunk(hunk)
        table.insert(chunk.old_lines, content)
        table.insert(chunk.new_lines, content)
        return nil
    elseif first == '+' then
        local content = line:sub(2)
        local chunk = ensure_chunk(hunk)
        table.insert(chunk.new_lines, content)
        return nil
    elseif first == '-' then
        local content = line:sub(2)
        local chunk = ensure_chunk(hunk)
        table.insert(chunk.old_lines, content)
        return nil
    end

    if last and (#last.old_lines > 0 or #last.new_lines > 0) then
        return invalid_hunk(
            self.line_number,
            ("Expected update hunk to start with a @@ context marker, got: '%s'"):format(line)
        )
    end

    return invalid_hunk(self.line_number, UNEXPECTED_LINE_FMT:format(line))
end

---@param line string
---@return string? err
function Parser:process_line(line)
    self.line_number = self.line_number + 1

    if self.mode == 'not_started' then
        if trim(line) == BEGIN_MARKER then
            self.mode = 'started'
            return nil
        end
        return invalid_patch("The first line of the patch must be '*** Begin Patch'")
    elseif self.mode == 'started' then
        local handled, err = self:handle_headers(trim(line))
        if err then
            return err
        end
        if handled then
            return nil
        end
        return invalid_hunk(self.line_number, INVALID_HEADER_FMT:format(trim(line)))
    elseif self.mode == 'add' then
        local handled, err = self:handle_headers(trim(line))
        if err then
            return err
        end
        if handled then
            return nil
        end
        if line:sub(1, 1) == '+' then
            local hunk = self:last_hunk()
            hunk.contents = hunk.contents .. line:sub(2) .. '\n'
            return nil
        end
        return invalid_hunk(self.line_number, INVALID_HEADER_FMT:format(trim(line)))
    elseif self.mode == 'delete' then
        local handled, err = self:handle_headers(trim(line))
        if err then
            return err
        end
        if handled then
            return nil
        end
        return invalid_hunk(self.line_number, INVALID_HEADER_FMT:format(trim(line)))
    elseif self.mode == 'update' then
        return self:process_update_line(line)
    elseif self.mode == 'ended' then
        if trim(line) == '' then
            return nil
        end
        return invalid_patch("The last line of the patch must be '*** End Patch'")
    end
end

--- Parse a patch into a list of hunks.
---@param patch string
---@return table[]? hunks, string? err
function M.parse(patch)
    if type(patch) ~= 'string' then
        return nil, invalid_patch('patch is not a string')
    end

    local trimmed = trim(patch)
    local lines = trimmed == '' and {} or vim.split(trimmed, '\n', { plain = true })
    -- Strip a single trailing \r per line (CRLF tolerance, mirrors push_delta).
    for i, line in ipairs(lines) do
        if line:sub(-1) == '\r' then
            lines[i] = line:sub(1, -2)
        end
    end

    local checked, berr = check_boundaries(lines)
    if not checked then
        return nil, berr
    end
    lines = checked

    local parser = new_parser()
    for _, line in ipairs(lines) do
        local err = parser:process_line(line)
        if err then
            return nil, err
        end
    end

    if parser.mode ~= 'ended' then
        return nil, invalid_patch("The last line of the patch must be '*** End Patch'")
    end

    return parser.hunks, nil
end

-- ---------------------------------------------------------------------------
-- Matcher (mirrors seek_sequence.rs) — 0-based start, 0-based result
-- ---------------------------------------------------------------------------

---@param lines string[]
---@param pattern string[]
---@param start integer 0-based
---@param eof boolean
---@return integer? index 0-based
function M.seek_sequence(lines, pattern, start, eof)
    local n = #lines
    local m = #pattern
    if m == 0 then
        return start
    end
    if m > n then
        return nil
    end
    local search_start = (eof and n >= m) and (n - m) or start

    -- exact
    for i = search_start, n - m do
        local ok = true
        for k = 1, m do
            if lines[i + k] ~= pattern[k] then
                ok = false
                break
            end
        end
        if ok then
            return i
        end
    end
    -- rstrip
    for i = search_start, n - m do
        local ok = true
        for k = 1, m do
            if rtrim(lines[i + k]) ~= rtrim(pattern[k]) then
                ok = false
                break
            end
        end
        if ok then
            return i
        end
    end
    -- trim both
    for i = search_start, n - m do
        local ok = true
        for k = 1, m do
            if trim(lines[i + k]) ~= trim(pattern[k]) then
                ok = false
                break
            end
        end
        if ok then
            return i
        end
    end
    -- TODO: unicode-normalisation tier (Codex's 4th pass) omitted for v1.
    return nil
end

-- ---------------------------------------------------------------------------
-- Applier (mirrors compute_replacements + apply_replacements)
-- ---------------------------------------------------------------------------

---@param original_lines string[]
---@param chunks table[]
---@param path string for error messages
---@return string[]? new_lines, string? err
function M.compute_new_lines(original_lines, chunks, path)
    path = path or '<buffer>'
    local replacements = {} -- { {start0, old_len, seg}, ... }
    local line_index = 0

    for _, chunk in ipairs(chunks) do
        if chunk.change_context then
            local idx = M.seek_sequence(original_lines, { chunk.change_context }, line_index, false)
            if idx then
                line_index = idx + 1
            else
                return nil, ("Failed to find context '%s' in %s"):format(chunk.change_context, path)
            end
        end

        if #chunk.old_lines == 0 then
            local insertion_idx = #original_lines
            table.insert(replacements, { insertion_idx, 0, chunk.new_lines })
        else
            local pattern = chunk.old_lines
            local new_slice = chunk.new_lines
            local found = M.seek_sequence(original_lines, pattern, line_index, chunk.is_end_of_file)

            if not found and pattern[#pattern] == '' then
                pattern = vim.list_slice(pattern, 1, #pattern - 1)
                if new_slice[#new_slice] == '' then
                    new_slice = vim.list_slice(new_slice, 1, #new_slice - 1)
                end
                found = M.seek_sequence(original_lines, pattern, line_index, chunk.is_end_of_file)
            end

            if found then
                table.insert(replacements, { found, #pattern, new_slice })
                line_index = found + #pattern
            else
                return nil,
                    ('Failed to find expected lines in %s:\n%s'):format(path, table.concat(chunk.old_lines, '\n'))
            end
        end
    end

    table.sort(replacements, function(a, b)
        return a[1] < b[1]
    end)

    local out = vim.list_extend({}, original_lines)
    for i = #replacements, 1, -1 do
        local start0, old_len, seg = replacements[i][1], replacements[i][2], replacements[i][3]
        for _ = 1, old_len do
            if start0 + 1 <= #out then
                table.remove(out, start0 + 1)
            end
        end
        for off, seg_line in ipairs(seg) do
            table.insert(out, start0 + off, seg_line)
        end
    end

    return out, nil
end

--- Parse `patch` and apply its Update File hunk to `lines`.
---@param lines string[] buffer lines (no trailing empty element)
---@param patch string
---@param opts? { path?: string }
---@return boolean ok, string[]? new_lines, string? err
function M.apply(lines, patch, opts)
    opts = opts or {}
    local hunks, err = M.parse(patch)
    if not hunks then
        return false, nil, err
    end

    local update_hunk
    for _, hunk in ipairs(hunks) do
        if hunk.kind == 'add' or hunk.kind == 'delete' then
            return false, nil, ("duet supports only '*** Update File' edits, got %s for '%s'"):format(hunk.kind, hunk.path)
        elseif hunk.kind == 'update' then
            if opts.path == nil or hunk.path == opts.path or update_hunk == nil then
                if opts.path == nil or hunk.path == opts.path then
                    update_hunk = hunk
                    break
                end
                update_hunk = update_hunk or hunk
            end
        end
    end

    if not update_hunk then
        return false, nil, invalid_patch('patch contained no *** Update File hunk')
    end

    local new_lines, cerr = M.compute_new_lines(lines, update_hunk.chunks, update_hunk.path)
    if not new_lines then
        return false, nil, cerr
    end
    return true, new_lines, nil
end

return M
