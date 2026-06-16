-- Bench: the "duplicated simplex tableau" NES scenario the user hit.
--
-- The user copies the initial tableau to the end of the document, then edits the
-- copy entry-by-entry to perform a pivot (Gaussian elimination). Each edit
-- changes one matrix cell. After each edit we ask the live duet model for the
-- next-edit prediction and classify where its patch lands.
--
-- The crux: until a row of the SECOND tableau has been touched, it is
-- byte-identical to the same row of the FIRST tableau. apply_patch's
-- seek_sequence returns the FIRST match, so a minimal-context hunk for an
-- un-edited row silently rewrites the FIRST tableau. We label every prediction
-- T1 (wrong block) / T2-hit (exact next cell) / T2-fwd / T2-other / read /
-- no_edit / noapply, dump full reasoning to jsonl, and tally at the end.
--
-- Run: OPENROUTER_API_KEY=... MINUET_EFFORT=medium \
--        nvim --headless -u NONE -i NONE -n -c "luafile experiments/duet-nes/scripts/nes_tableau.lua" -c "qa!"

local dev = vim.fn.expand '~/code/lua/minuet-ai.nvim'
vim.opt.runtimepath:prepend(dev)
package.path = table.concat({ dev .. '/lua/?.lua', dev .. '/lua/?/init.lua', package.path }, ';')
require('minuet').setup { duet = { provider = 'openai_compatible' } }

local session = require 'minuet.duet.session'
local chat = require 'minuet.duet.chat'
local tools = require 'minuet.duet.tools'
local apply_patch = require 'minuet.duet.apply_patch'
local root = require('minuet').config

local EFFORT = os.getenv 'MINUET_EFFORT' or 'medium'
root.duet.provider_options.openai_compatible.optional.reasoning.effort = EFFORT
local MAX = tonumber(os.getenv 'TABLEAU_MAX') or 21
local PATH = 'main.typ'

-- Matrix cells are [label, {x_1, x_2, x_3, x_4, x_5, x_0, b}].
-- COPY == the freshly copied initial tableau; TARGET == after pivoting x_3 out /
-- x_0 in (divide the x_3 row by its x_0 entry -1, then eliminate x_0 elsewhere).
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

