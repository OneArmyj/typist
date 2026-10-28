-- Draws a session on top of the buffer with extmarks. The buffer text itself
-- is never modified.
local engine = require("typist.engine")

local M = {}

M.ns = vim.api.nvim_create_namespace("typist")
local cursor_ns = vim.api.nvim_create_namespace("typist_cursor")

-- Above treesitter (100) and semantic tokens (125-127).
local PRIORITY = 10000

local function mark(buf, ns, row, col, opts)
	opts.priority = opts.priority or PRIORITY
	opts.strict = false
	return vim.api.nvim_buf_set_extmark(buf, ns, row, col, opts)
end

-- Dim every part of the buffer that is not covered by a target. Only the gaps
-- between targets are visited, so cost is independent of buffer size.
local function dim_outside(buf, targets)
	local sorted = {}
	for i, t in ipairs(targets) do
		sorted[i] = t
	end
	table.sort(sorted, function(a, b)
		return a.row < b.row
	end)
	local function dim_rows(first, last)
		if first <= last then
			mark(buf, M.ns, first, 0, {
				end_row = last + 1,
				end_col = 0,
				hl_group = "TypistDim",
				hl_eol = true,
				number_hl_group = "TypistDimNr",
			})
		end
	end
	local next_row = 0
	for _, t in ipairs(sorted) do
		dim_rows(next_row, t.row - 1)
		if t.col > 0 then
			mark(buf, M.ns, t.row, 0, { end_col = t.col, hl_group = "TypistDim" })
		end
		-- end_row/end_col = 0 of the next line covers the rest of this one, whatever its length.
		mark(buf, M.ns, t.row, t.col + #t.text, { end_row = t.row + 1, end_col = 0, hl_group = "TypistDim" })
		next_row = math.max(next_row, t.row + 1)
	end
	dim_rows(next_row, vim.api.nvim_buf_line_count(buf) - 1)
end

-- Highlight a line's typed characters, one mark per run of the same group.
-- `group_of(ci)` gives the group for character `ci`, or nil for none.
-- Skipped characters are left alone.
local function paint(buf, line, group_of, ids)
	local run_group, run_start, run_end
	local function flush()
		if run_group then
			table.insert(ids, mark(buf, M.ns, line.row, run_start, { end_col = run_end, hl_group = run_group }))
		end
		run_group = nil
	end
	for ci = line.start, line.last do
		local ch = line.chars[ci]
		local group = not ch.skip and group_of(ci) or nil
		if group ~= run_group then
			flush()
			run_group, run_start = group, ch.col
		end
		run_end = ch.col + #ch.ch
	end
	flush()
	return ids
end

local function ghost()
	return "TypistGhost"
end

-- Ghost text over a whole round that is not being typed right now.
local function draw_pending(view, state)
	local ids = {}
	for _, line in ipairs(state.lines) do
		paint(view.buf, line, ghost, ids)
	end
	return ids
end

local function delete_marks(buf, ids)
	for _, id in ipairs(ids or {}) do
		pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, id)
	end
end

