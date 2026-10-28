local config = require("typist.config")
local engine = require("typist.engine")
local highlights = require("typist.highlights")
local hud = require("typist.hud")
local render = require("typist.render")

local M = {}

local ESC = "\27"
-- The only keys that end a session. Everything else is typing input.
local STOP_KEYS = { [ESC] = true, ["\3"] = true }
local CTRL_W = "\23"
local CTRL_H = "\8"
local BS = vim.keycode("<BS>")
local KEYPAD_ENTER = vim.keycode("<kEnter>")

local active = false
local stop_requested = false
local initialized = false

local function ensure_setup()
	if not initialized then
		initialized = true
		highlights.setup()
	end
end

function M.setup(opts)
	config.setup(opts)
	if initialized then
		highlights.apply()
	end
	ensure_setup()
end

-- Turn getregionpos() output into engine targets.
local function targets_from_region(buf, region)
	local targets = {}
	for _, segment in ipairs(region) do
		local first, last = segment[1], segment[2]
		local row = first[2] - 1
		local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
		if first[3] > 0 then
			local stop = math.min(last[3], #line)
			table.insert(targets, { row = row, col = first[3] - 1, text = line:sub(first[3], stop) })
		else
			table.insert(targets, { row = row, col = 0, text = "" })
		end
	end
	return targets
end

local function targets_from_lines(buf, line1, line2)
	local targets = {}
	local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
	for i, text in ipairs(lines) do
		table.insert(targets, { row = line1 - 2 + i, col = 0, text = text })
	end
	return targets
end

-- Add `ranges` (`{ start, end }`) to `target.skip`, drawn with `group`.
local function add_skip(target, ranges, group)
	for _, range in ipairs(ranges or {}) do
		target.skip = target.skip or {}
		table.insert(target.skip, { range[1], range[2], group })
	end
end

-- Mark the comments in `targets` (sorted by row) as not typed, if enabled.
local function skip_comments(buf, targets)
	if not config.options.skip_comments or #targets == 0 then
		return
	end
	local by_row = require("typist.comments").ranges(buf, targets[1].row, targets[#targets].row)
	for _, t in ipairs(targets) do
		add_skip(t, by_row[t.row], "TypistSkipped")
	end
end

-- Read keys until the round is complete or abandoned. `on_change` runs after
-- every key that changed the round. Returns false if the user stopped the
-- session, true if the round was finished or skipped.
local function run_loop(state, view, keys, on_change)
	while not state.done do
		vim.cmd.redraw()
		-- Hide the editor cursor; the TypistCursor block is the only cursor shown.
		local ok, key = pcall(vim.fn.getcharstr, -1, { cursor = "hide" })
		if not ok or stop_requested or STOP_KEYS[key] then
			return false
		end
		if keys.skip[key] then
			return true
		end
		local changed
		if key == BS or key == CTRL_H then
			changed = engine.backspace(state)
		elseif key == CTRL_W then
			changed = engine.backspace_word(state)
		elseif key == "\r" or key == "\n" or key == KEYPAD_ENTER then
			changed = engine.type(state, "\n")
		elseif key:byte(1) ~= 0x80 and (key == "\t" or key:byte(1) >= 0x20) then
			changed = engine.type(state, key)
		end
		if changed then
			render.update(view, state, changed)
			on_change()
		end
	end
	return true
end

local function keyset(list)
	local set = {}
	for _, key in ipairs(list or {}) do
		set[vim.keycode(key)] = true
	end
	return set
end

-- Window-local options changed during a session. Only the local values are
-- touched, so the user's global settings are never overwritten.
local WINDOW_OPTIONS = {
	-- Cursor must be able to rest one past the last character while <CR> is expected.
	virtualedit = "onemore",
	cursorline = false,
	-- Every character being typed must be on screen: no closed folds, and
	-- no concealed text (markdown, json, help).
	foldenable = false,
	conceallevel = 0,
}

-- Prepare the window for a session and return a function that restores it.
local function take_over(win, buf)
	local saved_view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
	local saved_wo = {}
	for name, value in pairs(WINDOW_OPTIONS) do
		saved_wo[name] = vim.api.nvim_get_option_value(name, { scope = "local", win = win })
		vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
	end
	-- Hide diagnostics and inlay hints so only the code itself is on screen.
	local diagnostics_on = vim.diagnostic.is_enabled({ bufnr = buf })
	local hints_on = vim.lsp.inlay_hint.is_enabled({ bufnr = buf })
	if diagnostics_on then
		vim.diagnostic.enable(false, { bufnr = buf })
	end
	if hints_on then
		vim.lsp.inlay_hint.enable(false, { bufnr = buf })
	end
	return function(restore_view)
		if vim.api.nvim_win_is_valid(win) then
			for name, value in pairs(saved_wo) do
				vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
			end
			if restore_view then
				vim.api.nvim_win_call(win, function()
					vim.fn.winrestview(saved_view)
				end)
			end
		end
		if vim.api.nvim_buf_is_valid(buf) then
			if diagnostics_on then
				vim.diagnostic.enable(true, { bufnr = buf })
			end
			if hints_on then
				vim.lsp.inlay_hint.enable(true, { bufnr = buf })
			end
		end
	end
end

-- First and last buffer line (1-based) covered by `targets`, in order.
local function span(targets)
	return targets[1].row + 1, targets[#targets].row + 1
end

-- Scroll so the round's lines, and the `padding` replaced lines drawn above
-- its first line, are in view.
local function reveal(win, targets, padding)
	local first, last = span(targets)
	vim.api.nvim_win_call(win, function()
		local top, bottom = vim.fn.line("w0"), vim.fn.line("w$")
		-- The replaced lines sit between line `first - 1` and `first`. They are
		-- visible if a line above `first` is on screen, or as filler at the top.
		local replaced_visible = padding == 0 or top < first or vim.fn.winsaveview().topfill >= padding
		if top <= first and last <= bottom and replaced_visible then
			return
		end
		-- Center the block, but keep its first line on screen if it is taller than the window.
		local height = vim.api.nvim_win_get_height(0)
		local wanted = math.floor((first + last) / 2 - height / 2) + 1
		wanted = math.max(1, math.min(wanted, first - 1))
		if padding > 0 and wanted >= first - 1 then
			-- Not enough room above (e.g. the hunk starts at line 1): show the
			-- replaced lines as filler above the first line.
			vim.fn.winrestview({ topline = first, topfill = padding })
		else
			vim.fn.winrestview({ topline = math.min(wanted, first), topfill = 0 })
		end
	end)
end

-- One stretch of a buffer line to type. `row` and `col` are 0-based; `col`
-- is a byte offset.
---@class typist.Target
---@field row integer
---@field col integer
---@field text string
---@field skip? table[] byte ranges `{ start, end, group? }` shown but not typed,
---drawn with `group` if set

-- A round is one block of text typed in one go: the selection, or one hunk.
---@class typist.Round
---@field targets typist.Target[]
---@field state table engine state for the targets
---@field deleted? string[] lines the block replaced (diff mode)
---@field label? string shown in the live stats, e.g. "hunk 2/5"

local function new_round(targets, clock)
	local opts = config.options
	return {
		targets = targets,
		state = engine.new(targets, {
			skip_leading_whitespace = opts.skip_leading_whitespace,
			trim_trailing_whitespace = opts.trim_trailing_whitespace,
			idle_timeout = opts.idle_timeout,
			clock = clock,
		}),
	}
end

---Run `rounds` (all non-empty) one after another in `win`.
---@param rounds typist.Round[]
---@param session { diff?: boolean, context?: typist.Round[], removed?: table[], skip_keys?: string[] }
---`diff`: diff mode (cursor stays where you stopped, results count hunks).
---`context`: every round to show as ghost text (default: `rounds`).
---`removed`: deletions with nothing to type, see `render.open`.
local function run_session(win, rounds, session)
	local opts = config.options
	local buf = vim.api.nvim_win_get_buf(win)
	active = true
	stop_requested = false

	local states, live, timer, view, restore = {}, nil, nil, nil, nil
	---@type typist.Round
	local round = rounds[1]
	-- Speed and accuracy are for the whole session, progress for the current round.
	local function refresh_hud()
		hud.update(live, engine.summary(states), engine.stats(round.state), round.label)
	end
	local stopped = false
	local ok, err = pcall(function()
		local keys = { skip = keyset(session.skip_keys) }
		restore = take_over(win, buf)
		live = hud.open(win, opts)
		if live then
			timer = vim.uv.new_timer()
			timer:start(
				1000,
				1000,
				vim.schedule_wrap(function()
					if active and round.state.start_time and not round.state.done then
						refresh_hud()
						vim.cmd.redraw()
					end
				end)
			)
		end
		view = render.open(win, opts, session.context or rounds, session.removed)
		for _, r in ipairs(rounds) do
			round = r
			table.insert(states, r.state)
			reveal(win, r.targets, r.deleted and math.min(#r.deleted, opts.diff.max_deleted + 1) or 0)
			render.begin_round(view, r)
			refresh_hud()
			stopped = not run_loop(r.state, view, keys, refresh_hud)
			engine.freeze(r.state)
			render.end_round(view, r)
			if stopped then
				break
			end
		end
	end)

	if timer then
		timer:stop()
		timer:close()
	end
	pcall(hud.close, live)
	local finished = 0
	for _, state in ipairs(states) do
		finished = finished + (state.done and 1 or 0)
	end
	M.last = {
		stats = engine.summary(states),
		completed = ok and not stopped,
		title = session.diff and "diff" or nil,
		rounds = session.diff and { finished = finished, total = #rounds } or nil,
	}
	if ok and opts.show_results and M.last.stats.keystrokes > 0 then
		pcall(hud.results, win, M.last)
	end
	pcall(render.clear, buf)
	-- In diff mode the cursor stays where you stopped; otherwise jump back.
	if restore then
		pcall(restore, not session.diff)
	end
	active = false
	vim.cmd.redraw()

	if not ok then
		error(err, 0)
	end
	return M.last
end

-- Common checks before a session. Returns the window and buffer to use, or
-- nil if a session is already running.
local function prepare(spec)
	ensure_setup()
	if active then
		vim.notify("typist: a test is already running", vim.log.levels.WARN)
		return nil
	end
	local win = spec.win or vim.api.nvim_get_current_win()
	return win, vim.api.nvim_win_get_buf(win)
end

---Start a typing test. Returns the result (see `M.last`), or nil if no test
---was started.
---@param spec? { targets?: typist.Target[], line1?: integer, line2?: integer, region?: table, win?: integer, clock?: fun(): number }
function M.start(spec)
	spec = spec or {}
	local win, buf = prepare(spec)
	if not win then
		return
	end

	local targets = spec.targets
	if not targets then
		targets = spec.region and targets_from_region(buf, spec.region)
			or targets_from_lines(buf, spec.line1 or 1, spec.line2 or vim.api.nvim_buf_line_count(buf))
		skip_comments(buf, targets)
	end
	local round = new_round(targets, spec.clock)
	if round.state.done then
		vim.notify("typist: nothing to type in the selection", vim.log.levels.INFO)
		return
	end
	return run_session(win, { round }, {})
end

-- Index of the round nearest to buffer line `row` (1-based).
local function nearest_round(rounds, row)
	local spans = {}
	for i, round in ipairs(rounds) do
		local first, last = span(round.targets)
		spans[i] = { first = first, last = last }
	end
	return require("typist.git").nearest(spans, row)
end

---Type over the lines changed in git, hunk by hunk: from the hunk nearest
---the cursor down to the last one in the file. Every hunk is shown as ghost
---text; everything else is dimmed.
---Returns the result (see `M.last`), or nil if no test was started.
---@param spec? { base?: string, win?: integer, clock?: fun(): number }
function M.start_diff(spec)
	spec = spec or {}
	local win, buf = prepare(spec)
	if not win then
		return
	end
	local opts = config.options
	local base = spec.base or opts.diff.base

	local git = require("typist.git")
	local hunks, err = git.hunks(buf, base)
	if not hunks then
		vim.notify("typist: " .. err, vim.log.levels.WARN)
		return
	end
	-- `all`: hunks with something to type. `shown`: also those that are all
	-- comments, which are drawn but not visited.
	local all, shown, removed = {}, {}, {}
	for _, h in ipairs(hunks) do
		if h.last < h.first then
			-- Deletion only: nothing to type, but shown so every change is visible.
			if opts.diff.show_deleted then
				table.insert(removed, { row = h.first - 1, lines = h.deleted })
			end
		else
			local targets = targets_from_lines(buf, h.first, h.last)
			if opts.diff.changed_text_only then
				local added = vim.tbl_map(function(t)
					return t.text
				end, targets)
				for i, ranges in pairs(git.unchanged_parts(h.deleted, added)) do
					add_skip(targets[i], ranges)
				end
			end
			skip_comments(buf, targets)
			local round = new_round(targets, spec.clock)
			if opts.diff.show_deleted and #h.deleted > 0 then
				round.deleted = h.deleted
			end
			table.insert(shown, round)
			if not round.state.done then
				table.insert(all, round)
			end
		end
	end
	if #all == 0 then
		vim.notify(("typist: no changes to type (compared to %s)"):format(git.describe(base)), vim.log.levels.INFO)
		return
	end
	local rounds = vim.list_slice(all, nearest_round(all, vim.api.nvim_win_get_cursor(win)[1]))
	for i, round in ipairs(rounds) do
		round.label = ("hunk %d/%d"):format(i, #rounds)
	end
	return run_session(
		win,
		rounds,
		{ diff = true, context = shown, removed = removed, skip_keys = opts.diff.skip_keys }
	)
end

function M.is_active()
	return active
end

---Stop the running test from code (a timer or autocmd). While a test runs,
---every key is typing input, so users stop it with <Esc> or <C-c>.
function M.stop()
	if active then
		stop_requested = true
		-- Wake the blocking key read.
		vim.api.nvim_feedkeys(ESC, "n", false)
	end
end

---Start a test from the current visual selection (charwise, linewise or blockwise).
function M.start_visual()
	local mode = vim.fn.mode()
	if not mode:find("^[vV\22]") then
		vim.notify("typist: select some text first", vim.log.levels.INFO)
		return
	end
	local region = vim.fn.getregionpos(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
	vim.api.nvim_feedkeys(ESC, "nx", false)
	return M.start({ region = region })
end

---Flip (or set) a boolean option at runtime.
---@param name string
---@param value? boolean
function M.set_option(name, value)
	if not vim.tbl_contains(config.toggleable, name) then
		vim.notify("typist: unknown option " .. tostring(name), vim.log.levels.ERROR)
		return
	end
	if value == nil then
		value = not config.get(name)
	end
	config.set(name, value)
	vim.notify(("typist: %s = %s"):format(name, tostring(value)))
end

---Show the summary of the most recent test.
function M.show_last()
	if not M.last then
		vim.notify("typist: no test has been run yet")
		return
	end
	ensure_setup()
	hud.results(vim.api.nvim_get_current_win(), M.last)
end

---Entry point for :Typist. A `'<,'>` range from a charwise/blockwise visual
---selection keeps its exact columns; anything else is linewise.
function M.command(cmd)
	local vmode = vim.fn.visualmode()
	-- `cmd` does not say how the range was written, so check the command line:
	-- a typed `:1,3Typist` must not reuse the columns of an old selection.
	local from_visual = vim.startswith(vim.fn.histget("cmd", -1), "'<,'>")
	if cmd.range == 2 and from_visual and vmode ~= "" and vmode ~= "V" then
		local region = vim.fn.getregionpos(vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vmode })
		return M.start({ region = region })
	end
	return M.start({ line1 = cmd.line1, line2 = cmd.line2 })
end

return M
