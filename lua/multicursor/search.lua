local api     = vim.api
local state   = require('multicursor.state')
local marks   = require('multicursor.marks')
local regions = require('multicursor.regions')
local S       = state.S
local NS      = state.NS

local M = {}

local function vim_escape(word)
  return vim.fn.escape(word, '\\/.*$^~[]')
end

local function occ_pattern()
  local p = vim_escape(S.word)
  if S.whole_word then p = '\\<' .. p .. '\\>' end
  return '\\C' .. p
end

function M.find_next_occ(word, from_row, from_col)
  local pattern  = occ_pattern()
  local line_cnt = api.nvim_buf_line_count(0)
  local saved    = api.nvim_win_get_cursor(0)
  local srow, scol = from_row, from_col + #word
  local ln_len = #marks.line_at(0, from_row)
  if scol >= ln_len then srow = from_row + 1; scol = 0 end
  if srow >= line_cnt then srow = 0; scol = 0 end
  api.nvim_win_set_cursor(0, { srow + 1, scol })
  -- 'c' so a match starting exactly at the search start is not skipped
  -- (matters for adjacent matches, e.g. "ab" in "abab")
  local r = vim.fn.searchpos(pattern, 'wnc')
  api.nvim_win_set_cursor(0, saved)
  if r[1] > 0 then return r[1] - 1, r[2] - 1 end
  return nil, nil
end

function M.find_prev_occ(_, from_row, from_col)
  local pattern = occ_pattern()
  local saved   = api.nvim_win_get_cursor(0)
  api.nvim_win_set_cursor(0, { from_row + 1, from_col })
  local r = vim.fn.searchpos(pattern, 'bwn')
  api.nvim_win_set_cursor(0, saved)
  if r[1] > 0 then return r[1] - 1, r[2] - 1 end
  return nil, nil
end

function M.word_under_cursor()
  local word = vim.fn.expand('<cword>')
  if word == '' then return nil, nil, nil end
  local ws = vim.fn.searchpos('\\<' .. vim_escape(word) .. '\\>', 'bcn')
  if ws[1] == 0 then
    local cur = api.nvim_win_get_cursor(0)
    return word, cur[1] - 1, cur[2]
  end
  return word, ws[1] - 1, ws[2] - 1
end

local function word_at(ln, col)
  if #ln == 0 then return nil end
  col = math.min(col, #ln - 1)
  local function wc(i) return ln:sub(i, i):match('[%w_]') ~= nil end
  if not wc(col + 1) then return nil end
  local s, e = col, col
  while s > 0 and wc(s) do s = s - 1 end
  while e + 1 < #ln and wc(e + 2) do e = e + 1 end
  return s, e - s + 1
end

function M.is_word_char(ch)
  return ch:match('[%w_]') ~= nil
end

function M.capture_visual()
  local mode = api.nvim_get_mode().mode
  if not mode:match('^[vV\22]') then return nil end
  local esc = api.nvim_replace_termcodes('<Esc>', true, false, true)
  if mode ~= 'v' then
    api.nvim_feedkeys(esc, 'nx', false)
    vim.notify('MultiCursor: only charwise (v) selections are supported', vim.log.levels.WARN)
    return nil, 'abort'
  end
  local sp, cp = vim.fn.getpos('v'), vim.fn.getpos('.')
  if sp[2] ~= cp[2] then
    api.nvim_feedkeys(esc, 'nx', false)
    vim.notify('MultiCursor: multi-line selections are not supported', vim.log.levels.WARN)
    return nil, 'abort'
  end
  local row  = sp[2] - 1
  local a, b = sp[3] - 1, cp[3] - 1
  if a > b then a, b = b, a end
  local ln    = marks.line_at(0, row)
  -- extend b to cover the whole (possibly multibyte) last character
  local b_end = b + math.max(1, #vim.fn.strpart(ln, b, 1, 1))
  local text  = ln:sub(a + 1, b_end)
  api.nvim_feedkeys(esc, 'nx', false)
  if text == '' then return nil, 'abort' end
  return text, row, a
end

-- Word under cursor, or the visual selection when one is active.
-- Returns text, row, col, whole_word — or nil when there is nothing to use.
function M.target_text()
  local word, row, col = M.capture_visual()
  if word then return word, row, col, false end
  if row == 'abort' then return nil end
  word, row, col = M.word_under_cursor()
  if not word then return nil end
  return word, row, col, true
end

function M.start_session()
  local buf = api.nvim_get_current_buf()
  local word, row, col, whole = M.target_text()
  if not word then return end
  S.word       = word
  S.word_len   = #word
  S.whole_word = whole
  regions.set_active()
  marks.set_current(buf, row, col)
end

-- VM's Find-Under in cursor mode: turn every point cursor into a region on
-- the word it sits on.
function M.wordify_cursors()
  local buf = api.nvim_get_current_buf()
  local word, row, col = M.word_under_cursor()
  if not word then return end

  for _, c in ipairs(S.cursors) do
    if c.buf == buf then
      local r, cl = marks.mark_pos(c)
      if r then
        local s, len = word_at(marks.line_at(buf, r), cl)
        if s then
          c.word_len = len
          marks.move_mark(c, r, s)
        end
      end
    end
  end

  -- Drop duplicates and any region that landed on the current one.
  local seen = {}
  for i = #S.cursors, 1, -1 do
    local c = S.cursors[i]
    local r, cl = marks.mark_pos(c)
    local key = r and (c.buf .. ':' .. r .. ':' .. cl)
    if not r or seen[key] or (c.buf == buf and r == row and cl == col) then
      pcall(api.nvim_buf_del_extmark, c.buf, NS, c.id)
      table.remove(S.cursors, i)
    else
      seen[key] = true
    end
  end

  S.word       = word
  S.word_len   = #word
  S.whole_word = true
  marks.set_current(buf, row, col)
end

return M
