-- :checkhealth typist
local M = {}

function M.check()
	local health = vim.health
	health.start("typist")

	if vim.fn.has("nvim-0.11") == 1 then
		health.ok("Neovim " .. tostring(vim.version()))
	else
		health.error(
			"Neovim 0.11 or newer is required",
			{ "Upgrade Neovim: https://github.com/neovim/neovim/releases" }
		)
	end

	if vim.fn.executable("git") == 1 then
		local version = vim.system({ "git", "--version" }, { text = true }):wait()
		health.ok(vim.trim(version.stdout or "git"))
	else
		health.warn("git not found on $PATH", { ":TypistDiff needs git. :Typist works without it." })
	end

	if vim.o.termguicolors then
		health.ok("'termguicolors' is on")
	else
		health.warn(
			"'termguicolors' is off",
			{ "Dimming and ghost text are blended from your colorscheme's true colors." }
		)
	end
end

return M
