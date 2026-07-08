local api   = vim.api
local state = require('multicursor.state')
local marks = require('multicursor.marks')
local S     = state.S
local NS    = state.NS

local M = {}

-- Deactivation must NOT react to raw ESC bytes seen by vim.on_key: terminals
-- and multiplexers can leak ESC around Alt-modified keys. A real <Esc> keymap
-- lets Neovim's mapping engine disambiguate a deliberate press for us.
function M.install_esc_map()
  if S.esc_mapped then return end
  S.esc_mapped = true
  local saved  = vim.fn.maparg('<Esc>', 'n', false, true)
  S.saved_esc  = (saved and saved.lhs) and saved or nil
  vim.keymap.set('n', '<Esc>', function()
    vim.schedule(S.deactivate_fn)
    return '<Esc>'
  end, { expr = true, silent = true, desc = 'MultiCursor: exit' })
end

function M.restore_esc_map()
  if not S.esc_mapped then return end
  S.esc_mapped = false
  pcall(vim.keymap.del, 'n', '<Esc>')
  if S.saved_esc then
    pcall(vim.fn.mapset, 'n', false, S.saved_esc)
  end
  S.saved_esc = nil
end

function M.set_active()
  if not S.active then
    S.active = true
    M.install_esc_map()
  end
end

function M.region_at(buf, row, col)
  for _, c in ipairs(S.cursors) do
    if c.buf == buf then
      local r, cl = marks.mark_pos(c)
      if r == row and cl == col then return c end
    end
  end
  return nil
end

function M.remove_region(target)
  for i, c in ipairs(S.cursors) do
    if c == target then
      pcall(api.nvim_buf_del_extmark, c.buf, NS, c.id)
      table.remove(S.cursors, i)
      return
    end
  end
end

function M.add_cursor(buf, row, col, wlen)
  if M.region_at(buf, row, col) then return false end
  local id = marks.place_mark(buf, row, col, wlen)
  table.insert(S.cursors, { id = id, buf = buf, word_len = wlen })
  M.set_active()
  return true
end

-- Returns frozen-region positions sorted bottom-right → top-left.
function M.sorted_positions()
  local buf  = api.nvim_get_current_buf()
  local list = {}
  for _, c in ipairs(S.cursors) do
    if c.buf == buf then
      local row, col = marks.mark_pos(c)
      if row then
        list[#list + 1] = { buf = buf, id = c.id, row = row, col = col, word_len = c.word_len }
      end
    end
  end
  table.sort(list, function(a, b)
    if a.row ~= b.row then return a.row > b.row end
    return a.col > b.col
  end)
  return list
end

-- Once a cursor motion is used, regions lose their selection and keep only a
-- point cursor at their start (VM's cursor mode behaviour).
function M.collapse_word_mode()
  if not S.word then return end
  marks.clear_current_hl()
  S.word, S.word_len   = nil, 0
  S.whole_word         = true
  S.cur_row, S.cur_col = nil, nil
  for _, c in ipairs(S.cursors) do
    c.word_len = 1
    marks.refresh_mark(c)
  end
end

return M
