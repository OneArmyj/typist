-- Kept tiny: nothing is required until a command or mapping is used.
if vim.g.loaded_typist then
	return
end
vim.g.loaded_typist = true

local function typist()
	return require("typist")
end

local command = vim.api.nvim_create_user_command

command("Typist", function(cmd)
	typist().command(cmd)
end, { range = "%", desc = "Typing test over [range] (default: whole buffer)" })

command("TypistDiff", function(cmd)
	typist().start_diff({ base = cmd.args ~= "" and cmd.args or nil })
end, {
	nargs = "?",
	desc = "Type over the lines changed in git, from the hunk nearest the cursor",
	complete = function(lead)
		return vim.tbl_filter(function(c)
			return vim.startswith(c, lead)
		end, { "index", "HEAD", "HEAD~1" })
	end,
})

command("TypistResults", function()
	typist().show_last()
end, { desc = "Show the results of the last typing test" })

command("TypistOption", function(cmd)
	local name, arg = cmd.fargs[1], cmd.fargs[2]
	local value = ({ on = true, off = false })[arg]
	if (arg and value == nil) or #cmd.fargs > 2 then
		vim.notify("typist: usage: :TypistOption {name} [on|off]", vim.log.levels.ERROR)
		return
	end
	typist().set_option(name, value)
end, {
	nargs = "+",
	desc = "Toggle a typist option: :TypistOption {name} [on|off]",
	complete = function(lead, line)
		local candidates = #vim.split(line, "%s+") > 2 and { "on", "off" } or require("typist.config").toggleable
		return vim.tbl_filter(function(c)
			return vim.startswith(c, lead)
		end, candidates)
	end,
})

local map = vim.keymap.set
map("n", "<Plug>(typist-buffer)", function()
	typist().start()
end, { desc = "Typist: test the whole buffer" })
map("n", "<Plug>(typist-diff)", function()
	typist().start_diff()
end, { desc = "Typist: type over the git changes" })
map("x", "<Plug>(typist-visual)", function()
	typist().start_visual()
end, { desc = "Typist: test the selection" })