-- Show removed lines as struck-through virtual lines above `row`, or below
-- the last line when they were removed from the end of the file.
local function draw_deleted(view, row, deleted, ids)
	local max = view.opts.diff.max_deleted
	local tabstop = vim.bo[view.buf].tabstop
	local virt_lines = {}
	for i, text in ipairs(deleted) do
		if i > max then
			table.insert(virt_lines, { { ("… %d more removed"):format(#deleted - max), "TypistDim" } })
			break
		end
		-- Virtual text does not expand tabs.
		text = text:gsub("\t", string.rep(" ", tabstop))
		table.insert(virt_lines, { { text == "" and " " or text, "TypistDeleted" } })
	end
	if #virt_lines > 0 then
		local last = vim.api.nvim_buf_line_count(view.buf) - 1
		local above = row <= last
		table.insert(
			ids,
			mark(view.buf, M.ns, math.min(row, last), 0, { virt_lines = virt_lines, virt_lines_above = above })
		)
	end
end

---Set up the overlay for a session: dim everything outside the session's
---rounds and show every round as ghost text until it is typed.
---@param rounds typist.Round[] every round shown in this session
---@param removed? { row: integer, lines: string[] }[] deletions with nothing
---to type (diff mode), shown above 0-based `row` for the whole session
function M.open(win, opts, rounds, removed)
	local buf = vim.api.nvim_win_get_buf(win)
	local view = { win = win, buf = buf, opts = opts, line_marks = {}, round_marks = {}, pending = {} }
	-- Keep the overlay to the session window when the buffer is shown in other splits.
	if vim.api.nvim__ns_set then
		pcall(vim.api.nvim__ns_set, M.ns, { wins = { win } })
		pcall(vim.api.nvim__ns_set, cursor_ns, { wins = { win } })
	end
	if opts.dim_outside then
		local targets = {}
		for _, round in ipairs(rounds) do
			vim.list_extend(targets, round.targets)
		end
		dim_outside(buf, targets)
	end
	for _, round in ipairs(rounds) do
		view.pending[round] = draw_pending(view, round.state)
	end
	for _, r in ipairs(removed or {}) do
		draw_deleted(view, r.row, r.lines, {})
	end
	for _, round in ipairs(rounds) do
		for _, t in ipairs(round.targets) do
			-- Ranges with a group (comments) look the same for the whole session.
			for _, range in ipairs(t.skip or {}) do
				if range[3] then
					mark(
						buf,
						M.ns,
						t.row,
						range[1],
						{ end_col = math.min(range[2], t.col + #t.text), hl_group = range[3] }
					)
				end
			end
		end
	end
	return view
end

---Make `round` the one being typed.
---@param round typist.Round
function M.begin_round(view, round)
	delete_marks(view.buf, view.pending[round])
	view.pending[round] = nil
	for _, t in ipairs(round.targets) do
		-- Faint band behind the lines being typed, so the active block stands out.
		-- A low-priority range (not line_hl_group) so the cursor and error
		-- backgrounds still draw on top of it.
		local band = { end_row = t.row + 1, end_col = 0, hl_group = "TypistFocus", hl_eol = true, priority = 50 }
		table.insert(view.round_marks, mark(view.buf, M.ns, t.row, 0, band))
	end
	if round.deleted then
		draw_deleted(view, round.targets[1].row, round.deleted, view.round_marks)
	end
	for li = 1, #round.state.lines do
		M.draw_line(view, round.state, li)
	end
	M.draw_cursor(view, round.state)
end

---Leave `round`. A finished round keeps its real colors; an unfinished one
---(skipped or stopped) goes back to ghost text.
function M.end_round(view, round)
	delete_marks(view.buf, view.round_marks)
	for _, ids in pairs(view.line_marks) do
		delete_marks(view.buf, ids)
	end
	view.round_marks, view.line_marks = {}, {}
	vim.api.nvim_buf_clear_namespace(view.buf, cursor_ns, 0, -1)
	if not round.state.done then
		view.pending[round] = draw_pending(view, round.state)
	end
end

-- Re-render one target line: ghost for untyped, nothing for correct, red for wrong.
function M.draw_line(view, state, li)
	local buf = view.buf
	delete_marks(buf, view.line_marks[li])
	local ids = {}
	view.line_marks[li] = ids

	local status = state.lines[li].status
	paint(buf, state.lines[li], function(ci)
		return (status[ci] == nil and "TypistGhost") or (status[ci] == "wrong" and "TypistError") or nil
	end, ids)
end

function M.draw_cursor(view, state)
	vim.api.nvim_buf_clear_namespace(view.buf, cursor_ns, 0, -1)
	if state.done then
		return
	end
	local line = state.lines[state.li]
	local ch = line.chars[state.ci]
	local col, opts
	local at_newline = engine.at_newline(state)
	if at_newline or not ch then
		-- <CR> is expected, or a wrong final key left the cursor past the line.
		local symbol = at_newline and { view.opts.newline_symbol, "TypistNewline" } or { " ", "TypistCursor" }
		if state.missed then
			-- The last key was wrong but there is no character to mark red.
			symbol[2] = "TypistError"
		end
		col, opts = line.eol_col, { virt_text = { symbol }, virt_text_pos = "inline" }
	else
		local group = state.missed and "TypistError" or "TypistCursor"
		col, opts = ch.col, { end_col = ch.col + #ch.ch, hl_group = group }
	end
	opts.priority = PRIORITY + 1
	mark(view.buf, cursor_ns, line.row, col, opts)
	pcall(vim.api.nvim_win_set_cursor, view.win, { line.row + 1, col })
end

function M.update(view, state, changed)
	local seen = {}
	for _, li in ipairs(changed) do
		if not seen[li] and state.lines[li] then
			seen[li] = true
			M.draw_line(view, state, li)
		end
	end
	M.draw_cursor(view, state)
end

---Remove everything typist drew in `buf`.
function M.clear(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
		vim.api.nvim_buf_clear_namespace(buf, cursor_ns, 0, -1)
	end
end

return M
