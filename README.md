# multicursor.nvim

Multi-cursor editing for Neovim, written in pure Lua. Inspired by vim-visual-multi's workflow.

## Features

- Select word under cursor or visual selection, then add next/prev occurrences
- Select all occurrences at once
- Add cursors above/below vertically
- Insert, delete, and change at all cursors simultaneously
- Visual extend mode — grow selections with motions
- Operators: `d`, `c`, `x`, `s`, `D`, `C`, `f`/`t`/`F`/`T`, `;`, `,`
- Single undo entry for all cursors combined

## Requirements

Neovim 0.9+

## Installation

### lazy.nvim

```lua
{
  "higorhgon/multicursor-nvim",
  config = function()
    require("multicursor").setup()
  end,
}
```

### manual (vim.pack — Neovim 0.12+)

```lua
vim.pack.add("higorhgon/multicursor-nvim")
require("multicursor").setup()
```

## Configuration

Call `setup()` once, optionally overriding the default keymaps:

```lua
require("multicursor").setup({
  keymaps = {
    add_next    = "<M-n>",   -- select word / add next occurrence
    add_prev    = "<M-N>",   -- select word / add prev occurrence
    skip_next   = "<M-x>",   -- skip current, jump to next occurrence
    select_all  = "<M-A>",   -- select all occurrences at once
    cursor_up   = "<M-Up>",  -- add cursor on the line above
    cursor_down = "<M-Down>",-- add cursor on the line below
    remove_last = "<M-X>",   -- remove current region / go back
  },
})
```

All keys above are the defaults. Pass only the ones you want to override.

## Usage

### Selecting occurrences

| Key | Action |
|-----|--------|
| `<M-n>` | First press: select word under cursor (or current visual selection). Each next press freezes the current region and moves to the next occurrence. |
| `<M-N>` | Same as above but towards the previous occurrence. |
| `<M-A>` | Select every occurrence in the buffer at once. |
| `<M-x>` | Skip the current occurrence and jump to the next. |
| `<M-X>` | Remove the most recently added cursor / go back one. |
| `<Esc>` | Exit multicursor mode. |

### Vertical cursors

| Key | Action |
|-----|--------|
| `<M-Down>` | Add a cursor on the line below. |
| `<M-Up>` | Add a cursor on the line above. |

### Editing (active in multicursor mode)

All standard motions and editing keys work across every cursor simultaneously.

**Normal mode:**

| Key | Action |
|-----|--------|
| `i` / `a` / `I` / `A` | Enter insert mode at all cursors |
| `d` | Delete selected word / `d<motion>` in point mode |
| `c` / `s` | Delete selected word and enter insert mode |
| `x` / `X` | Delete char at / before each cursor |
| `D` / `C` | Delete to end of line at each cursor |
| `w` `b` `e` `h` `j` `k` `l` `0` `$` `^` `_` | Move all cursors |
| `f` `t` `F` `T` `;` `,` | Character search across all cursors |
| `v` | Enter visual extend mode |

**Insert mode:**

Characters typed, `<BS>`, `<Del>`, and `<Enter>` are mirrored to all cursors.

**Visual extend mode (`v`):**

All motions grow or shrink each cursor's selection. `d`/`x`/`c`/`s` delete the selections; `y` collapses them to the start.

## How it works

The plugin uses `vim.on_key` to intercept keypresses and mirror them to fake cursors rendered as extmarks. All edits belonging to one multicursor operation are joined into a single undo entry, so a single `u` undoes the entire operation across all cursors.
