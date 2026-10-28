-- Live stats pill and the end-of-test results card.
local M = {}

local hud_ns = vim.api.nvim_create_namespace("typist_hud")

local function format_time(seconds)
	seconds = math.floor(seconds)
	return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

-- Build `{ text, hl_ranges }` from a list of `{ str, group }` chunks.
local function compose(chunks)
	local text, ranges = "", {}
	for _, chunk in ipairs(chunks) do
		local start = #text
		text = text .. chunk[1]
		if chunk[2] then
			table.insert(ranges, { chunk[2], start, #text })
		end
	end
	return text, ranges
end

local function paint(buf, lines)
	local texts = {}
	for i, chunks in ipairs(lines) do
		local text, ranges = compose(chunks)
		texts[i] = { text, ranges }
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(
		buf,
		0,
		-1,
		false,
		vim.tbl_map(function(t)
			return t[1]
		end, texts)
	)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, hud_ns, 0, -1)
	for row, t in ipairs(texts) do
		for _, r in ipairs(t[2]) do
			vim.api.nvim_buf_set_extmark(buf, hud_ns, row - 1, r[2], { end_col = r[3], hl_group = r[1] })
		end
	end
	return vim.tbl_map(function(t)
		return vim.fn.strdisplaywidth(t[1])
	end, texts)
end

local function scratch()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	return buf
end

local function live_chunks(stats, opts, round, label)
	local sep = { "  ·  ", "TypistHudSep" }
	local parts = {}
	local function add(value, unit)
		if #parts > 0 then
			table.insert(parts, sep)
		end
		table.insert(parts, { value, "TypistHudValue" })
		if unit then
			table.insert(parts, { " " .. unit, "TypistHudLabel" })
		end
	end
	if opts.show_wpm then
		-- WPM is noise until there is at least a second of data.
		add(stats.elapsed >= 1 and ("%d"):format(stats.wpm + 0.5) or "–", "wpm")
	end
	if opts.show_accuracy then
		add(("%d%%"):format(stats.accuracy + 0.5), "acc")
	end
	if opts.show_timer then
		add(format_time(stats.elapsed))
	end
	if opts.show_progress then
		add(("%d/%d"):format(round.typed, round.total))
	end
	if label then
		add(label)
	end
	table.insert(parts, 1, { " ", "TypistHud" })
	table.insert(parts, { " ", "TypistHud" })
	return parts
end

local function anchor(win, position, width, height)
	local win_width = vim.api.nvim_win_get_width(win)
	local win_height = vim.api.nvim_win_get_height(win)
	local row = position:find("bottom") and (win_height - height - 1) or 0
	local col = position:find("left") and 1 or math.max(win_width - width - 2, 0)
	return row, col
end

---@return table|nil hud handle
function M.open(win, opts)
	if not opts.live_stats then
		return nil
	end
	local hud = { parent = win, buf = scratch(), opts = opts }
	hud.win = vim.api.nvim_open_win(hud.buf, false, {
		relative = "win",
		win = win,
		row = 0,
		col = 0,
		width = 1,
		height = 1,
		style = "minimal",
		focusable = false,
		zindex = 60,
		noautocmd = true,
	})
	vim.wo[hud.win].winhighlight = "Normal:TypistHud,NormalFloat:TypistHud"
	return hud
end

---@param stats table cumulative stats for the session (speed, accuracy, time)
---@param round table stats for the current round (progress)
---@param label? string e.g. "hunk 2/5"
function M.update(hud, stats, round, label)
	if not hud or not vim.api.nvim_win_is_valid(hud.win) then
		return
	end
	local width = math.max(paint(hud.buf, { live_chunks(stats, hud.opts, round, label) })[1], 1)
	-- Only move the window when its size actually changes.
	if width ~= hud.width then
		hud.width = width
		local row, col = anchor(hud.parent, hud.opts.hud.position, width, 1)
		vim.api.nvim_win_set_config(
			hud.win,
			{ relative = "win", win = hud.parent, row = row, col = col, width = width, height = 1 }
		)
	end
end

function M.close(hud)
	if hud and vim.api.nvim_win_is_valid(hud.win) then
		vim.api.nvim_win_close(hud.win, true)
	end
end

---Show the summary card. Closes on the next keypress.
---@param result { stats: table, completed: boolean, title?: string, rounds?: { finished: integer, total: integer } }
function M.results(win, result)
	local stats, completed, title = result.stats, result.completed, result.title
	local acc_group = stats.accuracy >= 95 and "TypistResultGood"
		or (stats.accuracy < 80 and "TypistResultBad" or "TypistResultValue")
	local function row(label, value, group)
		return { { ("  %-9s"):format(label), "TypistHudLabel" }, { value, group or "TypistResultValue" } }
	end
	local opts = require("typist.config").options
	local lines = { {} }
	if opts.show_wpm then
		vim.list_extend(lines, {
			{ { "  ", nil }, { ("%d"):format(stats.wpm + 0.5), "TypistResultTitle" }, { " wpm", "TypistHudLabel" } },
			{},
		})
	end
	if opts.show_accuracy then
		table.insert(lines, row("accuracy", ("%.1f%%"):format(stats.accuracy), acc_group))
	end
	if opts.show_wpm then
		table.insert(lines, row("raw", ("%d wpm"):format(stats.raw_wpm + 0.5)))
	end
	vim.list_extend(lines, {
		row("time", format_time(stats.elapsed)),
		row("errors", tostring(stats.errors), stats.errors > 0 and "TypistResultBad" or "TypistResultGood"),
		row("chars", ("%d/%d"):format(stats.typed, stats.total)),
	})
	if result.rounds then
		table.insert(lines, row("hunks", ("%d/%d"):format(result.rounds.finished, result.rounds.total)))
	end
	vim.list_extend(lines, { {}, { { "  press any key", "TypistHudSep" } } })
	local buf = scratch()
	local widths = paint(buf, lines)
	local width = math.max(unpack(widths)) + 4
	local height = #lines
	local float = vim.api.nvim_open_win(buf, false, {
		relative = "win",
		win = win,
		row = math.max(math.floor((vim.api.nvim_win_get_height(win) - height) / 2) - 1, 0),
		col = math.max(math.floor((vim.api.nvim_win_get_width(win) - width) / 2), 0),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = {
			{
				(" typist%s%s "):format(title and (" · " .. title) or "", completed and "" or " · stopped"),
				"TypistResultTitle",
			},
		},
		title_pos = "center",
		focusable = false,
		zindex = 70,
		noautocmd = true,
	})
	vim.wo[float].winhighlight =
		"Normal:TypistResult,NormalFloat:TypistResult,FloatBorder:TypistResultBorder,FloatTitle:TypistResultTitle"
	vim.cmd.redraw()
	-- Keys still in flight from typing the last character must not close the card.
	local opened = vim.uv.hrtime()
	repeat
		local ok = pcall(vim.fn.getcharstr, -1, { cursor = "hide" })
	until not ok or (vim.uv.hrtime() - opened) / 1e6 >= 400
	if vim.api.nvim_win_is_valid(float) then
		vim.api.nvim_win_close(float, true)
	end
end

return M