-- Deterministic row render; also returns the 1-based byte length up to and
-- including each cell (col 0 = label) so we can place the cursor after a cell.
local function render_row(label, nums)
    local s = '  ' .. string.format('%-3s', label)
    local ends = { [0] = #s }
    for ci = 1, 7 do
        s = s .. ', ' .. string.format('%3d', nums[ci])
        ends[ci] = #s
    end
    return s .. ';', ends
end

-- Build the whole document for a given state of the second tableau's rows.
-- Returns lines plus the 1-based line index of each tableau's first data row.
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
    add '1. Resolver cada uno de los problemas geométricamente.'
    add '2. Usar la _primera fase_, del método de las dos fases, para determinar la'
    add '   solución inicial para cada problema.'
    add '3. En el inciso 1 usar la segunda fase en tablas para obtener la solución óptima.'
    add '4. En el inciso 2 graficar cada iteración de la primera fase.'
    add '5. En el inciso 3 usar el _método simplex revisado_ para obtener la solución óptima.'
    add('', '')
    add '= Problema 1'
    add '$'
    add '"max" z = 3x_1 + x_2 \\'
    add '"sujeto a" \\'
    add 'cases('
    add '  x_1 - x_2  &<= -1,'
    add '  -x_1 - x_2 &<= -3,'
    add '  2x_1 + x_2 &<= 4,'
    add '  x_1 \\, x_2 &>= 0'
    add ')'
    add '$'
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

-- The ordered list of single-cell edits (row-major) that turns COPY into TARGET.
local function build_edits()
    local edits = {}
    for ri = 1, 4 do
        if COPY[ri][1] ~= TARGET[ri][1] then
            edits[#edits + 1] = { row = ri, col = 0, desc = COPY[ri][1] .. '->' .. TARGET[ri][1] }
        end
        for ci = 1, 7 do
            if COPY[ri][2][ci] ~= TARGET[ri][2][ci] then
                edits[#edits + 1] = {
                    row = ri,
                    col = ci,
                    desc = ('%s:%d->%d'):format(COLNAME[ci], COPY[ri][2][ci], TARGET[ri][2][ci]),
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

-- Trimmed cell strings of a rendered matrix row: out[1]=label, out[2..8]=nums.
local function parse_cells(line)
    local body = vim.trim((line:gsub(';%s*$', '')))
    local out = {}
    for _, p in ipairs(vim.split(body, ',', { plain = true })) do
        out[#out + 1] = vim.trim(p)
    end
    return out
end

-- How many of a row's 8 cells already equal TARGET (used to detect forward vs
-- revert progress on a second-tableau row).
local function target_match_count(row_idx, line)
    local cells = parse_cells(line)
    local want = { TARGET[row_idx][1] }
    for ci = 1, 7 do
        want[#want + 1] = tostring(TARGET[row_idx][2][ci])
    end
    local n = 0
    for i = 1, 8 do
        if cells[i] == want[i] then
            n = n + 1
        end
    end
    return n
end

-- ---- logging ---------------------------------------------------------------
local ts = os.date '%Y-%m-%d_%H-%M-%S'
local logpath = dev .. '/experiments/duet-nes/logs/nes_tableau_' .. ts .. '.jsonl'
local logf = assert(io.open(logpath, 'w'))
local function log(obj)
    obj.t_ms = vim.uv.now()
    logf:write(vim.json.encode(obj) .. '\n')
    logf:flush()
end

-- ---- model round trip (services read() like the real predict loop) ---------
local scfg = root.duet.session
local function build_messages(bufnr)
    -- Mirror init.build_messages for a MANUAL trigger (the user presses the key).
    local system = scfg.system .. '\n\n' .. scfg.capability_reminder .. '\n\n' .. scfg.manual_instruction
    local user = session.build_user_turn(bufnr, { ctx_lines = scfg.history_context_lines })
    return { { role = 'system', content = system }, { role = 'user', content = user } }
end

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
    return {
        role = 'assistant',
        tool_calls = msg.tool_calls,
        content = (type(msg.content) == 'string') and msg.content or vim.NIL,
    }
end

-- Returns { patch? | content? | reads_exhausted? | error? , reasonings = {...} }.
-- The model usually wants to `read` the exact buffer text first; service it (up
-- to max_reads) so we see the patch it ultimately emits, as the real loop does.
local function predict(bufnr)
    local messages = build_messages(bufnr)
    local reasonings, reads = {}, 0
    while true do
        local result = ask(messages)
        if not result or result.error then
            return { error = result and result.error or 'timeout', reasonings = reasonings }, messages
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
                    return { reads_exhausted = true, last_read = args, reasonings = reasonings }, messages
                end
                table.insert(messages, assistant_echo(msg))
                table.insert(messages, { role = 'tool', tool_call_id = call.id, content = tools.read_result(bufnr, args) })
                reads = reads + 1
            elseif name == 'apply_patch' then
                return { patch = (type(args) == 'table') and args.input or nil, reasonings = reasonings }, messages
            else
                return { tool = name, args = args, reasonings = reasonings }, messages
            end
        else
            local content = (type(msg.content) == 'string') and msg.content or nil
            return { content = content, reasonings = reasonings }, messages
        end
    end
end

-- ---- driver ----------------------------------------------------------------
local edits = build_edits()
local n_steps = math.min(MAX, #edits)

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, dev .. '/tmp/' .. PATH)
vim.bo[bufnr].filetype = 'typst'
vim.api.nvim_set_current_buf(bufnr)

local work = deepcopy_rows(COPY)
local baseline = build_doc(work)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, baseline)
session.clear(bufnr)
session.rebase(bufnr)

print('LOG: ' .. logpath)
print(('tableau bench effort=%s steps=%d/%d'):format(EFFORT, n_steps, #edits))
print '(class: T2-hit=exact next cell | T2-fwd=right block, progress | T2-other=right block, no progress)'
print '(       T1=WRONG block (duplicate-row ambiguity) | noapply | read | no_edit | error)'
print '----------------------------------------------------------------------------------------'

local tally = {}
for step = 1, n_steps do
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
    local out, messages = predict(bufnr)

    -- ground-truth next snapshot (for strict-hit comparison)
    local next_doc
    if step < #edits then
        local w2 = deepcopy_rows(work)
        apply_edit(w2, edits[step + 1])
        next_doc = build_doc(w2)
    end

    local content = out.content
    local class, detail = 'error', tostring(out.error)
    local changed_rows = {}
    if not out.error then
        if out.reads_exhausted then
            class, detail = 'read', vim.inspect(out.last_read):gsub('%s+', ' ')
        elseif content and content:find '%*%*%* No Edit' then
            class, detail = 'no_edit', ''
        elseif out.patch or (content and content:find '%*%*%* Begin Patch') then
            local patch = out.patch or content
            local applied, new_lines = apply_patch.apply(cur, patch)
            if not applied then
                class, detail = 'noapply', ''
            else
                for i = 1, math.max(#cur, #new_lines) do
                    if cur[i] ~= new_lines[i] then
                        changed_rows[#changed_rows + 1] = i
                    end
                end
                local first = changed_rows[1]
                local in_t1 = first and first >= t1 and first <= t1 + 3
                local in_t2 = first and first >= t2 and first <= t2 + 3
                if next_doc and vim.deep_equal(new_lines, next_doc) then
                    class, detail = 'T2-hit', 'L' .. tostring(first)
                elseif in_t1 then
                    class = 'T1'
                    detail = ('L%d  %q->%q'):format(first, cur[first], new_lines[first])
                elseif in_t2 then
                    local before = target_match_count(e.row, cur[first])
                    local after = target_match_count(first - t2 + 1, new_lines[first])
                    class = (after > before) and 'T2-fwd' or 'T2-other'
                    detail = ('L%d  %q->%q'):format(first, cur[first], new_lines[first])
                else
                    class = 'other'
                    detail = ('L%s changed=%s'):format(tostring(first), vim.inspect(changed_rows):gsub('%s+', ' '))
                end
            end
        else
            class, detail = 'other', 'no tool; content=' .. tostring(content)
        end
    end

    tally[class] = (tally[class] or 0) + 1
    local reason = table.concat(out.reasonings or {}, ' || '):gsub('%s+', ' ')
    log {
        step = step,
        edit = e,
        cursor = { row_line, col },
        class = class,
        detail = detail,
        changed_rows = changed_rows,
        reasonings = out.reasonings,
        content = content,
        patch = out.patch,
        user = messages[2].content,
    }
    print(('step %2d  edit %-3d r%dc%d %-12s @L%-2d | %-8s %s'):format(
        step, step, e.row, e.col, e.desc, row_line, class, detail))
    if reason ~= '' then
        print('         reason: ' .. reason:sub(1, 160))
    end
end

print '----------------------------------------------------------------------------------------'
local order = { 'T2-hit', 'T2-fwd', 'T2-other', 'T1', 'noapply', 'read', 'no_edit', 'other', 'error' }
local parts = {}
for _, c in ipairs(order) do
    if tally[c] then
        parts[#parts + 1] = ('%s=%d'):format(c, tally[c])
    end
end
print('tally: ' .. table.concat(parts, '  '))
print('done. effort=' .. EFFORT .. '  full request/response/reasoning in ' .. logpath)
logf:close()
