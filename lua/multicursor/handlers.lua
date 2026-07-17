local api     = vim.api
local state   = require('multicursor.state')
local marks   = require('multicursor.marks')
local regions = require('multicursor.regions')
local edit    = require('multicursor.edit')
local S       = state.S
local KEY_ESC = state.KEY_ESC

local M = {}

function M.handle_normal_key(k)
  if S.in_apply then return end

  -- Stray ESC bytes (Alt-combo leakage) must never touch the session;
  -- deliberate exits go through the <Esc> keymap installed while active.
  if k == KEY_ESC then return end

  if edit.PENDING_MOTIONS[k] then
    S.pending_motion = k
    return
  end

  -- ; and , replay the last f/t/F/T on the frozen regions.
  if k == ';' or k == ',' then
    local lf = S.last_ft
    if lf then
      local mk = k == ',' and edit.REVERSE_FT[lf.mk] or lf.mk
      local tc = lf.tc
      vim.schedule(function()
        if S.active then regions.collapse_word_mode(); edit.apply_ftFT(mk, tc) end
      end)
    end
    return
  end

  if edit.MOTION_KEYS[k] then
    vim.schedule(function()
      if S.active then regions.collapse_word_mode(); edit.apply_motion(k) end
    end)
    return
  end

  -- v — visual extend mode: every cursor grows a selection with the motions
  if k == 'v' and #S.cursors > 0 then
    vim.schedule(function() if S.active then edit.start_extend() end end)
    return
  end

  -- x / X with word-mode selection: delete the entire selection (like d)
  if (k == 'x' or k == 'X') and S.word then
    vim.schedule(function()
      if not S.active then return end
      S.in_apply = true
      local frow, fcol = edit.delete_regions_text()
      api.nvim_win_set_cursor(0, { frow + 1, fcol })
      for _, c in ipairs(S.cursors) do c.word_len = 1 end
      S.word = nil; S.word_len = 0
      S.cur_row, S.cur_col = nil, nil
      marks.clear_current_hl()
      S.in_apply = false
      for _, c in ipairs(S.cursors) do marks.refresh_mark(c) end
    end)
    return true  -- suppress: Neovim must not see x or it deletes a single char
  end

  -- x / X — delete char at / before cursor (point mode)
  if k == 'x' then
    vim.schedule(function()
      if not S.active then return end
      regions.collapse_word_mode()
      S.in_apply = true
      for _, p in ipairs(regions.sorted_positions()) do
        pcall(vim.cmd, 'undojoin')
        edit.do_delete_fwd(p.buf, p.row, p.col)
      end
      S.in_apply = false
      for _, c in ipairs(S.cursors) do marks.refresh_mark(c) end
    end)
    return
  end
  if k == 'X' then
    vim.schedule(function()
      if not S.active then return end
      regions.collapse_word_mode()
      S.in_apply = true
      for _, p in ipairs(regions.sorted_positions()) do
        pcall(vim.cmd, 'undojoin')
        edit.do_backspace(p.buf, p.row, p.col)
      end
      S.in_apply = false
      for _, c in ipairs(S.cursors) do marks.refresh_mark(c) end
    end)
    return
  end

  -- c / s — change selected text at all regions, then enter insert mode
  if (k == 'c' or k == 's') and S.word then
    vim.schedule(function()
      if not S.active then return end
      S.in_apply = true
      local frow, fcol = edit.delete_regions_text()
      api.nvim_win_set_cursor(0, { frow + 1, fcol })
      for _, c in ipairs(S.cursors) do c.word_len = 1 end
      S.word = nil; S.word_len = 0
      S.cur_row, S.cur_col = nil, nil
      marks.clear_current_hl()
      S.in_apply = false
      for _, c in ipairs(S.cursors) do marks.refresh_mark(c) end
      vim.cmd('startinsert')
    end)
    return true  -- suppress: we handle everything, Neovim must not see c/s
  end

  -- d — delete selected text at all regions
  if k == 'd' and S.word then
    vim.schedule(function()
      if not S.active then return end
      S.in_apply = true
      local frow, fcol = edit.delete_regions_text()
      api.nvim_win_set_cursor(0, { frow + 1, fcol })
      for _, c in ipairs(S.cursors) do c.word_len = 1 end
      S.word = nil; S.word_len = 0
      S.cur_row, S.cur_col = nil, nil
      marks.clear_current_hl()
      S.in_apply = false
      for _, c in ipairs(S.cursors) do marks.refresh_mark(c) end
    end)
    return true  -- suppress: Neovim must not see d or it enters operator-pending
  end

  -- s (point mode) — substitute: delete char at each cursor, insert follows
  if k == 's' then
    vim.schedule(function()
      if not S.active then return end
      S.in_apply = true
      for _, p in ipairs(regions.sorted_positions()) do edit.do_delete_fwd(p.buf, p.row, p.col) end
      S.in_apply = false
      for _, c in ipairs(S.cursors) do marks.refresh_mark(c) end
    end)
    return
  end

  -- d / c with a motion (point mode): capture the motion, then replay.
  -- Suppress the operator key; apply_operator handles main + fake cursors.
  if (k == 'd' or k == 'c') and #S.cursors > 0 then
    S.pending_op = { op = k, keys = '' }
    return true
  end

  -- D / C — delete to end of line at every cursor (C: insert follows)
  if k == 'D' or k == 'C' then
    vim.schedule(function()
      if not S.active then return end
      regions.collapse_word_mode()
      S.in_apply = true
      for _, p in ipairs(regions.sorted_positions()) do
        pcall(vim.cmd, 'undojoin')
        local ln = marks.line_at(p.buf, p.row)
        if p.col < #ln then
          api.nvim_buf_set_text(p.buf, p.row, p.col, p.row, #ln, { '' })
        end
      end
      S.in_apply = false
      for _, c in ipairs(S.cursors) do marks.refresh_mark(c) end
    end)
    return
  end

  -- Insert-mode entry keys: leave word mode and reposition frozen regions
  if k == 'i' or k == 'a' or k == 'A' or k == 'I' then
    vim.schedule(function()
      if not S.active then return end
      regions.collapse_word_mode()
      for _, c in ipairs(S.cursors) do
        if k == 'a' then
          edit.do_move_col(c, 1)
        elseif k == 'A' then
          edit.do_move_eol(c)
        elseif k == 'I' then
          edit.do_move_bol(c, true)
        end
      end
    end)
  end
end

function M.handle_visual_key(k)
  if S.in_apply then return end

  if edit.PENDING_MOTIONS[k] then
    S.pending_motion = k
    return
  end

  if k == ';' or k == ',' then
    local lf = S.last_ft
    if lf then
      local mk = k == ',' and edit.REVERSE_FT[lf.mk] or lf.mk
      local tc = lf.tc
      vim.schedule(function()
        if S.active and S.extend then edit.apply_extend_ft(mk, tc) end
      end)
    end
    return
  end

  if edit.MOTION_KEYS[k] then
    vim.schedule(function()
      if S.active and S.extend then edit.apply_extend_motion(k) end
    end)
    return
  end

  if k == 'd' or k == 'x' or k == 'c' or k == 's' then
    S.extend_op = k
    vim.schedule(function() if S.active then edit.extend_delete() end end)
    return
  end

  if k == 'y' then
    S.extend_op = 'y'
    vim.schedule(function() if S.active then edit.extend_yank_collapse() end end)
    return
  end
end

return M
