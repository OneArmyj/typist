local engine = require("typist.engine")

local function fake_clock()
	local now = 0
	return function()
		return now
	end, function(t)
		now = t
	end
end

local function type_str(state, s)
	for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
		engine.type(state, ch)
	end
end

local function lines(...)
	local targets = {}
	for i, text in ipairs({ ... }) do
		table.insert(targets, { row = i - 1, col = 0, text = text })
	end
	return targets
end

it("completes a single line typed correctly", function()
	local s = engine.new(lines("abc"))
	type_str(s, "abc")
	eq(true, s.done)
	eq(100, engine.stats(s).accuracy)
	eq(3, s.correct_chars)
end)

it("marks wrong chars and advances", function()
	local s = engine.new(lines("abc"))
	type_str(s, "axc")
	eq(true, s.done)
	eq({ "correct", "wrong", "correct" }, s.lines[1].status)
	eq(1, engine.stats(s).errors)
end)

it("backspace clears status but accuracy remembers the mistake", function()
	local s = engine.new(lines("abc"))
	type_str(s, "ax")
	engine.backspace(s)
	eq(nil, s.lines[1].status[2])
	type_str(s, "bc")
	eq(true, s.done)
	eq(3, s.correct_chars)
	eq(3, engine.stats(s).keystrokes - 1)
	eq(75, engine.stats(s).accuracy)
end)

it("skips leading indentation and requires enter between lines", function()
	local s = engine.new(lines("ab", "    cd"))
	type_str(s, "ab")
	eq(true, engine.at_newline(s))
	eq("\n", engine.expected(s))
	type_str(s, "x") -- wrong key at eol: counted, no movement
	eq(true, engine.at_newline(s))
	engine.type(s, "\n")
	eq(2, s.li)
	eq(5, s.ci)
	eq("c", engine.expected(s))
	type_str(s, "cd")
	eq(true, s.done)
	eq(1, engine.stats(s).errors)
end)

it("enter mid-line counts as an error without moving", function()
	local s = engine.new(lines("ab"))
	engine.type(s, "\n")
	eq(1, s.ci)
	eq(1, s.keystrokes - s.correct_keystrokes)
end)

it("can be configured to require indentation", function()
	local s = engine.new(lines("  a"), { skip_leading_whitespace = false })
	eq(" ", engine.expected(s))
end)

it("backspace crosses back over a line break", function()
	local s = engine.new(lines("ab", "\tcd"))
	type_str(s, "ab\n")
	eq(2, s.li)
	engine.backspace(s)
	eq(1, s.li)
	eq(true, engine.at_newline(s))
	engine.backspace(s)
	eq("b", engine.expected(s))
end)

