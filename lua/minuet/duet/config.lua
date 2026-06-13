local default_markers = {
    editable_region_start = '<editable_region>',
    editable_region_end = '</editable_region>',
    cursor_position = '<cursor_position/>',
}
local function get_markers()
    local markers = default_markers
    if require('minuet').config then
        markers = require('minuet').config.duet.markers
    end
    return markers
end

local function render_markers(template)
    local shared_utils = require 'minuet.utils'

    local markers = get_markers()
    template =
        shared_utils.replace_string_literal(template, '{{{editable_region_start}}}', markers.editable_region_start)
    template = shared_utils.replace_string_literal(template, '{{{editable_region_end}}}', markers.editable_region_end)
    template = shared_utils.replace_string_literal(template, '{{{cursor_position}}}', markers.cursor_position)

    return template
end

local function make_default_prompt()
    return render_markers [[You are an AI editing engine that rewrites only the editable region in a document.

Input markers:
- `{{{editable_region_start}}}` and `{{{editable_region_end}}}` wrap the editable region.
- `{{{cursor_position}}}` marks the current cursor position inside that editable region.]]
end

local function make_default_guidelines()
    return render_markers [[Guidelines:
1. Return only the rewritten editable region, wrapped in `{{{editable_region_start}}}` and `{{{editable_region_end}}}`.
2. Include exactly one `{{{cursor_position}}}` marker inside the rewritten editable region.
3. Preserve indentation, formatting, blank lines, and surrounding syntax conventions. Keep the exact number of empty lines unless you are intentionally changing them.
4. For any text or code inside the editable region that is not intended to change, copy it verbatim. Do not paraphrase, refactor, reformat, or otherwise alter unchanged content.
5. Make only the smallest changes necessary to satisfy the requested edit.
6. Do not return explanations, markdown fences, or any content outside the editable region block.
7. Make the rewrite coherent with the surrounding non-editable text.]]
end

local default_system = {
    template = '{{{prompt}}}\n{{{guidelines}}}',
    prompt = make_default_prompt,
    guidelines = make_default_guidelines,
}

local function get_context_value(key)
    return function(context)
        return context[key] or ''
    end
end

---@type minuet.DuetChatInput
local default_chat_input = {
    template = function()
        return render_markers [[{{{non_editable_region_before}}}
{{{editable_region_start}}}
{{{editable_region_before_cursor}}}{{{cursor_position}}}{{{editable_region_after_cursor}}}
{{{editable_region_end}}}
{{{non_editable_region_after}}}]]
    end,
    non_editable_region_before = get_context_value 'non_editable_region_before',
    editable_region_before_cursor = get_context_value 'editable_region_before_cursor',
    editable_region_after_cursor = get_context_value 'editable_region_after_cursor',
    non_editable_region_after = get_context_value 'non_editable_region_after',
}

local default_few_shots = function()
    return {
        {
            role = 'user',
            content = render_markers [[type User = {
    id: string;
    name: string;
    role?: string;
    active?: boolean;
};

async function buildRequest(user: User, overrides: Record<string, any> = {}) {
    const baseHeaders = { 'content-type': 'application/json' };

{{{editable_region_start}}}
    const payload = {
        id: user.id,
        name: user.name,
    };

    return {
        method: 'POST',
        headers: baseHeaders,
        body: JSON.stringify(payload{{{cursor_position}}}),
    };
{{{editable_region_end}}}
}

export async function sendUser(user: User, overrides = {}) {
    const request = await buildRequest(user, overrides);
    return fetch('/api/users', request);
}]],
        },
        {
            role = 'assistant',
            content = render_markers [[{{{editable_region_start}}}
    const payload = {
        id: user.id,
        name: user.name,
        role: overrides.role ?? user.role ?? "viewer",
        active: overrides.active ?? user.active ?? true,
    };

    return {
        method: 'POST',
        headers: {
            ...baseHeaders,
            ...overrides.headers,
        },
        body: JSON.stringify(payload),
        signal: overrides.signal,
        keepalive: overrides.keepalive ?? false,{{{cursor_position}}}
    };
{{{editable_region_end}}}]],
        },
    }
end

local function make_openai_options()
    return {
        model = 'gpt-5.4-mini',
        api_key = 'OPENAI_API_KEY',
        end_point = 'https://api.openai.com/v1/chat/completions',
        system = vim.deepcopy(default_system),
        few_shots = default_few_shots,
        chat_input = vim.deepcopy(default_chat_input),
        optional = {},
        transform = {},
    }
end

local function make_claude_options()
    return {
        model = 'claude-haiku-4-5',
        api_key = 'ANTHROPIC_API_KEY',
        end_point = 'https://api.anthropic.com/v1/messages',
        system = vim.deepcopy(default_system),
        few_shots = default_few_shots,
        chat_input = vim.deepcopy(default_chat_input),
        max_tokens = 8192,
        optional = {},
        transform = {},
    }
