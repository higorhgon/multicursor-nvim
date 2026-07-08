local api     = vim.api
local state   = require('multicursor.state')
local marks   = require('multicursor.marks')
local regions = require('multicursor.regions')
local S       = state.S
local NS      = state.NS
local KEY_BS  = state.KEY_BS
local KEY_DEL = state.KEY_DEL

local M = {}

-- ── Motion constants ──────────────────────────────────────────────────────────

M.MOTION_KEYS = {
  w=true, b=true, e=true, W=true, B=true, E=true,
  h=true, l=true, j=true, k=true,
  ['0']=true, ['$']=true, ['^']=true, ['_']=true,
}

M.PENDING_MOTIONS = { f=true, t=true, F=true, T=true }
M.REVERSE_FT      = { f='F', F='f', t='T', T='t' }

M.OP_MOTIONS = {
  w=true, W=true, b=true, B=true, e=true, E=true,
  ['$']=true, ['0']=true, ['^']=true, ['_']=true,
  h=true, l=true, j=true, k=true,
}

-- ── Text primitives ───────────────────────────────────────────────────────────

function M.do_insert(buf, row, col, ch)
  api.nvim_buf_set_text(buf, row, col, row, col, { ch })
end

function M.do_backspace(buf, row, col)
  if col > 0 then
    api.nvim_buf_set_text(buf, row, col - 1, row, col, { '' })
  elseif row > 0 then
    local prev_len = #marks.line_at(buf, row - 1)
    api.nvim_buf_set_text(buf, row - 1, prev_len, row, 0, { '' })
  end
end

