local M = {}

M.defaults = {
	-- Live stats window shown while typing.
	live_stats = true,
	show_wpm = true,
	show_accuracy = true,
	show_progress = true,
	show_timer = true,
	-- Summary window shown when the test is completed.
	show_results = true,
	-- Dim buffer text that is not part of the test.
	dim_outside = true,
	-- How far dimmed text fades into the background: 0 = not at all, 1 = invisible.
	dim_amount = 0.85,
	-- Indentation is filled in automatically; you only type the code.
	skip_leading_whitespace = true,
	trim_trailing_whitespace = true,
	-- Comments are shown (faded) but not typed.
	skip_comments = true,
	-- A pause between two keys counts as at most this many seconds, so a
	-- break mid-test does not drag down WPM. false to count every pause.
	idle_timeout = 5,
	hud = {
		-- "top_right" | "top_left" | "bottom_right" | "bottom_left"
		position = "top_right",
	},
	-- :TypistDiff, typing over the lines changed in git.
	diff = {
		-- What to diff against: "index" (unstaged changes, where an agent's
		-- edits usually are) or any revision, e.g. "HEAD" or "main".
		base = "index",
		-- Show the lines a hunk replaced, faded, above it.
		show_deleted = true,
		max_deleted = 8,
		-- In an edited line, only type the words that changed; the rest is
		-- shown as already typed.
		changed_text_only = true,
		-- Skip the current hunk without typing it.
		skip_keys = { "<C-n>" },
	},
	-- Characters drawn at the end of a line where <CR> is expected.
	newline_symbol = "⏎",
	-- Per-group overrides, e.g. { TypistGhost = { fg = "#555555" } }.
	highlights = {},
}

M.options = vim.deepcopy(M.defaults)

-- Boolean options that :TypistOption can flip at runtime.
M.toggleable = {
	"live_stats",
	"show_wpm",
	"show_accuracy",
	"show_progress",
	"show_timer",
	"show_results",
	"dim_outside",
	"skip_leading_whitespace",
	"trim_trailing_whitespace",
	"skip_comments",
	"diff.show_deleted",
	"diff.changed_text_only",
}

-- Read or write a dotted option name such as "diff.show_deleted".
function M.get(name)
	local value = M.options
	for part in name:gmatch("[^.]+") do
		value = value[part]
	end
	return value
end

function M.set(name, value)
	local parts = vim.split(name, ".", { plain = true })
	local tbl = M.options
	for i = 1, #parts - 1 do
		tbl = tbl[parts[i]]
	end
	tbl[parts[#parts]] = value
end

function M.setup(opts)
	vim.validate("opts", opts, "table", true)
	if opts and opts.diff then
		vim.validate("diff", opts.diff, "table")
		vim.validate("diff.skip_keys", opts.diff.skip_keys, "table", true)
	end
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	-- Lists replace rather than merge.
	if opts and opts.diff and opts.diff.skip_keys then
		M.options.diff.skip_keys = opts.diff.skip_keys
	end
end

return M
