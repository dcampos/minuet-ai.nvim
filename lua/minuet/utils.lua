local M = {}

function M.replace_string_literal(text, needle, replacement)
    local result = {}
    local start_index = 1

    while true do
        local match_start, match_end = text:find(needle, start_index, true)
        if not match_start then
            table.insert(result, text:sub(start_index))
            break
        end

        table.insert(result, text:sub(start_index, match_start - 1))
        table.insert(result, replacement)
        start_index = match_end + 1
    end

    return table.concat(result)
end

function M.notify(msg, minuet_level, vim_level, opts)
    local config = require('minuet').config
    local notify_levels = {
        debug = 0,
        verbose = 1,
        warn = 2,
        error = 3,
    }

    if config.notify and notify_levels[minuet_level] >= notify_levels[config.notify] then
        vim.notify(msg, vim_level, opts)
    end
end

--- Get API key from environment variable or function.
---@param env_var string|function environment variable name or function returning API key
---@return string? API key or nil if not found or invalid
function M.get_api_key(env_var)
    local api_key
    if type(env_var) == 'function' then
        api_key = env_var()
    elseif type(env_var) == 'string' then
        api_key = vim.env[env_var]
    end

    if type(api_key) ~= 'string' or api_key == '' then
        return nil
    end

    return api_key
end

-- referenced from cmp_ai
function M.make_tmp_file(content)
    local tmp_file = os.tmpname()

    local f = io.open(tmp_file, 'w+')
    if f == nil then
        M.notify('Cannot open temporary message file: ' .. tmp_file, 'error', vim.log.levels.ERROR)
        return
    end

    local result, json = pcall(vim.json.encode, content)

    if not result then
        M.notify('Failed to encode completion request data', 'error', vim.log.levels.ERROR)
        return
    end

    f:write(json)
    f:close()

    return tmp_file
end

function M.make_system_prompt(template, n_completion)
    ---- replace the placeholders in the template with the values in the table
    local system_prompt = template.template
    local n_completion_template = template.n_completion_template

    if type(system_prompt) == 'function' then
        system_prompt = system_prompt()
    end

    if type(n_completion_template) == 'function' then
        n_completion_template = n_completion_template()
    end

    if type(n_completion_template) == 'string' and type(n_completion) == 'number' then
        n_completion_template = string.format(n_completion_template, n_completion)
        system_prompt = M.replace_string_literal(system_prompt, '{{{n_completion_template}}}', n_completion_template)
    end

    template.template = nil
    template.n_completion_template = nil

    for k, v in pairs(template) do
        if type(v) == 'function' then
            system_prompt = M.replace_string_literal(system_prompt, '{{{' .. k .. '}}}', v())
        elseif type(v) == 'string' then
            system_prompt = M.replace_string_literal(system_prompt, '{{{' .. k .. '}}}', v)
        end
    end

    ---- remove the placeholders that are not replaced
    system_prompt = system_prompt:gsub('{{{.*}}}', '')

    return system_prompt
end

--- Return val if val is not a function, else call val and return the value
---
---@generic T
---@param val T|fun(): T
---@return T
function M.get_or_eval_value(val)
    if type(val) ~= 'function' then
        return val
    end
    return val()
end

---@return string
function M.add_language_comment()
    if vim.bo.ft == nil or vim.bo.ft == '' then
        return ''
    end

    local language_string = 'language: ' .. vim.bo.ft
    local commentstring = vim.bo.commentstring

    if commentstring == nil or commentstring == '' then
        return '# ' .. language_string
    end

    -- Directly replace %s with the comment
    if commentstring:find '%%s' then
        language_string = commentstring:gsub('%%s', language_string)
        return language_string
    end

    -- Fallback to prepending comment if no %s found
    return commentstring .. ' ' .. language_string
end

---@return string
function M.add_tab_comment()
    if vim.bo.ft == nil or vim.bo.ft == '' then
        return ''
    end

    local tab_string
    local tabwidth = vim.bo.softtabstop > 0 and vim.bo.softtabstop or vim.bo.shiftwidth
    local commentstring = vim.bo.commentstring

    if vim.bo.expandtab and tabwidth > 0 then
        tab_string = 'indentation: use ' .. tabwidth .. ' spaces for a tab'
    elseif not vim.bo.expandtab then
        tab_string = 'indentation: use \t for a tab'
    else
        return ''
    end

    if commentstring == nil or commentstring == '' then
        return '# ' .. tab_string
    end

    -- Directly replace %s with the comment
    if commentstring:find '%%s' then
        tab_string = commentstring:gsub('%%s', tab_string)
        return tab_string
    end

    -- Fallback to prepending comment if no %s found
    return commentstring .. ' ' .. tab_string
