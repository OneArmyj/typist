# typist.nvim

Type your own code as a typing test, right in the buffer. Select some code, or point typist at your git changes, and retype it over its ghost text. You practise typing and review every changed line as you go.

```
local M = {}                                  62 wpm  ·  97% acc  ·  0:14  ·  18/49  ·  hunk 2/3
-- Compute the fibonacci number for n.
function M.fib(n)
    if n < 2 then                <- replaced lines, struck through
      return n
  local a, b = 0, 1              <- typed: back to normal syntax colors
  for _ = 1, n|do                <- cursor; the rest is still ghost text
    a, b = b, a + b
  end
```

## Features

- **In place.** You type over the real code. The buffer is never modified.
- **Git diff mode.** Type each hunk from the one nearest your cursor down to the end of the file. Replaced and deleted lines show struck through.
- **Only what changed.** In an edited line you type just the changed words.
- **Code, not comments.** Comments are shown faded and skipped.
- **Stats.** Live WPM, accuracy and timer, plus a results card at the end.
- **Theme-aware.** Colors are derived from your colorscheme.
- **Lightweight.** No dependencies, about 0.05 ms at startup.

## Requirements

- Neovim 0.11+
- `git`, for `:TypistDiff` only
- `'termguicolors'` recommended (falls back to 256 colors without it)

Run `:checkhealth typist` to check.

## Installation

```lua
-- vim.pack (Neovim 0.12+)
vim.pack.add({ "https://github.com/OneArmyj/typist.nvim" })

-- lazy.nvim
{
  "OneArmyj/typist.nvim",
  cmd = { "Typist", "TypistDiff", "TypistResults", "TypistOption" },
  keys = {
    { "<leader>ty", "<Plug>(typist-visual)", mode = "x", desc = "Typist: selection" },
    { "<leader>tY", "<Plug>(typist-buffer)", desc = "Typist: whole buffer" },
    { "<leader>td", "<Plug>(typist-diff)", desc = "Typist: git changes" },
    { "<leader>tr", "<cmd>TypistResults<cr>", desc = "Typist: last results" },
  },
}
```

`setup()` is optional. Typist creates no mappings; map the `<Plug>` keys above yourself.

## Usage

| Command | Description |
| --- | --- |
| `:[range]Typist` | Type the selection or `[range]` (default: the whole buffer). |
| `:TypistDiff [base]` | Type the git changes, hunk by hunk. |
| `:TypistResults` | Show the last results card. |
| `:TypistOption {name} [on\|off]` | Toggle an option, e.g. `:TypistOption skip_comments off`. |

`:TypistDiff` compares against the git index by default, i.e. unstaged changes and unsaved edits, which is where an agent's edits usually are. Pass a revision to compare against that instead, e.g. `:TypistDiff HEAD` or `:TypistDiff main`. Hunks above your cursor are skipped, so press `gg` first to type them all.

| Key | Action |
| --- | --- |
| any character | Type it. A mistake turns red and the cursor moves on. |
| `<BS>` / `<C-w>` | Delete the previous character / word. |
| `<CR>` | Next line (indentation is filled in). |
| `<C-n>` | Skip the current hunk. |
| `<Esc>` / `<C-c>` | Stop. These are the only keys that end a test. |

A test only finishes once its last character is correct.

## Configuration

The defaults:

```lua
require("typist").setup({
  live_stats = true,
  show_wpm = true,
  show_accuracy = true,
  show_timer = true,
  show_progress = true,
  show_results = true,
  dim_outside = true,
  dim_amount = 0.85,              -- 0 = no fade, 1 = invisible
  skip_leading_whitespace = true,
  trim_trailing_whitespace = true,
  skip_comments = true,
  idle_timeout = 5,               -- longest pause counted, in seconds (false = no limit)
  hud = { position = "top_right" },
  newline_symbol = "⏎",
  diff = {
    base = "index",               -- or a revision: "HEAD", "main", ...
    show_deleted = true,
    max_deleted = 8,
    changed_text_only = true,     -- type only the changed words of edited lines
    skip_keys = { "<C-n>" },
  },
  highlights = {},                -- e.g. { TypistCursor = { fg = "#1e1e2e", bg = "#89dceb" } }
})
```

Override colors through `highlights`. A plain `:highlight` is lost on the next `ColorScheme`. See `:h typist-highlights` for the group names.

## Stats

| Stat | Definition |
| --- | --- |
| WPM | (correct characters ÷ 5) per minute. `<CR>` counts as a character. |
| Raw | (all keystrokes ÷ 5) per minute, including mistakes. |
| Accuracy | Correct keystrokes ÷ all keystrokes. Fixed mistakes still count. |
| Time | First to last keystroke. Time between hunks is not counted, and a pause counts as at most `idle_timeout` seconds. |

Auto-filled indentation, skipped comments and unchanged text don't count towards any stat.

## Lua API

```lua
local typist = require("typist")
typist.start({ line1 = 10, line2 = 20 })
typist.start_visual()
typist.start_diff({ base = "HEAD" })
typist.stop()
typist.show_last()
typist.set_option("skip_comments", false)
```

`start*()` return the result (also kept in `typist.last`), or `nil` if no test started. See `:h typist-api`.

## Development

```sh
nvim --headless --clean -l tests/run.lua   # tests (need git)
stylua --check .
```

## License

[MIT](LICENSE)