end

local function make_gemini_options()
    return {
        model = 'gemini-3-flash-preview',
        api_key = 'GEMINI_API_KEY',
        end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
        system = vim.deepcopy(default_system),
        few_shots = default_few_shots,
        chat_input = vim.deepcopy(default_chat_input),
        optional = {},
        transform = {},
    }
end

local function make_openai_compatible_options()
    return {
        model = 'openai/gpt-oss-120b',
        api_key = 'OPENROUTER_API_KEY',
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        name = 'Openrouter',
        system = vim.deepcopy(default_system),
        few_shots = default_few_shots,
        chat_input = vim.deepcopy(default_chat_input),
        optional = {
            -- NES wants low latency and minimal reasoning.
            reasoning = { effort = 'low' },
            provider = { sort = 'throughput' },
        },
        transform = {},
    }
end

-- NES (apply_patch) session prompt. The model receives the user's recent edits
-- (apply_patch dialect) and the current file with a cursor marker, and predicts
-- the single next edit via the apply_patch tool.
local function make_nes_system(cursor_marker, no_edit_token)
    return ([[You are a next-edit-prediction engine inside the user's code editor.

You are given the user's recent edits (in apply_patch dialect, oldest to newest)
and the current file with a %s marker showing the cursor position. Predict the
SINGLE smallest next edit the user is most likely to make, and emit it by calling
the `apply_patch` tool.

Rules:
- Emit exactly ONE small edit. On a multi-site change such as a rename, emit only
  the NEXT occurrence, not all of them.
- You only have the `*** Update File` capability of apply_patch: a single small
  hunk. No `*** Add File`, `*** Delete File`, or `*** Move to`.
- The patch must apply to the CURRENT file: context and removed (`-`) lines must
  match the real buffer exactly. If unsure of the exact text, call `read` first,
  then emit the patch.
- The %s marker is not real text; never include it in a patch.
- If no edit is warranted, reply with the text `%s` and do not call a tool.]]):format(
        cursor_marker,
        cursor_marker,
        no_edit_token
    )
end

local DUET_CURSOR_MARKER = '<|cursor|>'
local DUET_NO_EDIT_TOKEN = '*** No Edit'

---@alias minuet.DuetChatInputFunction fun(context: table): string

--- Configuration for formatting duet chat input to the LLM
---@class minuet.DuetChatInput
---@field template string|fun(): string Template string with placeholders for context parts
---@field non_editable_region_before string|minuet.DuetChatInputFunction
---@field editable_region_before_cursor string|minuet.DuetChatInputFunction
---@field editable_region_after_cursor string|minuet.DuetChatInputFunction
---@field non_editable_region_after string|minuet.DuetChatInputFunction

---@class minuet.DuetEditableRegion
---@field lines_before integer
---@field lines_after integer
---@field before_region_filter_length integer
---@field after_region_filter_length integer

---@class minuet.DuetNonEditableRegion
---@field context_window integer
---@field context_ratio number

---@class minuet.DuetConfig
---@field provider string
---@field request_timeout integer
---@field editable_region minuet.DuetEditableRegion
---@field non_editable_region minuet.DuetNonEditableRegion
---@field markers { editable_region_start: string, editable_region_end: string, cursor_position: string }
---@field preview { cursor: string }
---@field provider_options table<string, table>
local M = {
    -- NES (apply_patch) is the active duet design; default to gpt-oss via OpenRouter.
    provider = 'openai_compatible',
    request_timeout = 15,
    editable_region = {
        lines_before = 8,
        lines_after = 15,
        before_region_filter_length = 30,
        after_region_filter_length = 30,
    },
    non_editable_region = {
        context_window = 40000,
        context_ratio = 0.75,
    },
    markers = vim.deepcopy(default_markers),
    preview = {
        cursor = '\u{f246}',
    },
    -- NES session settings (apply_patch flow). See duet-nes-spec.md.
    session = {
        cursor_marker = DUET_CURSOR_MARKER,
        no_edit_token = DUET_NO_EDIT_TOKEN,
        system = make_nes_system(DUET_CURSOR_MARKER, DUET_NO_EDIT_TOKEN),
        capability_reminder = 'Reminder: emit exactly one small `*** Update File` hunk via the apply_patch '
            .. 'tool; no Add/Delete/Move; context and `-` lines must match the current buffer exactly.',
        history_context_lines = 8,
        max_edits = 20,
        idle_minutes = 20,
        seed_edits = 3,
        capability_reminder_every = 5,
        max_attempts = 3,
        max_reads = 2,
        auto_trigger = false,
        debounce_ms = 150,
    },
    provider_options = {
        openai = make_openai_options(),
        claude = make_claude_options(),
        gemini = make_gemini_options(),
        openai_compatible = make_openai_compatible_options(),
    },
}

return M