it("skips blank lines and trims trailing whitespace", function()
	local s = engine.new(lines("a  ", "", "   ", "b"))
	eq(2, #s.lines)
	type_str(s, "a\nb")
	eq(true, s.done)
	eq(3, engine.stats(s).total)
end)

it("handles multibyte characters with byte columns", function()
	local s = engine.new({ { row = 0, col = 2, text = "é→x" } })
	eq(
		{ 2, 4, 7 },
		vim.tbl_map(function(c)
			return c.col
		end, s.lines[1].chars)
	)
	type_str(s, "é→x")
	eq(true, s.done)
	eq(100, engine.stats(s).accuracy)
end)

it("ctrl-w deletes back to the previous word", function()
	local s = engine.new(lines("foo bar"))
	type_str(s, "foo ba")
	engine.backspace_word(s)
	eq("b", engine.expected(s))
	engine.backspace_word(s)
	eq("f", engine.expected(s))
end)

it("computes wpm from correct chars and elapsed time", function()
	local clock, set = fake_clock()
	local s = engine.new(lines(string.rep("a", 50)), { clock = clock })
	set(10)
	engine.type(s, "a") -- timer starts at first keystroke
	for _ = 2, 49 do
		engine.type(s, "a")
	end
	set(60)
	engine.type(s, "b") -- last char wrong: not finished yet
	eq(false, s.done)
	eq((50 / 5) / (50 / 60), engine.stats(s).raw_wpm)
	engine.type(s, "z") -- extra keys at the end are errors, cursor stays
	eq(false, s.done)
	engine.backspace(s)
	set(70)
	engine.type(s, "a")
	local st = engine.stats(s)
	eq(true, s.done)
	eq(60, st.elapsed, "from first keystroke to the final correct one")
	eq(50 / 5, st.wpm)
	eq(52 / 5, st.raw_wpm, "50 correct + 2 wrong keys")
	eq(2, st.errors)
	eq(50 / 52 * 100, st.accuracy)
end)

it("a round only ends when its last character is correct", function()
	local s = engine.new(lines("ab", "cd"))
	type_str(s, "ab\ncx")
	eq(false, s.done)
	eq({ "correct", "wrong" }, s.lines[2].status)
	engine.backspace(s)
	type_str(s, "d")
	eq(true, s.done)
end)

it("empty selection is immediately done", function()
	local s = engine.new(lines("", "   "))
	eq(true, s.done)
end)

it("flags a wrong key that has nothing to mark red", function()
	local s = engine.new(lines("ab", "cd"))
	engine.type(s, "a")
	engine.type(s, "\n")
	eq(true, s.missed, "enter mid-line")
	engine.type(s, "b")
	eq(false, s.missed)
	engine.type(s, " ")
	eq(true, s.missed, "space where <CR> is expected")
	eq(2, engine.stats(s).errors)
end)

it("skip ranges are shown but not typed", function()
	-- "x = 1 -- one": the comment (cols 6..12) is skipped.
	local s = engine.new({
		{ row = 0, col = 0, text = "x = 1 -- one", skip = { { 6, 12 } } },
		{ row = 1, col = 0, text = "y" },
	})
	eq(5 + 1 + 1, s.total, "x = 1, <CR>, y")
	for _, ch in ipairs(vim.split("x = 1", "")) do
		engine.type(s, ch)
	end
	eq("\n", engine.expected(s), "the comment is not typed")
	eq(12, s.lines[1].eol_col, "<CR> marker after the comment")
	engine.type(s, "\n")
	engine.type(s, "y")
	eq(true, s.done)
	eq(100, engine.stats(s).accuracy)
end)

it("skips the unchanged middle of a line, and backspace jumps back over it", function()
	-- Type "local" and "60" only: "local timeout = 60".
	local s = engine.new({ { row = 0, col = 0, text = "local timeout = 60", skip = { { 5, 16 } } } })
	eq(7, s.total)
	for _, ch in ipairs(vim.split("local", "")) do
		engine.type(s, ch)
	end
	eq("6", engine.expected(s))
	engine.backspace(s)
	eq("l", engine.expected(s), "back to the last typed char before the gap")
	engine.type(s, "l")
	engine.type(s, "6")
	engine.type(s, "0")
	eq(true, s.done)
end)

it("a line that is all comment is left out", function()
	local s =
		engine.new({ { row = 0, col = 0, text = "-- note", skip = { { 0, 7 } } }, { row = 1, col = 0, text = "z" } })
	eq(1, #s.lines)
	eq(1, s.total)
end)

it("caps long pauses at idle_timeout", function()
	local clock, set = fake_clock()
	local s = engine.new(lines("abcd"), { clock = clock, idle_timeout = 5 })
	set(0)
	engine.type(s, "a")
	set(1)
	engine.type(s, "b")
	set(61) -- a one-minute break counts as 5s
	engine.type(s, "c")
	eq(1 + 5, engine.stats(s).elapsed)
	set(100)
	eq(1 + 5 + 5, engine.stats(s).elapsed, "a running clock also stops 5s after the last key")
	engine.type(s, "d")
	eq(1 + 5 + 5, engine.stats(s).elapsed, "the same pause, now ended by a key")
	eq(true, s.done)
end)
