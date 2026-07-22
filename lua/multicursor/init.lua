local api      = vim.api
local state    = require('multicursor.state')
local marks    = require('multicursor.marks')
local regions  = require('multicursor.regions')
local edit     = require('multicursor.edit')
local search   = require('multicursor.search')
local handlers = require('multicursor.handlers')
local S        = state.S
local NS       = state.NS
local KEY_ESC  = state.KEY_ESC
local KEY_BS   = state.KEY_BS
local KEY_DEL  = state.KEY_DEL

local M = {}

-- ── Deactivate ────────────────────────────────────────────────────────────────

function M.deactivate()
  regions.restore_esc_map()
  edit.remove_extend_maps()
  marks.clear_current_hl()
  for _, c in ipairs(S.cursors) do
    pcall(api.nvim_buf_del_extmark, c.buf, NS, c.id)
  end
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) then
      api.nvim_buf_clear_namespace(b, NS, 0, -1)
    end
  end
  S.cursors        = {}
  S.active         = false
  S.word           = nil
  S.word_len       = 0
  S.whole_word     = true
  S.cur_row        = nil
  S.cur_col        = nil
  S.cur_hl_id      = nil
  S.cur_hl_buf     = nil
  S.pending_motion = nil
  S.pending_op     = nil
  S.last_ft        = nil
  S.extend         = false
  S.extend_op      = nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- <M-n> — VM-Find-Under: first press selects the word under cursor (or the
-- active visual selection). Each next press freezes the current region and
-- makes the next occurrence current. When every occurrence is already
-- selected it cycles through them instead of duplicating.
function M.add_next()
  local buf = api.nvim_get_current_buf()

  if not S.word then
    if S.active and #S.cursors > 0 then
      search.wordify_cursors()
    else
      search.start_session()
    end
    return
  end

  local cur = api.nvim_win_get_cursor(0)
  local nr, nc = search.find_next_occ(S.word, cur[1] - 1, cur[2])
  if not nr or (nr == S.cur_row and nc == S.cur_col) then
    vim.notify('MultiCursor: no other occurrences of "' .. S.word .. '"', vim.log.levels.INFO)
    return
  end

  local existing = regions.region_at(buf, nr, nc)
  if S.cur_row then regions.add_cursor(buf, S.cur_row, S.cur_col, S.word_len) end
  if existing then regions.remove_region(existing) end
  marks.clear_current_hl()
  marks.set_current(buf, nr, nc)
end

-- <M-N> — VM-Find-Prev: like add_next but towards the previous occurrence.
function M.add_prev()
  local buf = api.nvim_get_current_buf()

  if not S.word then
    if S.active and #S.cursors > 0 then
      search.wordify_cursors()
    else
      search.start_session()
    end
    return
  end

  local cur = api.nvim_win_get_cursor(0)
  local nr, nc = search.find_prev_occ(S.word, cur[1] - 1, cur[2])
  if not nr or (nr == S.cur_row and nc == S.cur_col) then
    vim.notify('MultiCursor: no other occurrences of "' .. S.word .. '"', vim.log.levels.INFO)
    return
  end

  local existing = regions.region_at(buf, nr, nc)
  if S.cur_row then regions.add_cursor(buf, S.cur_row, S.cur_col, S.word_len) end
  if existing then regions.remove_region(existing) end
  marks.clear_current_hl()
  marks.set_current(buf, nr, nc)
end

-- <M-x> — VM-Skip-Region: discard the current region and make the next
-- occurrence current instead.
function M.skip_next()
  if not S.active or not S.word then return end
  local buf = api.nvim_get_current_buf()

  local cur = api.nvim_win_get_cursor(0)
  local nr, nc = search.find_next_occ(S.word, cur[1] - 1, cur[2])
  if not nr or (nr == S.cur_row and nc == S.cur_col) then
    marks.clear_current_hl()
    if #S.cursors == 0 then M.deactivate() end
    vim.notify('MultiCursor: no more occurrences', vim.log.levels.INFO)
    return
  end

  local existing = regions.region_at(buf, nr, nc)
  if existing then regions.remove_region(existing) end
  marks.clear_current_hl()
  marks.set_current(buf, nr, nc)     -- old current is NOT frozen: skipped
end

