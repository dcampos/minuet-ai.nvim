-- Compare the shipped OpenRouter chat/tool-call NES path against Inception
-- Mercury Edit 2's native /edit/completions path on the corrected tableau pivot.
--
-- Run:
--   MERCURY_EVAL_STEPS=8 MERCURY_EVAL_REPEATS=3 MERCURY_EVAL_VARIANTS=O,M \
--     nvim --headless -u NONE -i NONE -n \
--       -c "luafile experiments/duet-nes/scripts/nes_mercury_edit.lua" -c "qa!"
--
-- Variants:
--   O: OpenRouter chat baseline (openai/gpt-oss-120b, apply_patch tool)
--   M: direct Inception Mercury Edit 2 (native tagged edit prompt)

local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { duet = { provider = 'openai_compatible' } }

local session = require 'minuet.duet.session'
local chat = require 'minuet.duet.chat'
local tools = require 'minuet.duet.tools'
local apply_patch = require 'minuet.duet.apply_patch'
local root = require('minuet').config
local scfg = root.duet.session

local STEPS = tonumber(os.getenv 'MERCURY_EVAL_STEPS') or 8
local REPEATS = tonumber(os.getenv 'MERCURY_EVAL_REPEATS') or 3
local EFFORT = os.getenv 'MINUET_EFFORT' or 'medium'
local VARIANTS = {}
for v in (os.getenv 'MERCURY_EVAL_VARIANTS' or 'O,M'):gmatch '[^,]+' do
    VARIANTS[#VARIANTS + 1] = v
end

root.duet.provider_options.openai_compatible.optional.reasoning.effort = EFFORT
root.duet.provider_options.inception_edit.lines_before = tonumber(os.getenv 'MERCURY_EDIT_LINES_BEFORE') or 5
root.duet.provider_options.inception_edit.lines_after = tonumber(os.getenv 'MERCURY_EDIT_LINES_AFTER') or 10

local PATH = 'main.typ'
local CTX = scfg.history_context_lines
local COPY = {
    { 'x_3', { 1, -1, 1, 0, 0, -1, -1 } },
    { 'x_4', { -1, -1, 0, 1, 0, -1, -3 } },
    { 'x_5', { 2, 1, 0, 0, 1, -1, 4 } },
    { 'z', { 0, 0, 0, 0, 0, -1, 0 } },
}
local TARGET = {
    { 'x_3', { 2, 0, 1, -1, 0, 0, 2 } },
    { 'x_0', { 1, 1, 0, -1, 0, 1, 3 } },
    { 'x_5', { 3, 2, 0, -1, 1, 0, 7 } },
    { 'z', { 1, 1, 0, -1, 0, 0, 3 } },
}
local COLNAME = { 'x_1', 'x_2', 'x_3', 'x_4', 'x_5', 'x_0', 'b' }

local function render_row(label, nums)
    local s = '  ' .. string.format('%-3s', label)
    local ends = { [0] = #s }
    for ci = 1, 7 do
        s = s .. ', ' .. string.format('%3d', nums[ci])
        ends[ci] = #s
    end
    return s .. ';', ends
end

local function build_doc(rows2)
    local L = {}
    local function add(...)
        for _, x in ipairs { ... } do
            L[#L + 1] = x
        end
    end
    local function header()
        add 'mat('
        add '  delim: "|",'
        add '  augment: #(hline: (1,4), vline: (1,7)),'
        add '  dot.c, x_1, x_2, x_3, x_4, x_5, x_0, b;'
    end
    add '#set text(lang: "es")'
    add '#set math.mat(delim: "[")'
    add('', '')
    add '= Taller 2.1: El método simplex revisado'
    add ''
    add '*Respuesta:* Iniciamos con el objetivo auxiliar $max - x_0$'
    add ''
    add '$'
    header()
    local t1 = #L + 1
    for _, r in ipairs(COPY) do
        add((render_row(r[1], r[2])))
    end
    add ')'
    add '$'
    add ''
    add 'El siguiente paso es meter $x_0$ a la base sacando $x_4$, la variable básica'
    add 'con el valor más negativo en la columna $b$ ($-3$); pivoteamos sobre la'
    add 'columna de $x_0$ usando la fila de $x_4$.'
    add ''
    add '$'
    header()
    local t2 = #L + 1
    for _, r in ipairs(rows2) do
        add((render_row(r[1], r[2])))
    end
    add ')'
    add '$'
    return L, t1, t2
end

local function build_edits()
    local edits = {}
    for ri = 1, 4 do
        if COPY[ri][1] ~= TARGET[ri][1] then
            edits[#edits + 1] = { row = ri, col = 0, desc = ('r%dc0 %s->%s'):format(ri, COPY[ri][1], TARGET[ri][1]) }
        end
        for ci = 1, 7 do
            if COPY[ri][2][ci] ~= TARGET[ri][2][ci] then
                edits[#edits + 1] = {
                    row = ri,
                    col = ci,
                    desc = ('r%dc%d %s:%d->%d'):format(ri, ci, COLNAME[ci], COPY[ri][2][ci], TARGET[ri][2][ci]),
                }
            end
        end
    end
    return edits
end

local function deepcopy_rows(rows)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = { r[1], vim.deepcopy(r[2]) }
    end
    return out
end

local function apply_edit(rows, e)
    if e.col == 0 then
        rows[e.row][1] = TARGET[e.row][1]
    else
        rows[e.row][2][e.col] = TARGET[e.row][2][e.col]
    end
end

local function set_cursor_for_edit(work, e)
    local lines, _, t2 = build_doc(work)
    local row = t2 + (e.row - 1)
    local _, ends = render_row(work[e.row][1], work[e.row][2])
    vim.api.nvim_win_set_cursor(0, { row, math.min(ends[e.col], #lines[row] - 1) })
    return row
end

local function changed_idx(cur, new_lines)
    for i = 1, math.max(#cur, #new_lines) do
        if cur[i] ~= new_lines[i] then
            return i
        end
    end
end

local function classify(cur, out, t1, t2, target_doc, cursor_row)
    if out.error then
        return 'error', nil
    end
    local content = out.content
    if content and content:find(vim.pesc(scfg.no_edit_token)) then
        return 'no_edit', nil
    end
    local patch = out.patch or (content and content:find '%*%*%* Begin Patch' and content)
    if not patch then
        return 'other', nil
    end
    local applied, new_lines = apply_patch.apply(cur, patch, { cursor_row = cursor_row })
    if not applied then
        return 'noapply', patch
    end
    local idx = changed_idx(cur, new_lines)
    if vim.deep_equal(new_lines, target_doc) then
        return 'T2-hit', patch
    end
    if idx and idx >= t1 and idx <= t1 + 3 then
        return 'T1', patch
    end
    if idx and idx >= t2 and idx <= t2 + 3 then
        return 'T2-other', patch
    end
    return 'other', patch
end

local function ask(messages, ctx)
    local done, result = false, nil
    chat.request(messages, tools.specs(), function(r)
        result = r
        done = true
    end, ctx)
    vim.wait(60000, function()
        return done
    end, 50)
    return result
end

local function predict_openrouter(bufnr)
    root.duet.provider = 'openai_compatible'
    local system = scfg.system .. '\n\n' .. scfg.capability_reminder .. '\n\n' .. scfg.auto_instruction
    local messages = {
        { role = 'system', content = system },
        { role = 'user', content = session.build_user_turn(bufnr, { ctx_lines = CTX }) },
    }
    local r = ask(messages, { bufnr = bufnr })
    if not r or r.error then
        return { error = r and r.error or 'timeout' }
    end
    local m = r.message or {}
    local call = m.tool_calls and m.tool_calls[1]
    if call and call['function'] and call['function'].name == 'apply_patch' then
        local ok, args = pcall(vim.json.decode, call['function'].arguments or '{}')
        return { patch = ok and args.input or nil }
    end
    return { content = (type(m.content) == 'string') and m.content or nil }
end

local function predict_mercury(bufnr)
    root.duet.provider = 'inception_edit'
    local r = ask({}, { bufnr = bufnr })
    if not r or r.error then
        return { error = r and r.error or 'timeout' }
    end
    local m = r.message or {}
    return { content = (type(m.content) == 'string') and m.content or nil }
end

local providers = {
    O = { label = 'openrouter chat apply_patch', fn = predict_openrouter },
    M = { label = 'inception mercury-edit native', fn = predict_mercury },
}

local edits = build_edits()
STEPS = math.min(STEPS, #edits - 1)

local ts = os.date '%Y-%m-%d_%H-%M-%S'
local outdir = dev .. '/experiments/duet-nes/logs/mercury_edit_' .. ts
vim.fn.mkdir(outdir, 'p')
local jsonl = assert(io.open(outdir .. '/results.jsonl', 'w'))
local function log(o)
    o.t_ms = vim.uv.now()
    jsonl:write(vim.json.encode(o) .. '\n')
    jsonl:flush()
end

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, dev .. '/tmp/' .. PATH)
vim.bo[bufnr].filetype = 'typst'
vim.bo[bufnr].buftype = ''
vim.api.nvim_set_current_buf(bufnr)

local tally = {}
for _, v in ipairs(VARIANTS) do
    tally[v] = {}
end

print('LOG DIR: ' .. outdir)
print(
    ('mercury_eval effort=%s steps=%d repeats=%d variants=%s'):format(
        EFFORT,
        STEPS,
        REPEATS,
        table.concat(VARIANTS, ',')
    )
)
print '------------------------------------------------------------------------'

for _, v in ipairs(VARIANTS) do
    local provider = providers[v]
    if not provider then
        error('unknown variant: ' .. tostring(v))
    end
    for rep = 1, REPEATS do
        local work = deepcopy_rows(COPY)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
        session.clear(bufnr)
        session.rebase(bufnr)

        local e1 = edits[1]
        apply_edit(work, e1)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
        set_cursor_for_edit(work, e1)
        session.capture(bufnr, CTX)

        for i = 2, STEPS + 1 do
            local target_e = edits[i]
            local target_rows = deepcopy_rows(work)
            apply_edit(target_rows, target_e)
            local _, t1, t2 = build_doc(work)
            local target_doc = build_doc(target_rows)
            local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local cursor_row = vim.api.nvim_win_get_cursor(0)[1]

            local out = provider.fn(bufnr)
            local class, patch = classify(cur, out, t1, t2, target_doc, cursor_row)
            tally[v][class] = (tally[v][class] or 0) + 1
            log {
                variant = v,
                label = provider.label,
                rep = rep,
                round = i,
                target = target_e.desc,
                class = class,
                patch = patch,
                error = out.error,
            }

            io.write(('%s r%d rd%-2d %-8s  '):format(v, rep, i, class))
            io.flush()

            apply_edit(work, target_e)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
            set_cursor_for_edit(work, target_e)
            session.capture(bufnr, CTX)
        end
        io.write '\n'
    end
end

jsonl:close()
print '------------------------------------------------------------------------'
for _, v in ipairs(VARIANTS) do
    local total, hit, parts = 0, tally[v]['T2-hit'] or 0, {}
    for _, c in ipairs { 'T2-hit', 'T2-other', 'T1', 'noapply', 'no_edit', 'other', 'error' } do
        if tally[v][c] then
            total = total + tally[v][c]
            parts[#parts + 1] = ('%s=%d'):format(c, tally[v][c])
        end
    end
    print(
        ('%s  %-30s hit %d/%d (%.0f%%) | %s'):format(
            v,
            providers[v].label,
            hit,
            total,
            100 * hit / math.max(1, total),
            table.concat(parts, '  ')
        )
    )
end
print('done. outdir=' .. outdir)
local mark = assert(io.open(dev .. '/tmp/mercury_eval_last_outdir', 'w'))
mark:write(outdir)
mark:close()
