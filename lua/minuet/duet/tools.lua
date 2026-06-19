-- Duet NES tool definitions (Codex-style) and the `read` handler.
-- Schema validated live against gpt-oss-120b on OpenRouter (see duet-nes-spec.md).

local M = {}

--- The OpenAI/OpenRouter `tools` array exposed to the model.
---@return table[]
function M.specs()
    return {
        {
            type = 'function',
            ['function'] = {
                name = 'apply_patch',
                description = 'Apply a single small Codex-style patch to the current file. '
                    .. 'The `input` is the full text from `*** Begin Patch` to `*** End Patch`. '
                    .. 'Use only `*** Update File` with one small hunk; context lines must match the current buffer exactly.',
                parameters = {
                    type = 'object',
                    properties = {
                        input = {
                            type = 'string',
                            description = 'The `*** Begin Patch` ... `*** End Patch` text.',
                        },
                    },
                    required = { 'input' },
                },
            },
        },
        {
            type = 'function',
            ['function'] = {
                name = 'read',
                description = 'Read the current buffer (optionally a 1-based inclusive line range) '
                    .. 'to re-check the exact text before emitting a patch.',
                parameters = {
                    type = 'object',
                    properties = {
                        start_line = { type = 'integer', description = '1-based first line (optional).' },
                        end_line = { type = 'integer', description = '1-based last line (optional).' },
                    },
                },
            },
        },
    }
end

--- Handle a `read` tool call: return the exact buffer text for the range so the
--- model can re-anchor its patch context.
---@param bufnr integer
---@param args table
---@param lines_override? string[]
---@return string
function M.read_result(bufnr, args, lines_override)
    local lines = lines_override or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local n = #lines
    local s = math.max(1, math.floor(tonumber(args.start_line) or 1))
    local e = math.min(n, math.floor(tonumber(args.end_line) or n))
    if e < s then
        s, e = 1, n
    end
    local slice = {}
    for i = s, e do
        table.insert(slice, lines[i])
    end
    return ('Current buffer lines %d-%d (exact text):\n%s'):format(s, e, table.concat(slice, '\n'))
end

return M
