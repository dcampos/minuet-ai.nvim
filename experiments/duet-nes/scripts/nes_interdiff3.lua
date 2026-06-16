-- Bench v3: ADDITIVE inter-diff memory (fixes both v2 confounds).
--   * keep the FULL current file every round (memory is added, never replaces it);
--   * inline the model's reasoning as visible CONTENT (the native `reasoning`
--     field is dropped by the provider, so R in v2 was inert).
--
-- Structure each round: system + [interleaved prior turns: short user (edit) +
-- assistant (arm payload + patch)] + FINAL user turn = the full baseline turn
-- (whole file + recent diffs + cursor). Accept-on-hit dispositions, no babysitting.
--
-- Arms:
--   A  baseline           full file, no memory
--   F  facts              prior turns carry only the patch (its own guesses) + accept/ignore
--   FN facts + self-note  prior assistant turns also carry a 1-2 sentence note
--   FR facts + reasoning  prior assistant turns inline the model's own reasoning (tail)
--
-- Run: OPENROUTER_API_KEY=... MINUET_EFFORT=medium INTERDIFF3_STEPS=8 INTERDIFF3_REPEATS=3 \
--   nvim --headless -u NONE -i NONE -n -c "luafile experiments/duet-nes/scripts/nes_interdiff3.lua" -c "qa!"

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
local STEPS = tonumber(os.getenv 'INTERDIFF3_STEPS') or 8
local REPEATS = tonumber(os.getenv 'INTERDIFF3_REPEATS') or 3
local VARIANTS = {}
for v in (os.getenv 'INTERDIFF3_VARIANTS' or 'A,F,FN,FR'):gmatch '[^,]+' do
    VARIANTS[#VARIANTS + 1] = v
end
local PATH = 'main.typ'
local CTX = scfg.history_context_lines

-- ---- scenario --------------------------------------------------------------
local COPY = {
    { 'x_3', { 1, -1, 1, 0, 0, -1, -1 } },
    { 'x_4', { -1, -1, 0, 1, 0, -1, -3 } },
    { 'x_5', { 2, 1, 0, 0, 1, -1, 4 } },
    { 'z', { 0, 0, 0, 0, 0, -1, 0 } },
}
-- Correct phase-1 pivot: x_4 leaves (its b = -3 is the most negative in the b
-- column), x_0 enters its row; pivot on the x_0 column. Result has b = (2,3,7,3),
-- all >= 0 (feasible), which confirms the pivot.
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
                edits[#edits + 1] =
                    { row = ri, col = ci, desc = ('r%dc%d %s:%d->%d'):format(ri, ci, COLNAME[ci], COPY[ri][2][ci], TARGET[ri][2][ci]) }
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
local function edit_diff(work_before, e)
    local before = build_doc(work_before)
    local after_rows = deepcopy_rows(work_before)
    apply_edit(after_rows, e)
    return session.render_edit(before, build_doc(after_rows), PATH, CTX) or '(no diff)'
end

-- ---- model round trips -----------------------------------------------------
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
    local msgs = vim.list_extend({}, messages)
    local reasonings, reads = {}, 0
    while true do
        local result = ask(msgs)
        if not result or result.error then
            return { error = result and result.error or 'timeout', reasonings = reasonings }
        end
        local m = result.message
        if type(m.reasoning) == 'string' and m.reasoning ~= '' then
            reasonings[#reasonings + 1] = m.reasoning
        end
        local call = m.tool_calls and m.tool_calls[1]
        if call and call['function'] then
            local name = call['function'].name
            local ok, args = pcall(vim.json.decode, call['function'].arguments or '{}')
            args = ok and args or {}
            if name == 'read' then
                if reads >= (scfg.max_reads or 2) then
                    return { reads_exhausted = true, reasonings = reasonings }
                end
                table.insert(msgs, assistant_echo(m))
                table.insert(msgs, { role = 'tool', tool_call_id = call.id, content = tools.read_result(bufnr, args) })
                reads = reads + 1
            elseif name == 'apply_patch' then
                return { patch = (type(args) == 'table') and args.input or nil, reasonings = reasonings }
            else
                return { tool = name, reasonings = reasonings }
            end
        else
            return { content = (type(m.content) == 'string') and m.content or nil, reasonings = reasonings }
        end
    end
end
local function ask_note(diffs_text, proposed)
    local r = ask {
        { role = 'system', content = "You keep terse notes to your future self while predicting a code user's next edits." },
        {
            role = 'user',
            content = "The user's edits so far (oldest to newest):\n\n" .. diffs_text .. '\n\nYou just proposed:\n' .. (proposed or '(none)') .. '\n\nIn 1-2 sentences, note what the user is doing and your best guess for the pattern. Concrete, no preamble.',
        },
    }
    if not r or r.error then
        return '(note unavailable)'
    end
    local m = r.message
    return (type(m.content) == 'string' and m.content ~= '' and m.content) or (type(m.reasoning) == 'string' and m.reasoning:sub(1, 300)) or '(empty)'
end

-- ---- classification --------------------------------------------------------
local function changed_idx(cur, new_lines)
    for i = 1, math.max(#cur, #new_lines) do
        if cur[i] ~= new_lines[i] then
            return i
        end
    end
end
local function classify(cur, out, t1, t2, target_doc)
    if out.error then
        return 'error', nil
    end
    if out.reads_exhausted then
        return 'read', nil
    end
    local content = out.content
    if content and content:find '%*%*%* No Edit' then
        return 'no_edit', nil
    end
    local patch = out.patch or (content and content:find '%*%*%* Begin Patch' and content)
    if not patch then
        return 'other', nil
    end
    local applied, new_lines = apply_patch.apply(cur, patch)
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

local function reason_tail(reasonings, n)
    local r = table.concat(reasonings or {}, '\n')
    if #r <= n then
        return r
    end
    return '…' .. r:sub(#r - n)
end
local function serialize(messages)
    local parts = {}
    for _, m in ipairs(messages) do
        local c = (type(m.content) == 'string') and m.content or (m.content == vim.NIL and '(tool call)' or '')
        if #c > 100000 then
            c = c:sub(1, 1500) .. '\n  …[' .. (#c - 100000) .. ' chars]…\n' .. c:sub(#c - 1000)
        end
        parts[#parts + 1] = '###### ' .. string.upper(m.role) .. '\n' .. c
    end
    return table.concat(parts, '\n\n')
end
local function excerpt(reasonings)
    local r = table.concat(reasonings or {}, ' || ')
    if #r <= 1100 then
        return r
    end
    return r:sub(1, 700) .. '\n\n   […' .. (#r - 1100) .. ' chars elided…]\n\n' .. r:sub(#r - 400)
end

-- ---- driver ----------------------------------------------------------------
local edits = build_edits()
STEPS = math.min(STEPS, #edits - 1)
local base_system = scfg.system .. '\n\n' .. scfg.capability_reminder .. '\n\n' .. scfg.auto_instruction
local labels = { A = 'baseline (full file, no memory)', F = 'full file + facts', FN = 'full file + facts + note', FR = 'full file + facts + reasoning' }

local ts = os.date '%Y-%m-%d_%H-%M-%S'
local outdir = dev .. '/experiments/duet-nes/logs/interdiff3_' .. ts
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
vim.api.nvim_set_current_buf(bufnr)

local report, tally, grid = {}, {}, {}
for _, v in ipairs(VARIANTS) do
    report[v] = { variant = v, label = labels[v] or v, rounds = {}, grid = {} }
    tally[v] = {}
    grid[v] = {}
end

print('LOG DIR: ' .. outdir)
print(('interdiff3 effort=%s steps=%d repeats=%d variants=%s'):format(EFFORT, STEPS, REPEATS, table.concat(VARIANTS, ',')))
print '------------------------------------------------------------------------'

for _, v in ipairs(VARIANTS) do
    local mem = v ~= 'A'
    for rep = 1, REPEATS do
        local work = deepcopy_rows(COPY)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
        session.clear(bufnr)
        session.rebase(bufnr)

        -- seed e_1 (user's first edit; no prediction)
        local e1 = edits[1]
        apply_edit(work, e1)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
        do
            local lines, _, t2 = build_doc(work)
            local rl = t2 + (e1.row - 1)
            local _, ends = render_row(work[e1.row][1], work[e1.row][2])
            vim.api.nvim_win_set_cursor(0, { rl, math.min(ends[e1.col], #lines[rl] - 1) })
        end
        session.capture(bufnr, CTX)

        local turns = {} -- interleaved prior [short user, assistant] pairs
        local prev_work = deepcopy_rows(COPY)
        local last_edit = e1
        local last_hit = nil

        for i = 2, STEPS + 1 do
            local target_e = edits[i]
            local target_rows = deepcopy_rows(work)
            apply_edit(target_rows, target_e)
            local _, t1, t2 = build_doc(work)
            local target_doc = build_doc(target_rows)
            local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            -- the FINAL user turn always carries the full baseline view.
            local outcome_prefix = ''
            if last_hit ~= nil then
                outcome_prefix = 'Outcome of your last suggestion: '
                    .. (last_hit and 'the user ACCEPTED it.' or 'the user did NOT use it.')
                    .. '\n\n'
            end
            local final_user = outcome_prefix .. session.build_user_turn(bufnr, { ctx_lines = CTX })

            local messages = { { role = 'system', content = base_system } }
            if mem then
                vim.list_extend(messages, turns)
            end
            table.insert(messages, { role = 'user', content = final_user })

            local out = predict(messages, bufnr)
            local class, patch = classify(cur, out, t1, t2, target_doc)
            local hit = class == 'T2-hit'
            local disposition = hit and 'accepted' or 'ignored'
            tally[v][class] = (tally[v][class] or 0) + 1
            grid[v][i] = grid[v][i] or { round = i, edit = target_e.desc, classes = {} }
            grid[v][i].classes[rep] = class

            local note = nil
            if v == 'FN' then
                note = ask_note(table.concat(session.edits(bufnr), '\n\n'), patch or '(no patch)')
            end

            if rep == 1 then
                report[v].rounds[#report[v].rounds + 1] = {
                    round = i,
                    target = target_e.desc,
                    class = class,
                    disposition = disposition,
                    transcript = serialize(messages),
                    reasoning_excerpt = excerpt(out.reasonings),
                    patch = patch or (out.content or '(no patch)'),
                    note = note,
                }
            end
            log { variant = v, rep = rep, round = i, target = target_e.desc, class = class, disposition = disposition, patch = patch, note = note }

            -- append this round's interleaved memory (short user req + assistant payload)
            if mem then
                table.insert(turns, {
                    role = 'user',
                    content = ('The user made this edit:\n%s\nPredict the next edit.'):format(edit_diff(prev_work, last_edit)),
                })
                local payload = patch or '(no edit proposed)'
                if v == 'FN' and note then
                    payload = 'Note: ' .. note .. '\n\n' .. payload
                elseif v == 'FR' then
                    payload = '[my reasoning]\n' .. reason_tail(out.reasonings, 1000) .. '\n\n' .. payload
                end
                table.insert(turns, { role = 'assistant', content = payload })
            end

            -- ADVANCE
            prev_work = deepcopy_rows(work)
            apply_edit(work, target_e)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
            do
                local lines, _, t2b = build_doc(work)
                local rl = t2b + (target_e.row - 1)
                local _, ends = render_row(work[target_e.row][1], work[target_e.row][2])
                vim.api.nvim_win_set_cursor(0, { rl, math.min(ends[target_e.col], #lines[rl] - 1) })
            end
            session.capture(bufnr, CTX)
            last_edit = target_e
            last_hit = hit

            io.write(('%-2s r%d rd%-2d %-8s(%s)  '):format(v, rep, i, class, disposition:sub(1, 3)))
            io.flush()
        end
        io.write '\n'
    end
end

for _, v in ipairs(VARIANTS) do
    for i = 2, STEPS + 1 do
        report[v].grid[#report[v].grid + 1] = grid[v][i]
    end
    local f = assert(io.open(outdir .. '/report_' .. v .. '.json', 'w'))
    f:write(vim.json.encode(report[v]))
    f:close()
end
jsonl:close()

print '------------------------------------------------------------------------'
for _, v in ipairs(VARIANTS) do
    local parts, total, hit = {}, 0, 0
    for _, c in ipairs { 'T2-hit', 'T2-other', 'T1', 'noapply', 'read', 'no_edit', 'other', 'error' } do
        if tally[v][c] then
            parts[#parts + 1] = ('%s=%d'):format(c, tally[v][c])
            total = total + tally[v][c]
        end
    end
    hit = tally[v]['T2-hit'] or 0
    print(('%-2s %-34s  hit/accepted %d/%d (%.0f%%)  | %s'):format(v, labels[v] or v, hit, total, 100 * hit / math.max(1, total), table.concat(parts, '  ')))
end
print('done. effort=' .. EFFORT .. '  outdir=' .. outdir)
local mark = assert(io.open(dev .. '/tmp/interdiff3_last_outdir', 'w'))
mark:write(outdir)
mark:close()
