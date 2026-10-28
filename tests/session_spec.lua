local typist = require("typist")
local render = require("typist.render")

local function fresh_buffer(lines)
	vim.cmd("enew!")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end

local function extmark_count(buf)
	return #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {})
end

typist.setup({ show_results = false })

it("runs a full session from typeahead and leaves the buffer untouched", function()
	local buf = fresh_buffer({ "before", "local x = 1", "  return x", "after" })
	local tick = vim.b[buf].changedtick
	vim.api.nvim_feedkeys("local y = 1\rreturn x", "t", false)
	local result = typist.start({ line1 = 2, line2 = 3 })
	eq(true, result.completed)
	eq(1, result.stats.errors)
	eq(tick, vim.b[buf].changedtick)
	eq(0, extmark_count(buf))
	eq({ "before", "local x = 1", "  return x", "after" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end)

it("escape aborts and cleans up", function()
	local buf = fresh_buffer({ "abc def" })
	vim.api.nvim_feedkeys("ab\27", "t", false)
	local result = typist.start({})
	eq(false, result.completed)
	eq(0, extmark_count(buf))
end)

it("backspace in the session undoes a wrong char", function()
	fresh_buffer({ "abc" })
	vim.api.nvim_feedkeys("ax" .. vim.keycode("<BS>") .. "bc", "t", false)
	local result = typist.start({})
	eq(true, result.completed)
	eq(1, result.stats.errors)
	eq(3, result.stats.typed)
end)

it("charwise region only covers the selected columns", function()
	local buf = fresh_buffer({ "foo(bar, baz)", "qux" })
	local region = vim.fn.getregionpos({ buf, 1, 5, 0 }, { buf, 1, 7, 0 }, { type = "v" })
	vim.api.nvim_feedkeys("bar", "t", false)
	local result = typist.start({ region = region })
	eq(true, result.completed)
	eq(3, result.stats.total)
end)

it("draws ghost and dim highlights while running", function()
	local buf = fresh_buffer({ "one", "two", "three" })
	local seen = {}
	-- Snapshot the overlay after the first keystroke is rendered.
	local original = render.update
	render.update = function(...)
		original(...)
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
			seen[m[4].hl_group or "virt"] = true
		end
	end
	vim.api.nvim_feedkeys("tx\27", "t", false)
	local ok, err = pcall(typist.start, { line1 = 2, line2 = 2 })
	render.update = original
	assert(ok, err)
	eq(true, seen.TypistDim, "dim")
	eq(true, seen.TypistGhost, "ghost")
	eq(true, seen.TypistError, "error")
	eq(0, extmark_count(buf))
end)

it("ctrl-c ends the test; other keys, like a mapping's <Space>, are typed", function()
	fresh_buffer({ "a b" })
	vim.api.nvim_feedkeys("a \3", "t", false)
	local result = typist.start({})
	eq(false, result.completed)
	eq(2, result.stats.typed)
	eq(0, result.stats.errors)
end)

it("toggle option flips booleans", function()
	local config = require("typist.config")
	local before = config.options.dim_outside
	local notify = vim.notify
	vim.notify = function() end
	typist.set_option("dim_outside")
	eq(not before, config.options.dim_outside)
	typist.set_option("dim_outside", before)
	vim.notify = notify
	eq(before, config.options.dim_outside)
end)

it("only changes window-local options, and restores them", function()
	local win = vim.api.nvim_get_current_win()
	fresh_buffer({ "abc" })
	vim.o.cursorline = false
	vim.go.virtualedit = "block"
	vim.wo[win][0].virtualedit = ""
	vim.wo[win][0].cursorline = true
	vim.api.nvim_feedkeys("abc", "t", false)
	typist.start({})
	eq(false, vim.go.cursorline, "global cursorline")
	eq("block", vim.go.virtualedit, "global virtualedit")
	eq(true, vim.api.nvim_get_option_value("cursorline", { scope = "local", win = win }))
	eq("", vim.api.nvim_get_option_value("virtualedit", { scope = "local", win = win }), "local value still unset")
	eq("block", vim.wo[win].virtualedit, "falls back to the global value")
	vim.wo[win].cursorline = false
end)

it("cleans up when drawing fails", function()
	local buf = fresh_buffer({ "abc" })
	local original = render.begin_round
	render.begin_round = function(view, round)
		original(view, round)
		error("boom")
	end
	local ok, err = pcall(typist.start, {})
	render.begin_round = original
	eq(false, ok)
	eq(true, tostring(err):find("boom") ~= nil)
	eq(false, typist.is_active())
	eq(0, extmark_count(buf))
end)

it("rejects a bad skip_keys option and stays usable", function()
	eq(false, (pcall(typist.setup, { diff = { skip_keys = "<C-n>" } })))
	typist.setup({ show_results = false })
	fresh_buffer({ "ab" })
	vim.api.nvim_feedkeys("ab", "t", false)
	eq(true, typist.start({}).completed)
end)

it(":TypistOption completes by prefix and rejects bad values", function()
	vim.cmd.runtime("plugin/typist.lua")
	eq({ "show_wpm" }, vim.fn.getcompletion("TypistOption show_w", "cmdline"))
	eq({ "off" }, vim.fn.getcompletion("TypistOption live_stats of", "cmdline"))
	local config = require("typist.config")
	local before = config.options.live_stats
	local notify, messages = vim.notify, {}
	vim.notify = function(msg, _)
		table.insert(messages, msg)
	end
	vim.cmd("TypistOption live_stats maybe")
	vim.notify = notify
	eq(before, config.options.live_stats)
	eq(true, messages[1]:find("usage") ~= nil)
end)

it(":Typist only keeps visual columns for a '<,'> range", function()
	vim.cmd.runtime("plugin/typist.lua")
	fresh_buffer({ "foo(bar, baz)", "qux" })
	local specs = {}
	local original = typist.start
	typist.start = function(spec)
		table.insert(specs, spec.region and "region" or "lines")
	end
	vim.api.nvim_feedkeys("0wwvll:Typist\r", "tx", false)
	vim.api.nvim_feedkeys(":1,1Typist\r", "tx", false)
	typist.start = original
	eq({ "region", "lines" }, specs)
	eq({ "HEAD", "HEAD~1" }, vim.fn.getcompletion("TypistDiff H", "cmdline"))
end)

it("skips comments when typing a selection", function()
	local buf = fresh_buffer({ "local x = 1 -- the x", "-- just a note", "return x" })
	vim.bo[buf].filetype = "lua"
	vim.api.nvim_feedkeys("local x = 1\rreturn x", "t", false)
	local result = typist.start({})
	eq(true, result.completed)
	eq(0, result.stats.errors)
	eq(#"local x = 1" + 1 + #"return x", result.stats.total)
end)

it("opens folds and shows concealed text during a test, then restores them", function()
	local win = vim.api.nvim_get_current_win()
	fresh_buffer({ "a", "b", "c" })
	vim.wo[win][0].foldmethod = "manual"
	vim.wo[win][0].conceallevel = 2
	vim.cmd("1,3fold")
	local seen
	local original = render.begin_round
	render.begin_round = function(...)
		original(...)
		seen = { vim.fn.foldclosed(2), vim.wo[win].conceallevel }
	end
	vim.api.nvim_feedkeys("\27", "t", false)
	local ok, err = pcall(typist.start, { line1 = 2, line2 = 2 })
	render.begin_round = original
	assert(ok, err)
	eq({ -1, 0 }, seen)
	eq(1, vim.fn.foldclosed(2), "fold closed again")
	eq(2, vim.wo[win].conceallevel)
	vim.wo[win][0].conceallevel = 0
	vim.cmd("normal! zE")
end)
