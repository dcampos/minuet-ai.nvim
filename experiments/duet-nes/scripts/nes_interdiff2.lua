-- Bench v2: a TRUE interleaved transcript with realistic dispositions.
--
-- Fixes from v1 (per review):
--   * the user ACCEPTS an exact-hit suggestion (disposition is accepted vs
--     ignored, a real mixed signal) instead of ignoring everything;
--   * no hand-written "you haven't figured it out" babysitting — the model sees
--     only facts (its own prior turns + accept/ignore + the actual edit);
--   * memory is an append-only multi-turn LOG (edit -> model turn -> outcome ->
--     edit -> ...), not an end-appended summary block.
--
-- Carry-forward variants (all medium effort):
--   A baseline   stateless: full file + recent diffs each turn, no memory
--   R reasoning  transcript; assistant turns carry the model's own `reasoning`
--                field natively (tests provider/model CoT reuse)
--   N notes      transcript; each turn we also ask the model for a 1-2 sentence
--                note to its future self, carried forward (separate output)
--
-- Run: OPENROUTER_API_KEY=... MINUET_EFFORT=medium INTERDIFF2_STEPS=8 INTERDIFF2_REPEATS=3 \
--   nvim --headless -u NONE -i NONE -n -c "luafile experiments/duet-nes/scripts/nes_interdiff2.lua" -c "qa!"

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
local STEPS = tonumber(os.getenv 'INTERDIFF2_STEPS') or 8
local REPEATS = tonumber(os.getenv 'INTERDIFF2_REPEATS') or 3
local VARIANTS = {}
for v in (os.getenv 'INTERDIFF2_VARIANTS' or 'A,R,N'):gmatch '%u' do
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

-- diff of applying edit `e` to `work_before`; returns the apply_patch block.
local function edit_diff(work_before, e)
    local before = build_doc(work_before)
    local after_rows = deepcopy_rows(work_before)
    apply_edit(after_rows, e)
    local after = build_doc(after_rows)
    return session.render_edit(before, after, PATH, CTX) or '(no diff)'
end

