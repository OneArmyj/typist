local typist = require("typist")
local git = require("typist.git")
local render = require("typist.render")

local tmp = vim.fn.tempname()

local function sh(cmd, cwd)
	local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
	assert(r.code == 0, table.concat(cmd, " ") .. ": " .. (r.stderr or ""))
	return r.stdout
end

-- A repo with `file.lua` committed as `base`, then the buffer edited to `edited`.
local function repo(base, edited)
	local dir = tmp .. "/" .. tostring(vim.uv.hrtime())
	vim.fn.mkdir(dir, "p")
	sh({ "git", "init", "-q" }, dir)
	sh({ "git", "config", "user.email", "t@t" }, dir)
	sh({ "git", "config", "user.name", "t" }, dir)
	local path = dir .. "/file.lua"
	vim.fn.writefile(base, path)
	sh({ "git", "add", "file.lua" }, dir)
	sh({ "git", "commit", "-qm", "init" }, dir)
	vim.fn.writefile(edited, path)
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	vim.bo.swapfile = false
	return vim.api.nvim_get_current_buf(), dir
end

local BASE = { "local a = 1", "local b = 2", "local c = 3", "local d = 4", "local e = 5", "local f = 6" }
local EDITED =
	{ "local a = 1", "local B = 20", "local c = 3", "local d = 4", "local e = 5", "local F = 60", "local g = 7" }

-- Whole lines are typed in these tests; changed_text_only has its own.
local WHOLE = { show_results = false, diff = { changed_text_only = false } }

local function fake_clock()
	local now = 0
	return function()
		now = now + 0.25
		return now
	end
end

it("finds changed hunks against the index", function()
	local buf = repo(BASE, EDITED)
	local hunks = assert(git.hunks(buf, "index"))
	eq(2, #hunks)
	eq({ first = 2, last = 2, deleted = { "local b = 2" } }, hunks[1])
	eq({ first = 6, last = 7, deleted = { "local f = 6" } }, hunks[2])
end)

it("sees unsaved buffer edits", function()
	local buf = repo(BASE, BASE)
	eq({}, git.hunks(buf, "index"))
	vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "local d = 40" })
	local hunks = git.hunks(buf, "index")
	eq(1, #hunks)
	eq(4, hunks[1].first)
end)

it("treats an untracked file as entirely new", function()
	local _, dir = repo(BASE, BASE)
	vim.fn.writefile({ "x = 1", "y = 2" }, dir .. "/new.lua")
	vim.cmd("edit! " .. vim.fn.fnameescape(dir .. "/new.lua"))
	local hunks = git.hunks(0, "index")
	eq({ { first = 1, last = 2, deleted = {} } }, hunks)
end)

it("reports a clear error outside a repository", function()
	local path = tmp .. "/norepo/x.lua"
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile({ "a" }, path)
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local hunks, err = git.hunks(0, "index")
	eq(nil, hunks)
	eq("not inside a git repository", err)
end)

it("reports an unknown revision", function()
	local buf = repo(BASE, EDITED)
	local hunks, err = git.hunks(buf, "nope")
	eq(nil, hunks)
	eq("unknown revision 'nope'", err)
end)

it("finds the hunk nearest the cursor", function()
	local hunks = { { first = 2, last = 2 }, { first = 20, last = 22 }, { first = 40, last = 40 } }
	eq(1, git.nearest(hunks, 1))
	eq(2, git.nearest(hunks, 18), "18 is 2 lines from hunk 2, 16 from hunk 1")
	eq(2, git.nearest(hunks, 21), "inside a hunk")
	eq(3, git.nearest(hunks, 100), "below the last hunk")
	eq(1, git.nearest(hunks, 11), "tie goes to the hunk above")
end)

