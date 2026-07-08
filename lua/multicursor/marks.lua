local api   = vim.api
local state = require('multicursor.state')
local S     = state.S
local NS    = state.NS

local M = {}

function M.setup_hl()
  api.nvim_set_hl(0, 'MultiCursor',       { reverse   = true, default = true })
  -- Fake cursors cannot be rendered as a real thin bar in a terminal, so
  -- insert mode falls back to an underline instead of the reverse block.
  api.nvim_set_hl(0, 'MultiCursorInsert', { underline = true, default = true })
end

function M.line_at(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
end

function M.cursor_hl()
  return api.nvim_get_mode().mode:sub(1, 1) == 'i' and 'MultiCursorInsert' or 'MultiCursor'
end

function M.make_mark_opts(col, wlen, ln)
  local hl      = M.cursor_hl()
  local end_col = math.min(col + wlen, #ln)
  local opts    = {
    hl_group      = hl,
    end_col       = math.max(end_col, col),
    priority      = 200,
    right_gravity = true,
  }
  local ch = col < #ln and ln:sub(col + 1, col + 1) or ''
  if ch == '' or ch:match('%s') then
    -- Whitespace and end-of-line cells are often covered by overlay virtual
    -- text from other plugins; draw our own cell on top so the cursor stays
    -- visible there.
    opts.virt_text     = { { ' ', hl } }
    opts.virt_text_pos = 'overlay'
    opts.priority      = 4096
    if ch == '' then opts.end_col = col end
  end
  return opts
end

function M.place_mark(buf, row, col, wlen)
  local ln   = M.line_at(buf, row)
  local opts = M.make_mark_opts(col, wlen, ln)
  return api.nvim_buf_set_extmark(buf, NS, row, col, opts)
end

function M.mark_pos(c)
  local pos = api.nvim_buf_get_extmark_by_id(c.buf, NS, c.id, {})
  if pos and #pos >= 2 then return pos[1], pos[2] end
  return nil, nil
end

function M.move_mark(c, row, col)
  local ln   = M.line_at(c.buf, row)
  local opts = M.make_mark_opts(col, c.word_len, ln)
  opts.id    = c.id
  api.nvim_buf_set_extmark(c.buf, NS, row, col, opts)
end

function M.refresh_mark(c)
  local row, col = M.mark_pos(c)
  if row then M.move_mark(c, row, col) end
end

function M.set_current_hl(buf, row, col)
  if S.cur_hl_id and S.cur_hl_buf then
    pcall(api.nvim_buf_del_extmark, S.cur_hl_buf, NS, S.cur_hl_id)
  end
  S.cur_hl_id  = nil
  S.cur_hl_buf = nil
  if not S.word or S.word_len == 0 then return end
  local ln   = M.line_at(buf, row)
  local opts = M.make_mark_opts(col, S.word_len, ln)
  S.cur_hl_id  = api.nvim_buf_set_extmark(buf, NS, row, col, opts)
  S.cur_hl_buf = buf
end

function M.clear_current_hl()
  if S.cur_hl_id and S.cur_hl_buf then
    pcall(api.nvim_buf_del_extmark, S.cur_hl_buf, NS, S.cur_hl_id)
  end
  S.cur_hl_id  = nil
  S.cur_hl_buf = nil
end

-- Move the real cursor to (row, col) and draw the current-region highlight.
function M.set_current(buf, row, col)
  S.cur_row, S.cur_col = row, col
  api.nvim_win_set_cursor(0, { row + 1, col })
  M.set_current_hl(buf, row, col)
end

return M