end

-- Copied from blink.cmp.Context. Because we might use nvim-cmp instead of
-- blink-cmp, so blink might not be installed, so we create another class here
-- and use it instead.

--- @class minuet.BlinkCmpContext
--- @field line string
--- @field cursor number[]

---@param blink_context minuet.BlinkCmpContext?
function M.make_cmp_context(blink_context)
    local self = {}
    local cursor
    if blink_context then
        cursor = blink_context.cursor
        self.cursor_line = blink_context.line
    else
        cursor = vim.api.nvim_win_get_cursor(0)
        self.cursor_line = vim.api.nvim_get_current_line()
    end

    self.cursor = {}
    self.cursor.row = cursor[1]
    self.cursor.col = cursor[2] + 1
    self.cursor.line = self.cursor.row - 1
    -- self.cursor.character = require('cmp.utils.misc').to_utfindex(self.cursor_line, self.cursor.col)
    self.cursor_before_line = string.sub(self.cursor_line, 1, self.cursor.col - 1)
    self.cursor_after_line = string.sub(self.cursor_line, self.cursor.col)
    return self
end

---@class minuet.LSPPositionParams
---@field context {triggerKind: number}
---@field position {character: number, line: number}
---@field textDocument {uri: string}

---@param params minuet.LSPPositionParams
function M.make_cmp_context_from_lsp_params(params)
    local bufnr
    local self = {}
    if params.textDocument.uri == 'file://' then
        bufnr = 0
    else
        bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    end

    local row = params.position.line
    local col = math.max(params.position.character, 0)
    self.cursor = {
        row = row,
        line = row,
        col = col,
    }

    local current_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
    local cursor_before_line = vim.fn.strcharpart(current_line, 0, col)
    local cursor_after_line = vim.fn.strcharpart(current_line, col)

    self.cursor_before_line = cursor_before_line
    self.cursor_after_line = cursor_after_line
    return self
end

local function collect_nearby_lines(bufnr, start_line, step, max_chars)
    local chunks = {}
    local chars = 0
    local block_size = 128
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local line = start_line

    while chars < max_chars do
        if step < 0 then
            if line <= 0 then
                break
            end
            local chunk_start = math.max(0, line - block_size)
            local lines = vim.api.nvim_buf_get_lines(bufnr, chunk_start, line, false)
            if #lines == 0 then
                break
            end
            local chunk = table.concat(lines, '\n')
            table.insert(chunks, 1, chunk)
            chars = chars + vim.fn.strchars(chunk) + 1
            line = chunk_start
        else
            if line >= line_count then
                break
            end
            local chunk_end = math.min(line_count, line + block_size)
            local lines = vim.api.nvim_buf_get_lines(bufnr, line, chunk_end, false)
            if #lines == 0 then
                break
            end
            local chunk = table.concat(lines, '\n')
            table.insert(chunks, chunk)
            chars = chars + vim.fn.strchars(chunk) + 1
            line = chunk_end
        end
    end

    return table.concat(chunks, '\n')
end

-- Find the LATEST occurrence of prev_pre inside raw_before such that the
-- text after the match (typed-since-anchor) is at most growth_slack chars.
-- Returns raw_before:sub(match_start) on success, or nil.
--
-- This is what lets the new request reuse the same anchor as the previous
-- one: the returned lines_before begins at the same buffer-content boundary
-- as prev_pre, then extends by typed_since chars. The whole point is to keep
-- the leading bytes of the FIM prompt byte-identical across requests so the
-- server's KV cache stays warm.
---@param raw_before string  buffer text up to cursor (fetched with extra slack)
---@param prev_pre string  lines_before from the previous request
---@param growth_slack integer max chars of new text past the anchor
---@return string?
local function extend_prefix_anchor(raw_before, prev_pre, growth_slack)
    if type(prev_pre) ~= 'string' or prev_pre == '' then
        return nil
    end
    local prev_blen = #prev_pre
    local raw_blen = #raw_before
    if prev_blen > raw_blen then
        return nil
    end

    -- Earliest byte position the match could start while still keeping
    -- typed_since within slack (worst case 4 bytes/char for UTF-8).
    local earliest = raw_blen - prev_blen + 1 - growth_slack * 4
    if earliest < 1 then
        earliest = 1
    end

    local best
    local pos = earliest
    while true do
        local found = raw_before:find(prev_pre, pos, true)
        if not found then
            break
        end
        local tail = raw_before:sub(found + prev_blen)
        local typed_since = vim.fn.strchars(tail)
        if typed_since <= growth_slack then
            best = found
        end
        pos = found + 1
    end

    if best then
        return raw_before:sub(best)
    end
    return nil