it("starts at the nearest hunk and ends at the bottom of the file", function()
	typist.setup(WHOLE)
	local buf = repo(BASE, EDITED)
	vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- nearer the second hunk
	local tick = vim.b[buf].changedtick
	local rows = {}
	local original = render.begin_round
	render.begin_round = function(view, round)
		table.insert(rows, round.targets[1].row + 1)
		return original(view, round)
	end
	vim.api.nvim_feedkeys("local F = 60\rlocal g = 7", "t", false)
	local ok, result = pcall(typist.start_diff, {})
	render.begin_round = original
	assert(ok, result)
	eq({ 6 }, rows, "no wrap back to the hunk above")
	eq(true, result.completed)
	eq({ finished = 1, total = 1 }, result.rounds)
	eq(0, result.stats.errors)
	eq(24, result.stats.total)
	eq(tick, vim.b[buf].changedtick, "buffer untouched")
	eq(0, #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}))
end)

it("types every hunk from the top and jumps between them", function()
	typist.setup(WHOLE)
	repo(BASE, EDITED)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	local rows = {}
	local original = render.begin_round
	render.begin_round = function(view, round)
		table.insert(rows, round.targets[1].row + 1)
		return original(view, round)
	end
	vim.api.nvim_feedkeys("local B = 20" .. "local F = 60\rlocal g = 7", "t", false)
	local ok, result = pcall(typist.start_diff, {})
	render.begin_round = original
	assert(ok, result)
	eq({ 2, 6 }, rows)
	eq({ finished = 2, total = 2 }, result.rounds)
end)

it("shows every hunk as ghost text and dims the rest", function()
	typist.setup(WHOLE)
	local buf = repo(BASE, EDITED)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	local snapshot
	local original = render.update
	render.update = function(...)
		original(...)
		snapshot = {}
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
			local group = m[4].hl_group
			if group == "TypistGhost" or group == "TypistDim" then
				for row = m[2], (m[4].end_col == 0 and m[4].end_row - 1 or m[4].end_row or m[2]) do
					snapshot[row + 1] = snapshot[row + 1] or group
				end
			end
		end
	end
	vim.api.nvim_feedkeys("l\27", "t", false)
	pcall(typist.start_diff, {})
	render.update = original
	-- Lines 2 (being typed) and 6-7 (waiting) are ghost; the rest is dimmed.
	eq({ "TypistDim", "TypistGhost", "TypistDim", "TypistDim", "TypistDim", "TypistGhost", "TypistGhost" }, snapshot)
end)

it("skip key moves on to the next hunk", function()
	typist.setup(WHOLE)
	repo(BASE, EDITED)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.api.nvim_feedkeys("loc" .. vim.keycode("<C-n>") .. "local F = 60\rlocal g = 7", "t", false)
	local result = typist.start_diff({})
	eq(true, result.completed)
	eq({ finished = 1, total = 2 }, result.rounds, "skipped hunk is not finished")
	eq(24 + 3, result.stats.typed)
end)

it("stopping keeps the cursor at the current hunk", function()
	typist.setup(WHOLE)
	repo(BASE, EDITED)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.api.nvim_feedkeys("local B = 20\27", "t", false)
	local result = typist.start_diff({})
	eq(false, result.completed)
	eq(6, vim.api.nvim_win_get_cursor(0)[1])
end)

it("draws the replaced lines above the hunk", function()
	typist.setup(WHOLE)
	local buf = repo(BASE, EDITED)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	local virt
	local original = render.update
	render.update = function(...)
		original(...)
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
			if m[4].virt_lines then
				virt = { row = m[2], text = m[4].virt_lines[1][1][1], above = m[4].virt_lines_above }
			end
		end
	end
	vim.api.nvim_feedkeys("l\27", "t", false)
	pcall(typist.start_diff, {})
	render.update = original
	eq({ row = 1, text = "local b = 2", above = true }, virt)
end)

it("stats add up across hunks with exact timing", function()
	typist.setup(WHOLE)
	repo(BASE, EDITED)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	local engine = require("typist.engine")
	-- Simulated time: every typed key takes 0.25s, and 10s pass between hunks.
	local now = 0
	local clock = function()
		return now
	end
	local type_orig, init_orig = engine.type, render.begin_round
	engine.type = function(...)
		now = now + 0.25
		return type_orig(...)
	end
	local rounds = 0
	render.begin_round = function(...)
		rounds = rounds + 1
		if rounds > 1 then
			now = now + 10
		end
		return init_orig(...)
	end
	-- Hunk 1, "local B = 20" (12 chars): one wrong key, fixed with backspace.
	-- Hunk 2, "local F = 60" <CR> "local g = 7" (24 incl. the newline).
	vim.api.nvim_feedkeys("local X" .. vim.keycode("<BS>") .. "B = 20" .. "local F = 60\rlocal g = 7", "t", false)
	local ok, result = pcall(typist.start_diff, { clock = clock })
	engine.type, render.begin_round = type_orig, init_orig
	assert(ok, result)
	local s = result.stats
	eq(true, result.completed)
	eq(36, s.total)
	eq(36, s.correct)
	eq(36, s.typed)
	eq(37, s.keystrokes, "13 + 24 key presses (backspace is not a keystroke)")
	eq(1, s.errors)
	eq(36 / 37 * 100, s.accuracy)
	-- Hunk 1: first key at 0.25, last at 3.25 -> 3.0s.
	-- Hunk 2: first key at 13.5, last at 19.25 -> 5.75s. The 10s gap is excluded.
	-- Hunk 2's first key is charged one average interval: 8.75s / 35 = 0.25s.
	eq(9, s.elapsed)
	eq((36 / 5) / (9 / 60), s.wpm)
	eq((37 / 5) / (9 / 60), s.raw_wpm, "raw counts every key, including the fixed mistake")
end)

it("wpm counts only correct characters; raw counts all typed", function()
	local engine = require("typist.engine")
	local now = 0
	local s = engine.new({ { row = 0, col = 0, text = "abcdefghij" } }, {
		clock = function()
			return now
		end,
	})
	for _, ch in ipairs(vim.split("abcdeXXXXj", "")) do
		engine.type(s, ch)
		now = now + 6 -- 10 keys over 54s between first and last
	end
	local st = engine.stats(s)
	eq(54, st.elapsed)
	eq(6, s.correct_chars)
	eq((6 / 5) / (54 / 60), st.wpm)
	eq((10 / 5) / (54 / 60), st.raw_wpm)
	eq(60, st.accuracy)
	eq(4, st.errors)
end)

it("a skipped hunk stops its clock at its last keystroke", function()
	typist.setup(WHOLE)
	repo(BASE, EDITED)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	local engine = require("typist.engine")
	local now = 0
	local type_orig, init_orig = engine.type, render.begin_round
	engine.type = function(...)
		now = now + 1
		return type_orig(...)
	end
	local rounds = 0
	render.begin_round = function(...)
		rounds = rounds + 1
		if rounds > 1 then
			now = now + 100 -- long pause after skipping
		end
		return init_orig(...)
	end
	vim.api.nvim_feedkeys("loc" .. vim.keycode("<C-n>") .. "local F = 60\rlocal g = 7", "t", false)
	local ok, result = pcall(typist.start_diff, {
		clock = function()
			return now
		end,
	})
	engine.type, render.begin_round = type_orig, init_orig
	assert(ok, result)
	-- Hunk 1: keys at t=1..3 -> 2s. Hunk 2: 24 keys at t=104..127 -> 23s.
	-- Plus one average interval (25s / 25) for hunk 2's first key.
	eq(26, result.stats.elapsed)
end)

it("shows the replaced lines when the hunk starts at line 1", function()
	typist.setup(vim.tbl_extend("force", WHOLE, { live_stats = false }))
	repo({ "old1", "old2", "keep" }, { "new1", "keep" })
	local topfill
	local original = render.begin_round
	render.begin_round = function(...)
		original(...)
		topfill = vim.fn.winsaveview().topfill
	end
	vim.api.nvim_feedkeys("\27", "t", false)
	local ok, err = pcall(typist.start_diff, {})
	render.begin_round = original
	assert(ok, err)
	eq(2, topfill, "both replaced lines shown as filler above line 1")
	typist.setup(WHOLE)
end)

it("refuses a file with merge conflicts", function()
	local _, dir = repo(BASE, BASE)
	sh({ "git", "checkout", "-qb", "other" }, dir)
	vim.fn.writefile({ "local a = 100" }, dir .. "/file.lua")
	sh({ "git", "commit", "-qam", "other" }, dir)
	sh({ "git", "checkout", "-q", "-" }, dir)
	vim.fn.writefile({ "local a = 200" }, dir .. "/file.lua")
	sh({ "git", "commit", "-qam", "main" }, dir)
	vim.system({ "git", "merge", "-q", "other" }, { cwd = dir }):wait()
	vim.cmd("edit!")
	local hunks, err = git.hunks(0, "index")
	eq(nil, hunks)
	eq("file has unresolved merge conflicts", err)
end)

it("splitting text into hunks does not inflate wpm", function()
	local engine = require("typist.engine")
	local now = 0
	local function clock()
		return now
	end
	local function type_all(state, text)
		for _, ch in ipairs(vim.split(text, "")) do
			engine.type(state, ch)
			now = now + 1
		end
	end
	local whole = engine.new({ { row = 0, col = 0, text = "abcdefghij" } }, { clock = clock })
	type_all(whole, "abcdefghij")
	local parts = {}
	for i, text in ipairs({ "abcde", "fghij" }) do
		parts[i] = engine.new({ { row = i, col = 0, text = text } }, { clock = clock })
		now = now + 30 -- moving between hunks is not counted
		type_all(parts[i], text)
	end
	eq(engine.stats(whole).wpm, engine.summary(parts).wpm)
end)

it("shows lines that were only deleted", function()
	typist.setup(vim.tbl_extend("force", WHOLE, { live_stats = false }))
	local buf = repo({ "keep 1", "gone", "keep 2", "old" }, { "keep 1", "keep 2", "new" })
	local virt = {}
	local original = render.begin_round
	render.begin_round = function(...)
		original(...)
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
			if m[4].virt_lines then
				table.insert(virt, { m[2], m[4].virt_lines[1][1][1] })
			end
		end
	end
	vim.api.nvim_feedkeys("\27", "t", false)
	local ok, err = pcall(typist.start_diff, {})
	render.begin_round = original
	assert(ok, err)
	table.sort(virt, function(a, b)
		return a[1] < b[1]
	end)
	eq({ { 1, "gone" }, { 2, "old" } }, virt)
	typist.setup(WHOLE)
end)

it("only the changed words of an edited line are typed", function()
	typist.setup({ show_results = false, live_stats = false })
	repo({ "local timeout = 30 -- seconds", "x()" }, { "local timeout = 60 -- seconds", "x()" })
	vim.api.nvim_feedkeys("60", "t", false)
	local ok, result = pcall(typist.start_diff, {})
	assert(ok, result)
	eq(true, result.completed)
	eq(2, result.stats.total, "just 60: the rest of the line, comment included, is kept")
	eq(0, result.stats.errors)
	typist.setup(WHOLE)
end)

it("a new line is typed whole, and its comment is skipped", function()
	typist.setup({ show_results = false, live_stats = false })
	local buf = repo({ "a()" }, { "a()", "b() -- why" })
	vim.bo[buf].filetype = "lua"
	vim.api.nvim_feedkeys("b()", "t", false)
	local ok, result = pcall(typist.start_diff, {})
	assert(ok, result)
	eq(true, result.completed)
	eq(3, result.stats.total)
	typist.setup(WHOLE)
end)

it("hunks that are only comments are shown but not visited", function()
	typist.setup({ show_results = false, live_stats = false })
	local buf = repo({ "a()", "b()" }, { "-- note", "a()", "b()", "c()" })
	vim.bo[buf].filetype = "lua"
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	local ghost_rows = {}
	local original = render.begin_round
	render.begin_round = function(view, round)
		original(view, round)
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
			if m[4].hl_group == "TypistSkipped" then
				ghost_rows[m[2]] = true
			end
		end
	end
	vim.api.nvim_feedkeys("c()", "t", false)
	local ok, result = pcall(typist.start_diff, {})
	render.begin_round = original
	assert(ok, result)
	eq({ finished = 1, total = 1 }, result.rounds)
	eq({ [0] = true }, ghost_rows, "the comment hunk is drawn as a skipped comment")
	typist.setup(WHOLE)
end)

it("unchanged_parts finds the unchanged words of edited lines", function()
	local parts = git.unchanged_parts({ "local timeout = 30" }, { "-- new", "local timeout = 60", "local retries = 3" })
	eq({ [2] = { { 0, 16 } } }, parts)
	eq({}, git.unchanged_parts({ "foo(a, b)" }, { "bar(x, y, z)" }), "rewritten: typed whole")
	eq({}, git.unchanged_parts({}, { "new" }))
end)
