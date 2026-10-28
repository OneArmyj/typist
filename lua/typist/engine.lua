-- Pure typing-test state machine. Knows nothing about windows or extmarks.
--
-- A session is built from "targets": one entry per buffer line to be typed,
-- `{ row = <0-based row>, col = <0-based byte col>, text = <string>, skip? }`.
-- `skip` lists byte ranges `{ start, end }` (buffer columns, end exclusive)
-- that are shown but not typed: comments, or code a diff left unchanged.
-- Each line is split into characters; between consecutive lines sits a
-- virtual "newline slot" that is satisfied by pressing <CR>.
local M = {}

local function default_clock()
	return vim.uv.hrtime() / 1e9
end

local function split_chars(text, base_col)
	local chars = {}
	local starts = vim.str_utf_pos(text)
	for i, pos in ipairs(starts) do
		local stop = (starts[i + 1] or #text + 1) - 1
		chars[i] = { ch = text:sub(pos, stop), col = base_col + pos - 1 }
	end
	return chars
end

local function is_blank(ch)
	return ch == " " or ch == "\t"
end

local function in_ranges(ranges, col)
	for _, range in ipairs(ranges or {}) do
		if col >= range[1] and col < range[2] then
			return true
		end
	end
	return false
end

-- Set `skip` on the characters that are not typed: those in the target's
-- skip ranges, blanks around the typed text, and blanks right after a
-- skipped stretch. Returns the first and last typed index, or nil.
local function mark_skips(chars, ranges, opts)
	for _, ch in ipairs(chars) do
		ch.skip = in_ranges(ranges, ch.col)
	end
	local first, last
	for i, ch in ipairs(chars) do
		if not ch.skip and not is_blank(ch.ch) then
			first = first or i
			last = i
		end
	end
	if not first then
		return nil
	end
	if opts.skip_leading_whitespace == false and not chars[1].skip then
		while first > 1 and not chars[first - 1].skip do
			first = first - 1
		end
	end
	if opts.trim_trailing_whitespace == false then
		while last < #chars and not chars[last + 1].skip do
			last = last + 1
		end
	end
	for i, ch in ipairs(chars) do
		if i < first or i > last or (i > first and is_blank(ch.ch) and chars[i - 1].skip) then
			ch.skip = true
		end
	end
	return first, last
end

---@param targets typist.Target[]
---@param opts? {skip_leading_whitespace?: boolean, trim_trailing_whitespace?: boolean, idle_timeout?: number|false, clock?: fun(): number}
---`idle_timeout`: a pause between keys longer than this many seconds only
---counts as this long.
function M.new(targets, opts)
	opts = opts or {}
	local lines = {}
	for _, target in ipairs(targets) do
		local chars = split_chars(target.text, target.col)
		local first, last = mark_skips(chars, target.skip, opts)
		-- Lines with nothing to type (blank, or all comment) are left out.
		if first then
			-- <CR> is expected after the last visible character, comments included.
			local eol = #chars
			while eol > last and is_blank(chars[eol].ch) do
				eol = eol - 1
			end
			table.insert(lines, {
				row = target.row,
				col = target.col,
				eol_col = chars[eol].col + #chars[eol].ch,
				chars = chars,
				start = first,
				last = last,
				status = {},
			})
		end
	end

	-- Characters to type plus one <CR> between consecutive lines.
	local total = math.max(#lines - 1, 0)
	for _, line in ipairs(lines) do
		for i = line.start, line.last do
			total = total + (line.chars[i].skip and 0 or 1)
		end
	end

	return {
		lines = lines,
		total = total,
		li = 1,
		ci = lines[1] and lines[1].start or 1,
		done = #lines == 0,
		clock = opts.clock or default_clock,
		idle_timeout = (opts.idle_timeout or 0) > 0 and opts.idle_timeout or math.huge,
		-- Pause time beyond `idle_timeout`, left out of the elapsed time.
		idle = 0,
		start_time = nil,
		end_time = nil,
		keystrokes = 0,
		correct_keystrokes = 0,
		typed_chars = 0,
		correct_chars = 0,
		missed = false,
	}
end

-- Index of the first typed character at or after `ci` (past the end: #chars + 1).
local function next_typed(line, ci)
	while ci <= #line.chars and line.chars[ci].skip do
		ci = ci + 1
	end
	return ci
end

-- Index of the last typed character at or before `ci`.
local function prev_typed(line, ci)
	while ci > line.start and line.chars[ci].skip do
		ci = ci - 1
	end
	return ci
end

-- True when the cursor sits on the newline slot after the current line.
function M.at_newline(state)
	local line = state.lines[state.li]
	return line ~= nil and state.ci > #line.chars and state.li < #state.lines
end

function M.expected(state)
	if state.done then
		return nil
	end
	if M.at_newline(state) then
		return "\n"
	end
	return state.lines[state.li].chars[state.ci].ch
end

local function set_status(state, line, ci, status)
	local prev = line.status[ci]
	if prev == status then
		return
	end
	if prev then
		state.typed_chars = state.typed_chars - 1
		if prev == "correct" then
			state.correct_chars = state.correct_chars - 1
		end
	end
	if status then
		state.typed_chars = state.typed_chars + 1
		if status == "correct" then
			state.correct_chars = state.correct_chars + 1
		end
	end
	line.status[ci] = status
end

local function keystroke(state, correct)
	state.missed = false
	local now = state.clock()
	if not state.start_time then
		state.start_time = now
	end
	if state.last_time and now - state.last_time > state.idle_timeout then
		state.idle = state.idle + now - state.last_time - state.idle_timeout
	end
	state.last_time = now
	state.keystrokes = state.keystrokes + 1
	if correct then
		state.correct_keystrokes = state.correct_keystrokes + 1
	end
end

-- The round ends once its final character is typed correctly. A wrong final
-- character leaves the cursor at the end so it can be fixed with backspace.
local function finish_if_complete(state)
	local line = state.lines[state.li]
	if state.li == #state.lines and state.ci > #line.chars and line.status[line.last] == "correct" then
		state.done = true
		state.end_time = state.last_time
	end
end

-- A wrong key that has nothing to mark red. `state.missed` stays set until the
-- next keystroke so the cursor can show it.
local function miss(state)
	keystroke(state, false)
	state.missed = true
	return { state.li }
end

---Feed one typed character (a printable char, "\t", or "\n").
---Returns the list of line indices whose rendering changed.
function M.type(state, ch)
	if state.done then
		return {}
	end
	local li = state.li
	local line = state.lines[li]

	if M.at_newline(state) then
		if ch ~= "\n" then
			-- Wrong key at end of line: counted, but the cursor does not move.
			return miss(state)
		end
		keystroke(state, true)
		set_status(state, line, state.ci, "correct")
		state.li = li + 1
		state.ci = state.lines[state.li].start
		return { li, li + 1 }
	end

	if ch == "\n" then
		-- Enter pressed mid-line: counted as a mistake, no movement.
		return miss(state)
	end

	if state.ci > #line.chars then
		-- Past the last character (its final key was wrong): nothing more to type.
		return miss(state)
	end
	local correct = line.chars[state.ci].ch == ch
	keystroke(state, correct)
	set_status(state, line, state.ci, correct and "correct" or "wrong")
	state.ci = next_typed(line, state.ci + 1)
	finish_if_complete(state)
	return { li }
end

---Undo the previous character. Crosses back over a line break.
function M.backspace(state)
	if state.done then
		return {}
	end
	local li = state.li
	local line = state.lines[li]
	if state.ci > line.start then
		state.ci = prev_typed(line, state.ci - 1)
		set_status(state, line, state.ci, nil)
		return { li }
	end
	if li > 1 then
		local prev = state.lines[li - 1]
		state.li = li - 1
		state.ci = #prev.chars + 1
		set_status(state, prev, state.ci, nil)
		return { li - 1, li }
	end
	return {}
end

---Undo back to the start of the previous word on the current line (<C-w>).
function M.backspace_word(state)
	if state.done then
		return {}
	end
	local line = state.lines[state.li]
	if state.ci <= line.start then
		return M.backspace(state)
	end
	local function prev_ch()
		return line.chars[prev_typed(line, state.ci - 1)].ch
	end
	while state.ci > line.start and is_blank(prev_ch()) do
		M.backspace(state)
	end
	while state.ci > line.start and not is_blank(prev_ch()) do
		M.backspace(state)
	end
	return { state.li }
end

---Stop the clock on an unfinished session (skipped or abandoned). Its time
---ends at the last keystroke, not when it was left.
function M.freeze(state)
	if state.start_time and not state.end_time then
		state.end_time = state.last_time
	end
end

---Combined stats over several sessions (e.g. one per git hunk). Elapsed time
---is summed per session, from its first keystroke to its last character, so
---time spent between sessions does not count against WPM. Long pauses are
---capped at `idle_timeout`.
---
---The clock starts on a session's first keystroke, so that key takes no time.
---To keep text split over many sessions from scoring higher than the same
---text typed in one go, each session after the first is charged one average
---key interval.
function M.summary(states)
	local elapsed, keystrokes, correct_keystrokes, typed, correct, total = 0, 0, 0, 0, 0, 0
	local started, intervals = 0, 0
	for _, s in ipairs(states) do
		if s.start_time then
			-- A running clock stops `idle_timeout` after the last key.
			local stop = s.end_time or math.min(s.clock(), s.last_time + s.idle_timeout)
			elapsed = elapsed + stop - s.start_time - s.idle
			started = started + 1
			intervals = intervals + s.keystrokes - 1
		end
		keystrokes = keystrokes + s.keystrokes
		correct_keystrokes = correct_keystrokes + s.correct_keystrokes
		typed = typed + s.typed_chars
		correct = correct + s.correct_chars
		total = total + s.total
	end
	if started > 1 and intervals > 0 then
		elapsed = elapsed + (started - 1) * elapsed / intervals
	end
	local minutes = elapsed / 60
	return {
		elapsed = elapsed,
		-- Standard definition: a "word" is 5 characters (newlines included).
		wpm = minutes > 0 and (correct / 5) / minutes or 0,
		-- Every key pressed, right or wrong, including ones later backspaced.
		raw_wpm = minutes > 0 and (keystrokes / 5) / minutes or 0,
		-- Every mistyped key counts, even if later fixed with backspace.
		accuracy = keystrokes > 0 and correct_keystrokes / keystrokes * 100 or 100,
		errors = keystrokes - correct_keystrokes,
		keystrokes = keystrokes,
		typed = typed,
		correct = correct,
		total = total,
	}
end

function M.stats(state)
	return M.summary({ state })
end

return M