end

-- If raw_after starts with prev_suf, return prev_suf (the suffix is "still
-- there"). Returns nil otherwise. While the user only types into the prefix
-- region, the buffer past the cursor is unchanged in content, so the
-- previous suffix string is still the right one to send — and keeping it
-- byte-identical is what allows SPM models to reuse SUF KV across requests.
---@param raw_after string buffer text from cursor onward
---@param prev_suf string lines_after from the previous request
---@return string?
local function pin_suffix_anchor(raw_after, prev_suf)
    if type(prev_suf) ~= 'string' or prev_suf == '' then
        return nil
    end
    if #prev_suf > #raw_after then
        return nil
    end
    if raw_after:sub(1, #prev_suf) == prev_suf then
        return prev_suf
    end
    return nil
end

---@class minuet.ContextAnchor
---@field prev_lines_before string lines_before sent in the previous request
---@field prev_lines_after string lines_after sent in the previous request
---@field growth_slack? integer Max new chars typed since the anchor before
---we re-anchor. Defaults to 0 (only reuse when cursor hasn't moved).

--- Get the context around the cursor position for code completion.
---
--- The optional `anchor` parameter keeps consecutive requests' prompt prefix
--- region byte-stable so the server's KV cache stays warm across keystrokes.
--- This matters most for SPM-trained FIM models: when the suffix segment is
--- before the prefix segment, appending characters at the cursor edge only
--- invalidates the trailing few tokens. Without an anchor, the legacy window
--- slides on every keystroke and every request is a fresh cache miss. With
--- one, we extend `prev_lines_before` by the typed-since chars and pin
--- `prev_lines_after` until the suffix content stops matching or growth_slack
--- is exceeded — at which point we re-anchor by falling back to the standard
--- fresh window (single chunked invalidation rather than per-char).
---@param cmp_context table Cursor + cursor_before_line/cursor_after_line.
---@param cfg? table Effective config; overrides context_window/context_ratio.
---@param anchor? minuet.ContextAnchor Previous request hint for cache reuse.
---@return table { lines_before, lines_after, opts = { is_incomplete_before, is_incomplete_after, anchored? } }
function M.get_context(cmp_context, cfg, anchor)
    local config = cfg or require('minuet').config

    local cursor = cmp_context.cursor
    local bufnr = 0
    local max_side_chars = config.context_window

    -- Pull a little extra so anchor extension can grow into slack on top of
    -- the standard window. With no anchor, growth_slack == 0 reproduces the
    -- legacy fetch size exactly.
    local growth_slack = (anchor and anchor.growth_slack) or 0
    local fetch_chars = max_side_chars + growth_slack

    local before_prefix = collect_nearby_lines(bufnr, cursor.line, -1, fetch_chars)
    local after_suffix = collect_nearby_lines(bufnr, cursor.line + 1, 1, fetch_chars)

    local raw_before = before_prefix .. '\n' .. cmp_context.cursor_before_line
    local raw_after = cmp_context.cursor_after_line .. '\n' .. after_suffix

    local n_chars_before = vim.fn.strchars(raw_before)
    local n_chars_after = vim.fn.strchars(raw_after)

    -- Anchor reuse only helps when the fresh window would left-truncate the
    -- prefix: that is the one case where the prefix slides and consecutive
    -- fresh prompts shed their shared leading bytes (and the server's KV cache
    -- with them). When the prefix already reaches the top of the buffer -- a
    -- short file that fits whole in context_window, or the cursor near the top
    -- of a long one -- the fresh window is already prefix-stable as you type
    -- forward, so anchoring buys no cache warmth and would only risk dropping
    -- text inserted above the cursor (a title, an import) from the prompt.
    -- This condition mirrors when the truncation below sets is_incomplete_before.
    local prefix_would_slide = n_chars_before + n_chars_after > config.context_window
        and n_chars_before >= config.context_window * config.context_ratio

    -- Try anchor reuse. Both prefix AND suffix anchors must match: SPM-style
    -- KV reuse needs every token before MID to be at the same position with
    -- the same content. Mismatch on either side means we'd lose cache from
    -- the mismatch onwards, so we may as well re-anchor cleanly.
    if prefix_would_slide and anchor and anchor.prev_lines_before and anchor.prev_lines_after then
        local pre = extend_prefix_anchor(raw_before, anchor.prev_lines_before, growth_slack)
        local suf = pin_suffix_anchor(raw_after, anchor.prev_lines_after)
        if pre and suf then
            return {
                lines_before = pre,
                lines_after = suf,
                opts = {
                    -- An anchor-reused context is, by construction, the same
                    -- window the previous request opened (just grown at the
                    -- cursor edge). Truncation didn't happen this turn.
                    is_incomplete_before = false,
                    is_incomplete_after = false,
                    anchored = true,
                },
            }
        end
    end

    -- Re-anchor path: standard fresh window centered on cursor.
    local lines_before = raw_before
    local lines_after = raw_after

    local opts = {
        is_incomplete_before = false,
        is_incomplete_after = false,
    }

    if n_chars_before + n_chars_after > config.context_window then
        if n_chars_before < config.context_window * config.context_ratio then
            lines_after = vim.fn.strcharpart(lines_after, 0, config.context_window - n_chars_before)
            opts.is_incomplete_after = true
        elseif n_chars_after < config.context_window * (1 - config.context_ratio) then
            lines_before = vim.fn.strcharpart(lines_before, n_chars_before + n_chars_after - config.context_window)
            opts.is_incomplete_before = true
        else
            lines_after = vim.fn.strcharpart(lines_after, 0, math.floor(config.context_window * (1 - config.context_ratio)))
            lines_before = vim.fn.strcharpart(
                lines_before,
                n_chars_before - math.floor(config.context_window * config.context_ratio)
            )
            opts.is_incomplete_before = true
            opts.is_incomplete_after = true
        end
    end

    return {
        lines_before = lines_before,
        lines_after = lines_after,
        opts = opts,
    }
end

---remove the sequence and the rest part from text.
---@param text string?
---@param context { lines_before: string?, lines_after: string? }
---@param cfg? table Effective config (defaults to global).
---@return string?
function M.filter_text(text, context, cfg)
    local config = cfg or require('minuet').config

    -- Handle nil values
    if not text or not context then
        return text
    end

    local lines_before = context.lines_before
    local lines_after = context.lines_after

    -- Handle nil context values
    if not lines_before and not lines_after then
        return text
    end

    if config.before_cursor_filter_length <= 0 and config.after_cursor_filter_length <= 0 then
        return text
    end

    text = M.remove_spaces_single(text or '', true)
    lines_before = M.remove_spaces_single(lines_before or '')
    lines_after = M.remove_spaces_single(lines_after or '')

    if not text then
        return
    end

    local filtered_text = text

    -- Filter based on context before cursor (trim from the beginning of completion)
    if lines_before and config.before_cursor_filter_length > 0 then
        local match_before = M.find_longest_match(filtered_text, lines_before)
        local match_len = vim.fn.strchars(match_before)
        if match_before and match_len >= config.before_cursor_filter_length then
            -- Remove the matching part from the beginning of the completion
            filtered_text = vim.fn.strcharpart(filtered_text, match_len)
        end
    end

    -- Filter based on context after cursor (trim from the end of completion)
    if lines_after and config.after_cursor_filter_length > 0 then
        local match_after = M.find_longest_match(lines_after, filtered_text)
        local match_len = vim.fn.strchars(match_after)
        if match_after and match_len >= config.after_cursor_filter_length then
            -- Remove the matching part from the end of the completion
            local text_len = vim.fn.strchars(filtered_text)
            filtered_text = vim.fn.strcharpart(filtered_text, 0, text_len - match_len)
        end
    end

    return filtered_text
end

--- Remove the trailing and leading spaces for a single string item
---@param item string
---@param keep_leading_newline? boolean
---@return string?
function M.remove_spaces_single(item, keep_leading_newline)
    if not item:find '%S' then -- skip entries that contain only whitespace
        return nil
    end

    local start_pattern = keep_leading_newline and '^[ \t]+' or '^%s+'

    -- replace the trailing spaces
    item = item:gsub('%s+$', '')
    -- replace the leading spaces
    item = item:gsub(start_pattern, '')

    return item
end

--- Remove the trailing and leading spaces for each string in the table
---@param items string[]
---@param keep_leading_newline? boolean
---@return string[]
function M.remove_spaces(items, keep_leading_newline)
    local new = {}

    for _, item in ipairs(items) do
        local item_processed = M.remove_spaces_single(item, keep_leading_newline)
        if item then
            table.insert(new, item_processed)
        end
    end

    return new
end

-- Find the longest string that is a prefix of A and a suffix of B. The
-- function iterates from the longest possible match length downwards for
-- efficiency.  If A or B are not strings, it returns an empty string.
---@param a string?
---@param b string?
function M.find_longest_match(a, b)
    -- Ensure both inputs are strings to avoid errors.
    if type(a) ~= 'string' or type(b) ~= 'string' then
        return ''
    end

    -- The longest possible match is limited by the shorter of the two strings.
    local max_len = math.min(#a, #b)

    -- Iterate downwards from the maximum possible length to 1.
    -- This is more efficient because the first match we find will be the longest one.
    for len = max_len, 1, -1 do
        -- Extract the prefix from string 'a'.
        local prefix_a = string.sub(a, 1, len)

        -- Extract the suffix from string 'b'.
        -- Negative indices in string.sub count from the end of the string.
        local suffix_b = string.sub(b, -len)

        -- If the prefix of 'a' matches the suffix of 'b', we've found our longest match.
        if prefix_a == suffix_b then
            return prefix_a
        end
    end

    -- If the loop completes without finding any match, return an empty string.
    return ''
end

--- If the last word of b is not a substring of the first word of a,
--- And it there are no trailing spaces for b and no leading spaces for a,
--- prepend the last word of b to a.
---@param a string?
---@param b string?
---@return string?
function M.prepend_to_complete_word(a, b)
    if not a or not b then
        return a
    end

    local last_word_b = b:match '[%w_-]+$'
    local first_word_a = a:match '^[%w_-]+'

    if last_word_b and first_word_a and not first_word_a:find(last_word_b, 1, true) then
        a = last_word_b .. a
    end

    return a
end

---Adjust indentation of lines based on direction
---@param lines string The string containing the lines to adjust
---@param ref_line string The reference line used to adjust identation
---@param direction "+" | "-" "+" for adding, "-" for removing
---@return string Lines Adjusted lines
function M.adjust_indentation(lines, ref_line, direction)
    local indentation = string.match(ref_line or '', '^%s*') or ''

    ---@diagnostic disable-next-line:cast-local-type
    lines = vim.split(lines, '\n')
    local new_lines = {}

    for _, line in ipairs(lines) do
        if direction == '+' then
            table.insert(new_lines, indentation .. line)
        elseif direction == '-' then
            -- Remove indentation if it exists at the start of the line
            if line:sub(1, #ref_line) == indentation then
                line = line:sub(#ref_line + 1)
            end
            table.insert(new_lines, line)
        end
    end

    return table.concat(new_lines, '\n')
end

---@param context table
---@param template table
---@return string[]
function M.make_chat_llm_shot(context, template)
    local inputs = template.template
    if type(inputs) == 'string' then
        inputs = { inputs }
    end
    local context_before_cursor = context.lines_before
    local context_after_cursor = context.lines_after
    local opts = context.opts

    -- Store the template value before clearing it
    template.template = nil
    local results = {}

    for _, input in ipairs(inputs) do
        local parts = {}
        local last_pos = 1
        while true do
            local start_pos, end_pos = input:find('{{{.-}}}', last_pos)
            if not start_pos then
                -- Add the remaining part of the string
                table.insert(parts, input:sub(last_pos))
                break
            end

            -- Add the text before the placeholder
            table.insert(parts, input:sub(last_pos, start_pos - 1))

            -- Extract placeholder key
            local key = input:sub(start_pos + 3, end_pos - 3)

            -- Get the replacement value if it exists
            if template[key] then
                local value = template[key](context_before_cursor, context_after_cursor, opts)
                table.insert(parts, value)
            end

            last_pos = end_pos + 1
        end

        local result = table.concat(parts)
        table.insert(results, result)
    end

    return results
end

---@param response vim.SystemCompleted
function M.no_stream_decode(response, data_file, provider, get_text_fn)
    os.remove(data_file)

    if response.code ~= 0 then
        if response.code == 28 then
            M.notify('Request timed out.', 'warn', vim.log.levels.WARN)
        else
            M.notify(string.format('Request failed with exit code %d', response.code), 'error', vim.log.levels.ERROR)
        end
        return
    end

    local result = response.stdout or ''
    local success, json = pcall(vim.json.decode, result)
    if not success then
        if result ~= '' then
            M.notify(
                'Failed to parse ' .. provider .. ' API response as json: ' .. vim.inspect(result),
                'error',
                vim.log.levels.INFO
            )
        end
        return
    end

    local result_str

    success, result_str = pcall(get_text_fn, json)

    if not success or not result_str or result_str == '' then
        if result:find 'error' then
            M.notify(provider .. ' returns error: ' .. vim.inspect(result), 'error', vim.log.levels.INFO)
        else
            M.notify(provider .. ' returns no text: ' .. vim.inspect(json), 'verbose', vim.log.levels.INFO)
        end
        return
    end

    return result_str
end

---@param response vim.SystemCompleted
function M.stream_decode(response, data_file, provider, get_text_fn)
    os.remove(data_file)

    if not (response.code == 28 or response.code == 0) then
        M.notify(string.format('Request failed with exit code %d', response.code), 'error', vim.log.levels.ERROR)
        return
    end

    local result = {}
    local responses = vim.split(response.stdout or '', '\n', { plain = true, trimempty = false })

    for _, line in ipairs(responses) do
        local success, json, text

        line = line:gsub('^data:', '')
        success, json = pcall(vim.json.decode, line)
        if not success then
            goto continue
        end

        success, text = pcall(get_text_fn, json)
        if not success then
            goto continue
        end

        if type(text) == 'string' and text ~= '' then
            table.insert(result, text)
        end
        ::continue::
    end

    local result_str = #result > 0 and table.concat(result) or nil

    if not result_str then
        local notified_on_error = false
        for _, line in ipairs(responses) do
            if line:find 'error' then
                M.notify(
                    provider .. ' returns error on streaming: ' .. vim.inspect(responses),
                    'error',
                    vim.log.levels.INFO
                )

                notified_on_error = true

                break
            end
        end

        if not notified_on_error then
            M.notify(
                provider .. ' returns no text on streaming: ' .. vim.inspect(responses),
                'verbose',
                vim.log.levels.INFO
            )
        end
        return
    end

    return result_str
end

M.add_single_line_entry = function(list)
    local newlist = {}

    for _, item in ipairs(list) do
        if type(item) == 'string' then
            -- single line completion item should be preferred.
            table.insert(newlist, item)
            table.insert(newlist, 1, vim.split(item, '\n')[1])
        end
    end

    return newlist
end

--- dedup the items in a list
M.list_dedup = function(list)
    local hash = {}
    local items_cleaned = {}
    for _, item in ipairs(list) do
        if type(item) == 'string' and not hash[item] then
            hash[item] = true
            table.insert(items_cleaned, item)
        end
    end
    return items_cleaned
end

---@class minuet.EventData
---@field provider string the name of the provider
---@field name string the name of the subprovider for openai-compatible and openai-fim-compatible
---@field model string the model name used during this event
---@field n_requests number the number of requests launched during this event
---@field request_idx? number the index of the current request
---@field timestamp number the timestamp of the event at MminuetRequestStartedPre

---@param event string The minuet event to run
---@param opts minuet.EventData The minuet data event
function M.run_event(event, opts)
    opts = opts or {}
    vim.api.nvim_exec_autocmds('User', { pattern = event, data = opts })
end

---@param end_point string
---@param headers table<string, string>
---@param data_file string
---@param cfg? table Effective config (defaults to global). Honors per-call
---curl_extra_args, request_timeout and proxy overrides.
---@return string[]
function M.make_curl_args(end_point, headers, data_file, cfg)
    local config = cfg or require('minuet').config

    local args = { '-L' }
    for _, arg in ipairs(config.curl_extra_args) do
        table.insert(args, arg)
    end

    for k, v in pairs(headers) do
        table.insert(args, '-H')
        table.insert(args, k .. ': ' .. v)
    end
    table.insert(args, '--max-time')
    table.insert(args, tostring(config.request_timeout))
    table.insert(args, '-d')
    table.insert(args, '@' .. data_file)

    if config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, config.proxy)
    end

    table.insert(args, end_point)

    return args
end

--- Runs a list of functions one by one.
--- Stops and returns false immediately if a function returns false.
--- @param hooks function[] A list of functions to run.
--- @param ... any Arguments to pass to each function.
--- @return boolean Returns false if any hook fails, true otherwise.
function M.run_hooks_until_failure(hooks, ...)
    if #hooks == 0 then
        return true
    end
    for _, func in ipairs(hooks) do
        local result = func(...)

        if not result then
            return false
        end
    end

    return true
end

return M
