-- Live probe: does gpt-oss-120b on OpenRouter emit an appliable apply_patch NES
-- edit via tool-calling? Run with:  nvim -l tests/harness/probe_gptoss.lua
-- Prototypes the real duet tool schema + prompt; validates the whole premise.

package.path = '/home/admin/code/lua/minuet-ai.nvim/lua/?.lua;' .. package.path
local ap = require 'minuet.duet.apply_patch'

-- Current buffer state: the user has ALREADY renamed `timeout` -> `timeout_secs`
-- on its declaration (line 1). The usage on line 4 still says `timeout`.
local file_lines = {
    'local timeout_secs = 30',
    '',
    'local function connect(host)',
    '  return open(host, timeout)',
    'end',
}
local cursor_view = table.concat({
    'local timeout_secs = 30',
    '',
    'local function connect(host)',
    '  return open(host, <|cursor|>timeout)',
    'end',
}, '\n')

-- The user's recent edit, shown in apply_patch dialect with context.
local recent_edit = table.concat({
    '*** Begin Patch',
    '*** Update File: net.lua',
    '@@',
    '-local timeout = 30',
    '+local timeout_secs = 30',
    ' ',
    ' local function connect(host)',
    '*** End Patch',
}, '\n')

local system = table.concat({
    'You are a next-edit-prediction engine inside a code editor.',
    'You are given the user\'s recent edits and the current file with a <|cursor|> marker.',
    'Predict the SINGLE smallest next edit the user is most likely to make next, and emit it',
    'by calling the `apply_patch` tool. On a multi-site rename, emit only the NEXT occurrence,',
    'not all of them. You only have the `*** Update File` capability of apply_patch: a single',
    'small hunk, no Add/Delete/Move. If no edit is warranted, reply with the text `*** No Edit`.',
}, '\n')

local user = table.concat({
    'Recent edits (oldest to newest):',
    '',
    recent_edit,
    '',
    'Current file `net.lua` (<|cursor|> marks the cursor; it is not real text):',
    '',
    cursor_view,
}, '\n')

local body = {
    model = 'openai/gpt-oss-120b',
    messages = {
        { role = 'system', content = system },
        { role = 'user', content = user },
    },
    tools = {
        {
            type = 'function',
            ['function'] = {
                name = 'apply_patch',
                description = 'Apply a Codex-style patch. The `input` is the full text from '
                    .. '`*** Begin Patch` to `*** End Patch`.',
                parameters = {
                    type = 'object',
                    properties = {
                        input = { type = 'string', description = 'The *** Begin Patch ... *** End Patch text.' },
                    },
                    required = { 'input' },
                },
            },
        },
        {
            type = 'function',
            ['function'] = {
                name = 'read',
                description = 'Read the current buffer (optionally a 1-based line range) to re-check exact state.',
                parameters = {
                    type = 'object',
                    properties = {
                        start_line = { type = 'integer' },
                        end_line = { type = 'integer' },
                    },
                },
            },
        },
    },
    tool_choice = 'auto',
    reasoning = { effort = 'low' },
    provider = { sort = 'throughput' },
}

local json = vim.json.encode(body)
local started = vim.uv.now()
local res = vim
    .system({
        'curl',
        '-sS',
        'https://openrouter.ai/api/v1/chat/completions',
        '-H',
        'Content-Type: application/json',
        '-H',
        'Authorization: Bearer ' .. (os.getenv 'OPENROUTER_API_KEY' or ''),
        '-d',
        json,
    }, { text = true })
    :wait()
local elapsed = vim.uv.now() - started

print('=== HTTP latency (ms): ' .. elapsed)
local ok_decode, resp = pcall(vim.json.decode, res.stdout)
if not ok_decode then
    print('DECODE FAIL. raw response:')
    print(res.stdout)
    os.exit(1)
end
if resp.error then
    print('API ERROR: ' .. vim.inspect(resp.error))
    os.exit(1)
end

local msg = resp.choices[1].message
print('=== model used: ' .. (resp.model or '?'))
print('=== reasoning: ' .. tostring(msg.reasoning and msg.reasoning:sub(1, 400) or '(none)'))
print('=== content: ' .. tostring(msg.content ~= '' and msg.content or '(empty)'))

local patch
if msg.tool_calls and msg.tool_calls[1] then
    local call = msg.tool_calls[1]
    print('=== tool called: ' .. call['function'].name)
    local args = vim.json.decode(call['function'].arguments)
    patch = args.input
elseif type(msg.content) == 'string' and msg.content:find '%*%*%* Begin Patch' then
    patch = msg.content
end

if not patch then
    print('=== NO PATCH RETURNED (model may have declined). Done.')
    os.exit(0)
end

print('=== patch returned:\n' .. patch)

local applied, new_lines, err = ap.apply(file_lines, patch, { path = 'net.lua' })
print('=== apply ok: ' .. tostring(applied))
if applied then
    print('=== buffer AFTER:\n' .. table.concat(new_lines, '\n'))
    local joined = table.concat(new_lines, '\n')
    if joined:find 'open%(host, timeout_secs%)' and not joined:find 'open%(host, timeout%)' then
        print('=== VERDICT: PASS — model propagated the rename to the usage site')
    else
        print('=== VERDICT: applied, but not the expected propagation')
    end
else
    print('=== apply error: ' .. tostring(err))
end