-- <M-X> — VM-Remove-Region: remove the current region (or the most recent
-- cursor in point mode) and move back to the previous one.
function M.remove_last()
  if not S.active then return end
  local c = table.remove(S.cursors)

  if S.word then
    marks.clear_current_hl()
    if not c then M.deactivate(); return end
    local row, col = marks.mark_pos(c)
    pcall(api.nvim_buf_del_extmark, c.buf, NS, c.id)
    if row and c.buf == api.nvim_get_current_buf() then
      marks.set_current(c.buf, row, col)
    elseif #S.cursors == 0 then
      M.deactivate()
    end
    return
  end

  if not c then M.deactivate(); return end
  local row, col = marks.mark_pos(c)
  pcall(api.nvim_buf_del_extmark, c.buf, NS, c.id)
  if row and c.buf == api.nvim_get_current_buf() then
    api.nvim_win_set_cursor(0, { row + 1, col })
  end
  if #S.cursors == 0 then M.deactivate() end
end

-- <M-A> — VM-Select-All: select every occurrence of the word under cursor
-- (or of the active visual selection).
function M.select_all()
  local buf = api.nvim_get_current_buf()
  local word, mrow, mcol, whole = search.target_text()
  if not word then return end

  S.word       = word
  S.word_len   = #word
  S.whole_word = whole
  regions.set_active()
  marks.set_current(buf, mrow, mcol)

  for row = 0, api.nvim_buf_line_count(buf) - 1 do
    local ln  = marks.line_at(buf, row)
    local pos = 1
    while true do
      local s, e = ln:find(word, pos, true)
      if not s then break end
      local ok = true
      if S.whole_word then
        local before = s > 1   and ln:sub(s - 1, s - 1) or ' '
        local after  = e < #ln and ln:sub(e + 1, e + 1) or ' '
        ok = not search.is_word_char(before) and not search.is_word_char(after)
      end
      if ok then
        local is_current = row == mrow and (s - 1) <= mcol and mcol <= (e - 1)
        if not is_current then
          regions.add_cursor(buf, row, s - 1, #word)
        end
      end
      pos = e + 1
    end
  end

  if #S.cursors > 0 then
    vim.notify(string.format('MultiCursor: %d cursors on "%s"', #S.cursors + 1, word), vim.log.levels.INFO)
  else
    vim.notify('MultiCursor: only one occurrence of "' .. word .. '"', vim.log.levels.INFO)
  end
end

-- <M-Down> / <M-Up>: add a point cursor on the line below / above.
function M.add_vertical(dir)
  if S.word then regions.collapse_word_mode() end

  local buf      = api.nvim_get_current_buf()
  local cur      = api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local nrow     = row + dir

  if nrow < 0 or nrow >= api.nvim_buf_line_count(buf) then return end

  local ln   = marks.line_at(buf, nrow)
  local ncol = math.min(col, math.max(0, #ln - 1))

  api.nvim_win_set_cursor(0, { nrow + 1, ncol })
  regions.add_cursor(buf, row, col, 1)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}
  -- Inject deactivate into shared state so regions/handlers can call it
  -- without a circular dependency back into this module.
  S.deactivate_fn = M.deactivate

  marks.setup_hl()

  local aug = api.nvim_create_augroup('MultiCursor', { clear = true })
  api.nvim_create_autocmd('ColorScheme', { group = aug, callback = marks.setup_hl })

  -- Restyle marks when entering/leaving insert mode, and mirror Neovim's
  -- cursor-left-by-1 when leaving it.
  api.nvim_create_autocmd('ModeChanged', {
    group   = aug,
    pattern = { '*:i*', 'i*:*' },
    callback = function(ev)
      if not S.active or S.in_apply then return end
      local from, to = ev.match:match('^(.*):(.*)$')
      local left_insert = from:sub(1, 1) == 'i' and to:sub(1, 1) ~= 'i'
      for _, c in ipairs(S.cursors) do
        if not c.vs then
          local row, col = marks.mark_pos(c)
          if row then
            if left_insert and col > 0 then col = col - 1 end
            marks.move_mark(c, row, col)
          end
        end
      end
    end,
  })

  -- Leaving charwise visual without an operator cancels extend mode.
  api.nvim_create_autocmd('ModeChanged', {
    group   = aug,
    pattern = 'v:*',
    callback = function()
      if not S.active or S.in_apply then return end
      if S.extend and not S.extend_op then
        vim.schedule(function()
          if S.extend and not S.extend_op then edit.cancel_extend() end
        end)
      end
    end,
  })

  api.nvim_create_autocmd('BufLeave', {
    group    = aug,
    callback = function() if S.active then M.deactivate() end end,
  })

  -- Main key interceptor.
  vim.on_key(function(key, typed)
    if not S.active or S.in_apply then return end

    local mode = api.nvim_get_mode().mode

    if mode:sub(1, 1) == 'i' then
      -- key == '' fires for incomplete mapping sequences; ignore.
      if key == '' then return end
      vim.schedule(function() if S.active then edit.apply_to_cursors(key) end end)
      return
    end

    -- Outside insert mode work with the keys as *typed*: `key` carries the
    -- post-mapping expansion, so remapped motions (e.g. flash.nvim taking
    -- over f/t/F/T) would otherwise be invisible here.
    if typed == nil or typed == '' then return end

    -- Operator (d/c) waiting for its motion.
    if S.pending_op then
      local p = S.pending_op
      if typed == KEY_ESC or typed == '\x03' or typed:byte(1) == 0x80 then
        S.pending_op = nil
        return
      end
      p.keys = p.keys .. typed
      local st = edit.op_status(p.op, p.keys)
      if st == 'cancel' then
        S.pending_op = nil
      elseif st == 'done' then
        S.pending_op = nil
        local op, keys = p.op, p.keys
        vim.schedule(function() if S.active then edit.apply_operator(op, keys) end end)
      end
      return ''  -- suppress: apply_operator handles main cursor + fakes
    end

    -- Capture the 2nd key of f/t/F/T before any mode check, since Neovim
    -- may report a special blocking state while collecting the char.
    if S.pending_motion then
      local mk, tc = S.pending_motion, typed
      S.pending_motion = nil
      if tc == KEY_ESC or tc == '\x03' or tc:byte(1) == 0x80 then return end
      S.last_ft = { mk = mk, tc = tc }
      vim.schedule(function()
        if not S.active then return end
        if S.extend then
          edit.apply_extend_ft(mk, tc)
        else
          regions.collapse_word_mode()
          edit.apply_ftFT(mk, tc)
        end
      end)
      return
    end

    -- Visual extend mode is handled by real buffer-local mappings (see
    -- edit.install_extend_maps), not here: on_key can observe the same
    -- keypress twice when another plugin (e.g. which-key) captures and
    -- re-feeds the first key typed after entering visual mode.
    if mode == 'n' then
      if handlers.handle_normal_key(typed) then return '' end
    end
  end, NS)

  -- Keymaps
  local km = vim.tbl_extend('force', {
    add_next    = '<M-n>',
    add_prev    = '<M-N>',
    skip_next   = '<M-x>',
    cursor_up   = '<M-Up>',
    cursor_down = '<M-Down>',
    select_all  = '<M-A>',
    remove_last = '<M-X>',
  }, opts.keymaps or {})

  local set = vim.keymap.set
  local no  = { noremap = true, silent = true }

  set({ 'n', 'x' }, km.add_next,    M.add_next,
    vim.tbl_extend('force', no, { desc = 'MultiCursor: find under / add next occurrence' }))
  set({ 'n', 'x' }, km.add_prev,    M.add_prev,
    vim.tbl_extend('force', no, { desc = 'MultiCursor: find under / add prev occurrence' }))
  set('n', km.skip_next,   M.skip_next,
    vim.tbl_extend('force', no, { desc = 'MultiCursor: skip current region, go to next' }))
  set({ 'n', 'x' }, km.select_all, M.select_all,
    vim.tbl_extend('force', no, { desc = 'MultiCursor: select all occurrences' }))
  set('n', km.cursor_up,   function() M.add_vertical(-1) end,
    vim.tbl_extend('force', no, { desc = 'MultiCursor: add cursor above' }))
  set('n', km.cursor_down, function() M.add_vertical(1) end,
    vim.tbl_extend('force', no, { desc = 'MultiCursor: add cursor below' }))
  set('n', km.remove_last, M.remove_last,
    vim.tbl_extend('force', no, { desc = 'MultiCursor: remove current region, go back' }))
end

return M