function M.do_delete_fwd(buf, row, col)
  local ln = marks.line_at(buf, row)
  if col < #ln then
    api.nvim_buf_set_text(buf, row, col, row, col + 1, { '' })
  elseif row < api.nvim_buf_line_count(buf) - 1 then
    api.nvim_buf_set_text(buf, row, #ln, row + 1, 0, { '' })
  end
end

function M.do_enter(buf, row, col)
  api.nvim_buf_set_text(buf, row, col, row, col, { '', '' })
end

function M.do_move_col(c, delta)
  local row, col = marks.mark_pos(c)
  if not row then return end
  local ln = marks.line_at(c.buf, row)
  c.word_len = 1
  -- Clamp to #ln (one past the last char) so `a` on the last char works.
  marks.move_mark(c, row, math.max(0, math.min(col + delta, #ln)))
end

function M.do_move_eol(c)
  local row = marks.mark_pos(c)
  if not row then return end
  c.word_len = 1
  marks.move_mark(c, row, #marks.line_at(c.buf, row))
end

function M.do_move_bol(c, skip_blank)
  local row = marks.mark_pos(c)
  if not row then return end
  local ln  = marks.line_at(c.buf, row)
  local col = skip_blank and ((ln:match('^%s*()') or 1) - 1) or 0
  c.word_len = 1
  marks.move_mark(c, row, col)
end

-- ── Insert-mode key application ───────────────────────────────────────────────

local function is_printable(k)
  if #k == 1 then
    local b = k:byte()
    return b == 9 or (b >= 32 and b ~= 127)
  end
  return k:byte(1) >= 0xC0
end

function M.apply_to_cursors(k)
  if S.in_apply then return end
  S.in_apply = true
  for _, pos in ipairs(regions.sorted_positions()) do
    pcall(vim.cmd, 'undojoin')
    if k == '\x08' or k == '\x7f' or k == KEY_BS then
      M.do_backspace(pos.buf, pos.row, pos.col)
    elseif k == KEY_DEL then
      M.do_delete_fwd(pos.buf, pos.row, pos.col)
    elseif k == '\r' or k == '\n' then
      M.do_enter(pos.buf, pos.row, pos.col)
    elseif is_printable(k) then
      M.do_insert(pos.buf, pos.row, pos.col, k)
    end
  end
  S.in_apply = false
  for _, c in ipairs(S.cursors) do marks.refresh_mark(c) end
end

-- ── Motion mirroring ──────────────────────────────────────────────────────────

function M.apply_motion(key)
  if S.in_apply then return end
  S.in_apply = true
  local buf  = api.nvim_get_current_buf()
  local main = api.nvim_win_get_cursor(0)
  for _, c in ipairs(S.cursors) do
    if c.buf == buf then
      local row, col = marks.mark_pos(c)
      if row then
        api.nvim_win_set_cursor(0, { row + 1, col })
        pcall(vim.cmd, 'normal! ' .. key)
        local npos = api.nvim_win_get_cursor(0)
        marks.move_mark(c, npos[1] - 1, npos[2])
      end
    end
  end
  api.nvim_win_set_cursor(0, main)
  S.in_apply = false
end

-- Destination column of f/t/F/T on a single line (pure Lua, byte-based).
function M.ft_dest(ln, col, mk, tc)
  local nc = col
  if mk == 'f' or mk == 't' then
    local i = ln:find(tc, col + 2, true)         -- first hit right of cursor
    if i then nc = (mk == 'f') and i - 1 or i - 2 end
  else
    local best, init = nil, 1                    -- last hit left of cursor
    while true do
      local i = ln:find(tc, init, true)
      if not i or i > col then break end
      best, init = i, i + 1
    end
    if best then nc = (mk == 'F') and best - 1 or best - 1 + #tc end
  end
  if nc < 0 then nc = col end
  return nc
end

-- Pure-Lua f/t/F/T — avoids normal! re-triggering vim.on_key.
function M.apply_ftFT(mk, tc)
  if S.in_apply then return end
  S.in_apply = true
  local buf = api.nvim_get_current_buf()
  for _, c in ipairs(S.cursors) do
    if c.buf == buf then
      local row, col = marks.mark_pos(c)
      if row then
        marks.move_mark(c, row, M.ft_dest(marks.line_at(buf, row), col, mk, tc))
      end
    end
  end
  S.in_apply = false
end

-- ── Visual extend mode ────────────────────────────────────────────────────────

function M.extend_span(c)
  local sr, sc = c.vs[1], c.vs[2]
  local er, ec = c.ve[1], c.ve[2]
  if er < sr or (er == sr and ec < sc) then
    sr, sc, er, ec = er, ec, sr, sc
  end
  return sr, sc, er, ec
end

local function update_extend_mark(c)
  local sr, sc, er, ec = M.extend_span(c)
  local eln  = marks.line_at(c.buf, er)
  local ecol = math.min(ec + math.max(1, #vim.fn.strpart(eln, ec, 1, 1)), math.max(#eln, 0))
  if er == sr and ecol < sc then ecol = sc end
  api.nvim_buf_set_extmark(c.buf, NS, sr, sc, {
    id            = c.id,
    hl_group      = marks.cursor_hl(),
    end_row       = er,
    end_col       = ecol,
    priority      = 300,
    right_gravity = false,
  })
end

function M.start_extend()
  if S.word then regions.collapse_word_mode() end
  local buf = api.nvim_get_current_buf()
  S.extend, S.extend_op = true, nil
  for _, c in ipairs(S.cursors) do
    if c.buf == buf then
      local row, col = marks.mark_pos(c)
      if row then
        c.vs, c.ve = { row, col }, { row, col }
        update_extend_mark(c)
      end
    end
  end
end

-- Leave extend mode without an operator (Esc / v again): collapse each
-- selection to its moving end, like Neovim leaves the cursor there.
function M.cancel_extend()
  if not S.extend then return end
  S.extend, S.extend_op = false, nil
  for _, c in ipairs(S.cursors) do
    if c.ve then
      local row, col = c.ve[1], c.ve[2]
      c.vs, c.ve = nil, nil
      c.word_len = 1
      marks.move_mark(c, row, col)
    end
  end
end

-- d/x/c/s on extend selections: delete every selected range (inclusive),
-- bottom-right → top-left, leaving a point cursor at each selection start.
function M.extend_delete()
  if S.in_apply then return end
  S.in_apply = true
  local buf   = api.nvim_get_current_buf()
  local items = {}
  for _, c in ipairs(S.cursors) do
    if c.buf == buf and c.vs and c.ve then
      local sr, sc, er, ec = M.extend_span(c)
      items[#items + 1] = { sr = sr, sc = sc, er = er, ec = ec }
    end
  end
  table.sort(items, function(a, b)
    if a.sr ~= b.sr then return a.sr > b.sr end
    return a.sc > b.sc
  end)
  for _, it in ipairs(items) do
    pcall(vim.cmd, 'undojoin')
    local eln  = marks.line_at(buf, it.er)
    local ecol = math.min(it.ec + math.max(1, #vim.fn.strpart(eln, it.ec, 1, 1)), #eln)
    if it.sr == it.er and ecol < it.sc then ecol = it.sc end
    pcall(api.nvim_buf_set_text, buf, it.sr, it.sc, it.er, ecol, { '' })
  end
  for _, c in ipairs(S.cursors) do
    c.vs, c.ve = nil, nil
    c.word_len = 1
  end
  S.extend, S.extend_op = false, nil
  S.in_apply = false
  for _, c in ipairs(S.cursors) do marks.refresh_mark(c) end
end

-- y on extend selections: no text change, collapse to selection starts.
function M.extend_yank_collapse()
  for _, c in ipairs(S.cursors) do
    if c.vs and c.ve then
      local sr, sc = M.extend_span(c)
      c.vs, c.ve = nil, nil
      c.word_len = 1
      marks.move_mark(c, sr, sc)
    end
  end
  S.extend, S.extend_op = false, nil
end

-- Mirror a motion on every selection end. The real cursor is in native
-- visual mode, so `normal!` would extend *its* selection: temporarily leave
-- visual, move each fake end, then restore the real selection with gv.
function M.apply_extend_motion(key)
  if S.in_apply then return end
  if api.nvim_get_mode().mode ~= 'v' then return end
  S.in_apply = true
  local buf = api.nvim_get_current_buf()
  local esc = api.nvim_replace_termcodes('<Esc>', true, false, true)
  api.nvim_feedkeys(esc, 'nx', false)
  local main = api.nvim_win_get_cursor(0)
  for _, c in ipairs(S.cursors) do
    if c.buf == buf and c.ve then
      api.nvim_win_set_cursor(0, { c.ve[1] + 1, c.ve[2] })
      pcall(vim.cmd, 'normal! ' .. key)
      local p = api.nvim_win_get_cursor(0)
      c.ve = { p[1] - 1, p[2] }
      update_extend_mark(c)
    end
  end
  api.nvim_win_set_cursor(0, main)
  api.nvim_feedkeys('gv', 'nx', false)
  S.in_apply = false
end

function M.apply_extend_ft(mk, tc)
  if S.in_apply then return end
  S.in_apply = true
  local buf = api.nvim_get_current_buf()
  for _, c in ipairs(S.cursors) do
    if c.buf == buf and c.ve then
      c.ve[2] = M.ft_dest(marks.line_at(buf, c.ve[1]), c.ve[2], mk, tc)
      update_extend_mark(c)
    end
  end
  S.in_apply = false
end

-- ── Operators (d / c with a motion, point mode) ───────────────────────────────

function M.op_status(op, keys)
  if #keys == 1 then
    if M.OP_MOTIONS[keys] or keys == op then return 'done' end
    if keys == 'i' or keys == 'a' or M.PENDING_MOTIONS[keys] then return 'wait' end
    return 'cancel'
  end
  return 'done'
end

-- Applies op+keys to the main cursor and every fake cursor in normal mode.
-- Both the operator key and the motion are suppressed by the key interceptor,
-- so Neovim never processes them — we replay everything with normal! here.
-- A scratch extmark tracks the main-cursor position through the fake-cursor
-- edits so it stays accurate even when earlier deletions shift lines.
function M.apply_operator(op, keys)
  if S.in_apply then return end
  S.in_apply = true
  local buf = api.nvim_get_current_buf()

  local mkeys = keys
  if op == 'c' then
    -- cw/cW behave like ce/cE (vim's own special case)
    if keys == 'w' then mkeys = 'e' elseif keys == 'W' then mkeys = 'E' end
  end

  local cmd = 'normal! d' .. (keys == op and op or mkeys)

  -- Apply to main cursor first; this starts the undo entry.
  local main = api.nvim_win_get_cursor(0)
  local mrow = main[1] - 1
  if op == 'c' and keys == op then          -- cc: clear the line, keep it
    local ln = marks.line_at(buf, mrow)
    if #ln > 0 then api.nvim_buf_set_text(buf, mrow, 0, mrow, #ln, { '' }) end
    api.nvim_win_set_cursor(0, { mrow + 1, 0 })
  else
    pcall(vim.cmd, cmd)
  end

  local after   = api.nvim_win_get_cursor(0)
  local at_eol  = after[2] >= #marks.line_at(buf, after[1] - 1)
  local scratch = api.nvim_buf_set_extmark(buf, NS, after[1] - 1, after[2], {})

  -- Apply to fake cursors, joining each edit into the same undo entry.
  for _, c in ipairs(S.cursors) do
    if c.buf == buf then
      local row, col = marks.mark_pos(c)
      if row then
        pcall(vim.cmd, 'undojoin')
        api.nvim_win_set_cursor(0, { row + 1, col })
        if op == 'c' and keys == op then
          local ln = marks.line_at(buf, row)
          if #ln > 0 then api.nvim_buf_set_text(buf, row, 0, row, #ln, { '' }) end
          api.nvim_win_set_cursor(0, { row + 1, 0 })
        else
          pcall(vim.cmd, cmd)
        end
        local p = api.nvim_win_get_cursor(0)
        marks.move_mark(c, p[1] - 1, p[2])
      end
    end
  end

  local pos  = api.nvim_buf_get_extmark_by_id(buf, NS, scratch, {})
  pcall(api.nvim_buf_del_extmark, buf, NS, scratch)
  local rrow = ((pos and pos[1]) or (after[1] - 1)) + 1
  local rcol = (pos and pos[2]) or after[2]
  pcall(api.nvim_win_set_cursor, 0, { rrow, rcol })
  S.in_apply = false

  if op == 'c' then
    vim.cmd(at_eol and 'startinsert!' or 'startinsert')
  end
end

-- Delete the matched text of every region (frozen + current) in a single
-- bottom-right → top-left pass, so earlier deletions cannot shift positions
-- that are still pending. Returns the final position of the current region,
-- tracked through the edits by a scratch extmark.
function M.delete_regions_text()
  local buf  = api.nvim_get_current_buf()
  local main = api.nvim_win_get_cursor(0)
  local mr   = S.cur_row or (main[1] - 1)
  local mc   = S.cur_col or main[2]

  local scratch = api.nvim_buf_set_extmark(buf, NS, mr, mc, { right_gravity = true })

  local list = regions.sorted_positions()
  if not regions.region_at(buf, mr, mc) then
    list[#list + 1] = { buf = buf, row = mr, col = mc, word_len = S.word_len }
    table.sort(list, function(a, b)
      if a.row ~= b.row then return a.row > b.row end
      return a.col > b.col
    end)
  end
  for _, p in ipairs(list) do
    pcall(vim.cmd, 'undojoin')
    local e = math.min(p.col + p.word_len, #marks.line_at(p.buf, p.row))
    api.nvim_buf_set_text(p.buf, p.row, p.col, p.row, e, { '' })
  end

  local pos = api.nvim_buf_get_extmark_by_id(buf, NS, scratch, {})
  pcall(api.nvim_buf_del_extmark, buf, NS, scratch)
  if pos and #pos >= 2 then return pos[1], pos[2] end
  return mr, mc
end

return M