-- cursor note for sitting on edit `e`'s cell in `work_after`.
local function cursor_note(work_after, e)
    local lines, _, t2 = build_doc(work_after)
    local row_line = t2 + (e.row - 1)
    local _, ends = render_row(work_after[e.row][1], work_after[e.row][2])
    local col = math.min(ends[e.col], #lines[row_line] - 1)
    return ('Editor cursor: line %d, column %d (1-based). That line reads: `%s`'):format(row_line, col + 1, lines[row_line]), row_line, col
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

-- predict against a fresh local copy of `messages` (read-servicing won't pollute
-- the persistent transcript).
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

-- variant N: a short note the model keeps for itself.
local function ask_note(diffs_text, proposed)
    local r = ask {
        { role = 'system', content = "You keep terse notes to your future self while predicting a code user's next edits." },
        {
            role = 'user',
            content = "The user's edits so far (oldest to newest):\n\n"
                .. diffs_text
                .. '\n\nYou just proposed this edit:\n'
                .. (proposed or '(none)')
                .. '\n\nIn 1-2 sentences, note what the user is doing and your best guess for the pattern. Concrete, no preamble.',
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

-- ---- serialization for the PDF (truncate reasoning so it stays readable) ----
local function serialize(messages)
    local parts = {}
    for _, m in ipairs(messages) do
        local seg = '###### ' .. string.upper(m.role)
        if type(m.reasoning) == 'string' and m.reasoning ~= '' then
            local r = m.reasoning
            if #r > 700 then
                r = r:sub(1, 480) .. ' …[' .. (#r - 700) .. ' chars]… ' .. r:sub(#r - 200)
            end
            seg = seg .. '\n[reasoning]\n' .. r
        end
        local c = (type(m.content) == 'string') and m.content or (m.content == vim.NIL and '(tool call)' or '')
        seg = seg .. '\n' .. c
        parts[#parts + 1] = seg
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
local labels = { A = 'baseline (stateless)', R = 'transcript + native reasoning', N = 'transcript + self-notes' }

local ts = os.date '%Y-%m-%d_%H-%M-%S'
local outdir = dev .. '/experiments/duet-nes/logs/interdiff2_' .. ts
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
    report[v] = { variant = v, label = labels[v], rounds = {}, grid = {} }
    tally[v] = {}
    grid[v] = {}
end

print('LOG DIR: ' .. outdir)
print(('interdiff2 effort=%s steps=%d repeats=%d variants=%s'):format(EFFORT, STEPS, REPEATS, table.concat(VARIANTS, ',')))
print '------------------------------------------------------------------------'

for _, v in ipairs(VARIANTS) do
    for rep = 1, REPEATS do
        -- fresh walk
        local work = deepcopy_rows(COPY)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
        session.clear(bufnr)
        session.rebase(bufnr)

        -- seed: the user's first edit e_1 (no prediction before it)
        local e1 = edits[1]
        apply_edit(work, e1)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
        do
            local _, rl, cc = cursor_note(work, e1)
            vim.api.nvim_win_set_cursor(0, { rl, cc })
        end
        session.capture(bufnr, CTX)

        -- transcript log for R / N (append-only). Stable prefix = start file.
        local turns = nil
        if v ~= 'A' then
            turns = {
                {
                    role = 'user',
                    content = ('File `%s` at session start:\n\n%s\n\nYou predict the user\'s next single edit each turn.'):format(
                        PATH,
                        table.concat(build_doc(COPY), '\n')
                    ),
                },
            }
        end
        local last_edit = e1 -- the most recent ACTUAL edit (its diff/cursor feed the next request)
        local prev_work = deepcopy_rows(COPY) -- state before last_edit (for diff rendering)
        local last_hit = nil -- disposition of the previous round's suggestion (nil at the seed)

        for i = 2, STEPS + 1 do
            local target_e = edits[i]
            local target_rows = deepcopy_rows(work)
            apply_edit(target_rows, target_e)
            local _, t1, t2 = build_doc(work)
            local target_doc = build_doc(target_rows)
            local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            -- one user turn carrying: prior outcome (fact), the latest actual edit, cursor.
            local cnote = cursor_note(work, last_edit)
            local outcome_prefix = ''
            if last_hit ~= nil then
                outcome_prefix = 'Outcome of your last suggestion: '
                    .. (last_hit and 'the user ACCEPTED it.' or 'the user did NOT use it.')
                    .. '\n\n'
            end
            local req = {
                role = 'user',
                content = outcome_prefix
                    .. ('The user just made this edit:\n%s\n\n%s\nPredict the user\'s next single edit.'):format(
                        edit_diff(prev_work, last_edit),
                        cnote
                    ),
            }

            local messages
            if v == 'A' then
                messages = { { role = 'system', content = base_system }, { role = 'user', content = session.build_user_turn(bufnr, { ctx_lines = CTX }) } }
            else
                messages = { { role = 'system', content = base_system } }
                vim.list_extend(messages, turns)
                table.insert(messages, req)
            end

            local out = predict(messages, bufnr)
            local class, patch = classify(cur, out, t1, t2, target_doc)
            local hit = class == 'T2-hit'
            local disposition = hit and 'accepted' or 'ignored'
            tally[v][class] = (tally[v][class] or 0) + 1
            grid[v][i] = grid[v][i] or { round = i, edit = target_e.desc, classes = {} }
            grid[v][i].classes[rep] = class

            -- variant N: get a note for the transcript
            local note = nil
            if v == 'N' then
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

            -- append this round to the transcript IN ORDER: the request, then the
            -- model's turn (carrying its reasoning [R] or note [N] + the patch).
            if v ~= 'A' then
                table.insert(turns, req)
                local asst = { role = 'assistant', content = (note and (note .. '\n\n') or '') .. (patch or '(no edit proposed)') }
                if v == 'R' then
                    asst.reasoning = table.concat(out.reasonings or {}, '\n')
                end
                table.insert(turns, asst)
            end

            -- ADVANCE: the edit e_i happens (accepted == proposal, or user types it)
            prev_work = deepcopy_rows(work)
            apply_edit(work, target_e)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, (build_doc(work)))
            do
                local _, rl, cc = cursor_note(work, target_e)
                vim.api.nvim_win_set_cursor(0, { rl, cc })
            end
            session.capture(bufnr, CTX)
            last_edit = target_e
            last_hit = hit

            io.write(('%s r%d round%-2d %-8s(%s)  '):format(v, rep, i, class, disposition:sub(1, 3)))
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
    local parts, total, hit, acc = {}, 0, 0, 0
    for _, c in ipairs { 'T2-hit', 'T2-other', 'T1', 'noapply', 'read', 'no_edit', 'other', 'error' } do
        if tally[v][c] then
            parts[#parts + 1] = ('%s=%d'):format(c, tally[v][c])
            total = total + tally[v][c]
        end
    end
    hit = tally[v]['T2-hit'] or 0
    print(('%s %-30s  hit/accepted %d/%d (%.0f%%)  | %s'):format(v, labels[v], hit, total, 100 * hit / math.max(1, total), table.concat(parts, '  ')))
end
print('done. effort=' .. EFFORT .. '  outdir=' .. outdir)
local mark = assert(io.open(dev .. '/tmp/interdiff2_last_outdir', 'w'))
mark:write(outdir)
mark:close()
