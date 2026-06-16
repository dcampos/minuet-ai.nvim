-- Bench: does INTER-DIFF MEMORY help? Today each NES prediction is stateless —
-- the model never sees its own prior guess, prior reasoning, or the user's
-- disposition (the user ignored it). We replay the tableau pivot edit-by-edit
-- and, exactly like the real session, the simulated user IGNORES every
-- suggestion and keeps doing the correct pivot. We compare three ways to carry
-- state forward, all appended at the very END of the user turn:
--
--   A baseline         no memory (control)
--   B attempts+ignored "you predicted X,Y,Z; user accepted NONE; reconsider"
--   C intent-summary   a short model-written hypothesis, carried + revised
--
-- Per (variant, step) we record what the model GETS (trailer) and RESPONDS
-- (reasoning excerpt + patch + class) to results.jsonl and per-variant JSON for
-- the PDF report. Run:
--   OPENROUTER_API_KEY=... MINUET_EFFORT=medium INTERDIFF_STEPS=6 \
--     nvim --headless -u NONE -i NONE -n -c "luafile experiments/duet-nes/scripts/nes_interdiff.lua" -c "qa!"

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

local EFFORT = os.getenv 'MINUET_EFFORT' or 'medium'
root.duet.provider_options.openai_compatible.optional.reasoning.effort = EFFORT
local STEPS = tonumber(os.getenv 'INTERDIFF_STEPS') or 6
local VARIANTS = {}
for v in (os.getenv 'INTERDIFF_VARIANTS' or 'A,B,C'):gmatch '%u' do
    VARIANTS[#VARIANTS + 1] = v
end
local PATH = 'main.typ'

-- ---- scenario (same pivot as nes_tableau) ----------------------------------
local COPY = {
    { 'x_3', { 1, -1, 1, 0, 0, -1, -1 } },
    { 'x_4', { -1, -1, 0, 1, 0, -1, -3 } },
    { 'x_5', { 2, 1, 0, 0, 1, -1, 4 } },
    { 'z', { 0, 0, 0, 0, 0, -1, 0 } },
}
local TARGET = {
    { 'x_0', { -1, 1, -1, 0, 0, 1, 1 } },
    { 'x_4', { -2, 0, -1, 1, 0, 0, -2 } },
    { 'x_5', { 1, 2, -1, 0, 1, 0, 5 } },
    { 'z', { -1, 1, -1, 0, 0, 0, 1 } },
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
    add 'En los siguientes problemas de optimización lineal:'
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
    add 'El siguiente paso es convertir $x_0$ en una variable no básica. Para esto'
    add 'tomamos sacamos $x_3$ de la base ya que es la más negativa.'
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

-- ---- model round trip (services read like the real loop) -------------------
local function ask(messages)
    local done, result = false, nil
    chat.request(messages, tools.specs(), function(r)
        result = r
        done = true
    end)
    vim.wait(60000, function()
        return done
    end, 50)
    return result
end

local function assistant_echo(msg)
    return { role = 'assistant', tool_calls = msg.tool_calls, content = (type(msg.content) == 'string') and msg.content or vim.NIL }
end

local function predict(messages, bufnr)
    local reasonings, reads = {}, 0
    while true do
        local result = ask(messages)
        if not result or result.error then
            return { error = result and result.error or 'timeout', reasonings = reasonings }
        end
        local msg = result.message
        if type(msg.reasoning) == 'string' and msg.reasoning ~= '' then
            reasonings[#reasonings + 1] = msg.reasoning
        end
        local call = msg.tool_calls and msg.tool_calls[1]
        if call and call['function'] then
            local name = call['function'].name
            local ok, args = pcall(vim.json.decode, call['function'].arguments or '{}')
            args = ok and args or {}
            if name == 'read' then
                if reads >= (scfg.max_reads or 2) then
                    return { reads_exhausted = true, reasonings = reasonings }
                end
                table.insert(messages, assistant_echo(msg))
                table.insert(messages, { role = 'tool', tool_call_id = call.id, content = tools.read_result(bufnr, args) })
                reads = reads + 1
            elseif name == 'apply_patch' then
                return { patch = (type(args) == 'table') and args.input or nil, reasonings = reasonings }
            else
                return { tool = name, reasonings = reasonings }
            end
        else
            return { content = (type(msg.content) == 'string') and msg.content or nil, reasonings = reasonings }
        end
    end
end

-- One-shot intent summary (variant C): cheap, recent edits only, no file.
local function summarize_intent(edits_text)
    local result = ask {
        { role = 'system', content = "You infer a code editor user's intent from their recent edits. Reply in 1-2 concrete sentences." },
        {
            role = 'user',
            content = 'Recent edits (oldest to newest), apply_patch dialect:\n\n'
                .. edits_text
                .. '\n\nName the transformation the user is performing and the single next edit you expect '
                .. '(the operation, and if you can the next cell and value).',
        },
    }
    if not result or result.error then
        return '(summary unavailable)'
    end
    local m = result.message
    return (type(m.content) == 'string' and m.content ~= '' and m.content)
        or (type(m.reasoning) == 'string' and m.reasoning:sub(1, 400))
        or '(empty summary)'
end

-- ---- classification --------------------------------------------------------
local function changed_idx(cur, new_lines)
    for i = 1, math.max(#cur, #new_lines) do
        if cur[i] ~= new_lines[i] then
            return i
        end
    end
end

local function classify(cur, out, t1, t2, next_doc)
    if out.error then
        return 'error', nil, nil
    end
    if out.reads_exhausted then
        return 'read', nil, nil
    end
    local content = out.content
    if content and content:find '%*%*%* No Edit' then
        return 'no_edit', nil, nil
    end
    local patch = out.patch or (content and content:find '%*%*%* Begin Patch' and content)
    if not patch then
        return 'other', nil, nil
    end
    local applied, new_lines = apply_patch.apply(cur, patch)
    if not applied then
        return 'noapply', nil, patch
    end
    local idx = changed_idx(cur, new_lines)
    if next_doc and vim.deep_equal(new_lines, next_doc) then
        return 'T2-hit', idx, patch
    end
    if idx and idx >= t1 and idx <= t1 + 3 then
        return 'T1', idx, patch
    end
    if idx and idx >= t2 and idx <= t2 + 3 then
        return 'T2-other', idx, patch
    end
    return 'other', idx, patch
end

-- ---- trailers (the inter-diff memory, appended at the very end) -------------
local function trailer_B(mem)
    if #mem.proposals == 0 then
        return nil
    end
    local lines = { '--- Your earlier predictions this session (the user accepted NONE of them) ---' }
    for _, p in ipairs(mem.proposals) do
        lines[#lines + 1] = ('%d. you predicted: %s   [IGNORED by the user]'):format(p.step, p.summary)
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'The user ignored every suggestion above, so you have NOT yet identified what they '
        .. 'are doing. Treat ALL their recent edits as ONE coherent operation, work that operation out '
        .. 'explicitly, and predict the next edit it implies. Do not repeat a prediction already ignored.'
    return table.concat(lines, '\n')
end

local function trailer_C(mem)
    if not mem.summary then
        return nil
    end
    return '--- Running hypothesis of the user intent (your own earlier summary) ---\n'
        .. mem.summary
        .. '\n\nRevise this if the latest edit contradicts it, then predict the next edit.'
end

-- ---- driver ----------------------------------------------------------------
local edits = build_edits()
STEPS = math.min(STEPS, #edits - 1) -- need an edit+1 target for each step
local REPEATS = tonumber(os.getenv 'INTERDIFF_REPEATS') or 3

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, dev .. '/tmp/' .. PATH)
vim.bo[bufnr].filetype = 'typst'
vim.api.nvim_set_current_buf(bufnr)

local base_system = scfg.system .. '\n\n' .. scfg.capability_reminder .. '\n\n' .. scfg.auto_instruction
local labels = { A = 'baseline (no memory)', B = 'attempts log + disposition', C = 'running intent summary' }

local ts = os.date '%Y-%m-%d_%H-%M-%S'
local outdir = dev .. '/experiments/duet-nes/logs/interdiff_' .. ts
vim.fn.mkdir(outdir, 'p')
local jsonl = assert(io.open(outdir .. '/results.jsonl', 'w'))
local function log(o)
    o.t_ms = vim.uv.now()
    jsonl:write(vim.json.encode(o) .. '\n')
    jsonl:flush()
end

local function excerpt(reasonings)
    local r = table.concat(reasonings or {}, ' || ')
    if #r <= 1200 then
        return r
    end
    return r:sub(1, 760) .. '\n\n   […' .. (#r - 1200) .. ' chars elided…]\n\n' .. r:sub(#r - 440)
end

local report, tally, grid = {}, {}, {}
for _, v in ipairs(VARIANTS) do
    report[v] = { variant = v, label = labels[v], steps = {}, grid = {} } -- steps = repeat 1 detail
    tally[v] = {}
    grid[v] = {} -- step -> { step, edit, classes = { per repeat } }
end
local summary_cache = {} -- step -> intent summary (deterministic edit history across repeats)

print('LOG DIR: ' .. outdir)
print(('interdiff bench effort=%s steps=%d repeats=%d variants=%s'):format(EFFORT, STEPS, REPEATS, table.concat(VARIANTS, ',')))
print(('~%d prediction calls + %d summaries'):format(STEPS * REPEATS * #VARIANTS, vim.tbl_contains(VARIANTS, 'C') and STEPS or 0))
print '------------------------------------------------------------------------'

for rep = 1, REPEATS do
    local mem = { A = {}, B = { proposals = {} }, C = { summary = nil } }
    local work = deepcopy_rows(COPY)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
    session.clear(bufnr)
    session.rebase(bufnr)

    for step = 1, STEPS do
        local e = edits[step]
        apply_edit(work, e)
        local lines, t1, t2 = build_doc(work)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        local row_line = t2 + (e.row - 1)
        local _, ends = render_row(work[e.row][1], work[e.row][2])
        local col = math.min(ends[e.col], math.max(0, #lines[row_line] - 1))
        vim.api.nvim_win_set_cursor(0, { row_line, col })
        session.capture(bufnr, scfg.history_context_lines)

        local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local base_user = session.build_user_turn(bufnr, { ctx_lines = scfg.history_context_lines })
        if rep == 1 and step == 3 then
            report._base_example = base_user -- one representative base turn for the PDF
        end

        local w2 = deepcopy_rows(work)
        apply_edit(w2, edits[step + 1])
        local next_doc = build_doc(w2)

        -- variant C summary, cached across repeats (the edit history is deterministic).
        if vim.tbl_contains(VARIANTS, 'C') then
            if not summary_cache[step] then
                summary_cache[step] = summarize_intent(table.concat(session.edits(bufnr), '\n\n'))
            end
            mem.C.summary = summary_cache[step]
        end

        for _, v in ipairs(VARIANTS) do
            local trailer = (v == 'B' and trailer_B(mem.B)) or (v == 'C' and trailer_C(mem.C)) or nil
            local user = trailer and (base_user .. '\n\n' .. trailer) or base_user
            local out = predict({ { role = 'system', content = base_system }, { role = 'user', content = user } }, bufnr)
            local class, idx, patch = classify(cur, out, t1, t2, next_doc)
            tally[v][class] = (tally[v][class] or 0) + 1
            grid[v][step] = grid[v][step] or { step = step, edit = e.desc, classes = {} }
            grid[v][step].classes[rep] = class

            -- accumulate variant B's memory of its own (ignored) proposals
            if v == 'B' then
                local summ
                if patch and idx then
                    local applied, nl = apply_patch.apply(cur, patch)
                    summ = applied and ('line %d: `%s` -> `%s`'):format(idx, vim.trim(cur[idx]), vim.trim(nl[idx])) or '(invalid patch)'
                elseif class == 'no_edit' then
                    summ = '`*** No Edit`'
                elseif class == 'read' then
                    summ = '(only called read)'
                else
                    summ = '(' .. class .. ')'
                end
                mem.B.proposals[#mem.B.proposals + 1] = { step = step, summary = summ, class = class }
            end

            if rep == 1 then
                report[v].steps[#report[v].steps + 1] = {
                    step = step,
                    edit = e.desc,
                    class = class,
                    trailer = trailer or '(none — baseline)',
                    reasoning_excerpt = excerpt(out.reasonings),
                    patch = patch or (out.content or '(no patch)'),
                    summary = (v == 'C') and mem.C.summary or nil,
                }
            end
            log {
                rep = rep,
                variant = v,
                step = step,
                edit = e.desc,
                class = class,
                trailer = trailer,
                patch = patch,
                reasonings = out.reasonings,
                summary = (v == 'C') and mem.C.summary or nil,
            }
            io.write(('r%d s%-2d %s:%-8s  '):format(rep, step, v, class))
            io.flush()
        end
        io.write '\n'
    end
end

-- flatten the per-step grid (sorted) into each report
for _, v in ipairs(VARIANTS) do
    for step = 1, STEPS do
        report[v].grid[step] = grid[v][step]
    end
    report[v].base_example = report._base_example
    local f = assert(io.open(outdir .. '/report_' .. v .. '.json', 'w'))
    f:write(vim.json.encode(report[v]))
    f:close()
end
jsonl:close()

print '------------------------------------------------------------------------'
for _, v in ipairs(VARIANTS) do
    local parts, total = {}, 0
    for _, c in ipairs { 'T2-hit', 'T2-other', 'T1', 'noapply', 'read', 'no_edit', 'other', 'error' } do
        if tally[v][c] then
            parts[#parts + 1] = ('%s=%d'):format(c, tally[v][c])
            total = total + tally[v][c]
        end
    end
    local hit = tally[v]['T2-hit'] or 0
    print(('%s %-26s  hit %d/%d (%.0f%%)  | %s'):format(v, labels[v], hit, total, 100 * hit / math.max(1, total), table.concat(parts, '  ')))
end
print('done. effort=' .. EFFORT .. '  outdir=' .. outdir)
local mark = assert(io.open(dev .. '/tmp/interdiff_last_outdir', 'w'))
mark:write(outdir)
mark:close()
