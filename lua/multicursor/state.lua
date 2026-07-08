local api = vim.api

local M = {}

M.NS = api.nvim_create_namespace('mc')

M.KEY_ESC = '\27'
M.KEY_BS  = api.nvim_replace_termcodes('<BS>',  true, true, true)
M.KEY_DEL = api.nvim_replace_termcodes('<Del>', true, true, true)

M.S = {
  cursors        = {},
  active         = false,
  in_apply       = false,
  word           = nil,
  word_len       = 0,
  whole_word     = true,
  cur_row        = nil,
  cur_col        = nil,
  cur_hl_id      = nil,
  cur_hl_buf     = nil,
  pending_motion = nil,
  pending_op     = nil,
  last_ft        = nil,
  extend         = false,
  extend_op      = nil,
  esc_mapped     = false,
  saved_esc      = nil,
  deactivate_fn  = nil,  -- injected by init.lua after M.deactivate is defined
}

return M
