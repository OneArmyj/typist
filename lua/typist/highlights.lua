-- Highlight groups derived from the active colorscheme, so the game always
-- matches the theme. Recomputed on every :colorscheme change.
local M = {}

local function hl(name)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	return ok and value or {}
end

local function first_color(attr, names)
	for _, name in ipairs(names) do
		local color = hl(name)[attr]
		if color then
			return color
		end
	end
end

-- Mix `a` into `b`: t = 1 gives a, t = 0 gives b.
local function blend(a, b, t)
	local function channel(color, shift)
		return math.floor(color / 2 ^ shift) % 256
	end
	local out = 0
	for _, shift in ipairs({ 16, 8, 0 }) do
		local c = math.floor(channel(a, shift) * t + channel(b, shift) * (1 - t) + 0.5)
		out = out + c * 2 ^ shift
	end
	return out
end

-- Hue in degrees and HSL saturation (0-1) of a 0xRRGGBB color.
local function hue_sat(color)
	local r = math.floor(color / 65536) % 256 / 255
	local g = math.floor(color / 256) % 256 / 255
	local b = color % 256 / 255
	local max, min = math.max(r, g, b), math.min(r, g, b)
	local delta = max - min
	if delta == 0 then
		return 0, 0
	end
	local light = (max + min) / 2
	local sat = delta / (1 - math.abs(2 * light - 1))
	local hue
	if max == r then
		hue = ((g - b) / delta) % 6
	elseif max == g then
		hue = (b - r) / delta + 2
	else
		hue = (r - g) / delta + 4
	end
	return hue * 60, sat
end

-- First theme color that is colorful and clearly a different hue from the
-- error color, so the cursor is never mistaken for a typo.
local function pick_accent(error, fallback)
	local error_hue = hue_sat(error)
	for _, name in ipairs({ "Special", "Type", "DiagnosticHint", "Keyword", "Function", "Title", "String" }) do
		local color = hl(name).fg
		if color then
			local hue, sat = hue_sat(color)
			local distance = math.abs(hue - error_hue)
			distance = math.min(distance, 360 - distance)
			if sat >= 0.15 and distance >= 90 then
				return color
			end
		end
	end
	return fallback
end

function M.palette()
	local dark = vim.o.background == "dark"
	local fg = first_color("fg", { "Normal" }) or (dark and 0xd0d0d0 or 0x303030)
	local bg = first_color("bg", { "Normal" }) or (dark and 0x101010 or 0xfafafa)
	local float_bg = first_color("bg", { "NormalFloat", "Pmenu" }) or bg
	local error = first_color("fg", { "DiagnosticError", "ErrorMsg", "Error" }) or 0xe06c75
	return {
		fg = fg,
		bg = bg,
		float_bg = float_bg,
		comment = first_color("fg", { "Comment" }) or blend(fg, bg, 0.5),
		error = error,
		removed = first_color("fg", { "Removed", "diffRemoved", "GitSignsDelete", "DiffDelete" }) or error,
		accent = pick_accent(error, fg),
		ok = first_color("fg", { "DiagnosticOk", "String" }) or fg,
		border = first_color("fg", { "FloatBorder", "WinSeparator" }) or blend(fg, bg, 0.3),
	}
end

function M.apply()
	local p = M.palette()
	local dim = 1 - math.min(math.max(require("typist.config").options.dim_amount, 0), 1)
	local groups = {
		-- Text outside the test: pushed far into the background.
		TypistDim = { fg = blend(p.fg, p.bg, dim), nocombine = true },
		TypistDimNr = { fg = blend(p.fg, p.bg, dim * 0.8) },
		-- Lines being typed get a faint band so the block reads as "in focus".
		TypistFocus = { bg = blend(p.fg, p.bg, 0.05) },
		-- Untyped target text: readable, but clearly not "real" yet. Only fg is
		-- set, so the focus band stays visible behind it.
		TypistGhost = { fg = blend(p.fg, p.bg, 0.45) },
		TypistError = { fg = p.error, bg = blend(p.error, p.bg, 0.18), nocombine = true },
		-- Solid block: the editor cursor is hidden during a test, so this is the only one.
		TypistCursor = { fg = p.bg, bg = p.accent, nocombine = true },
		TypistNewline = { fg = p.accent },
		-- Comments inside the test: shown, but clearly not part of the typing.
		TypistSkipped = { fg = blend(p.comment, p.bg, 0.55), italic = true },
		-- Lines a hunk replaced, shown above it in diff mode.
		TypistDeleted = { fg = blend(p.removed, p.bg, 0.55), strikethrough = true },
		TypistHud = { fg = blend(p.fg, p.bg, 0.6), bg = p.float_bg },
		TypistHudValue = { fg = p.accent, bg = p.float_bg, bold = true },
		TypistHudLabel = { fg = blend(p.fg, p.float_bg, 0.45), bg = p.float_bg },
		TypistHudSep = { fg = blend(p.fg, p.float_bg, 0.25), bg = p.float_bg },
		TypistResult = { fg = p.fg, bg = p.float_bg },
		TypistResultBorder = { fg = p.border, bg = p.float_bg },
		TypistResultTitle = { fg = p.accent, bg = p.float_bg, bold = true },
		TypistResultValue = { fg = p.accent, bg = p.float_bg, bold = true },
		TypistResultGood = { fg = p.ok, bg = p.float_bg, bold = true },
		TypistResultBad = { fg = p.error, bg = p.float_bg, bold = true },
	}
	-- Approximate fallbacks for terminals without 'termguicolors' (256 colors).
	local dark = vim.o.background == "dark"
	local cterm = {
		TypistDim = { ctermfg = dark and 236 or 252 },
		TypistDimNr = { ctermfg = dark and 236 or 252 },
		TypistGhost = { ctermfg = dark and 242 or 246 },
		TypistSkipped = { ctermfg = dark and 238 or 250, cterm = { italic = true } },
		TypistError = { ctermfg = 1, ctermbg = dark and 52 or 224 },
		TypistCursor = { ctermfg = dark and 0 or 15, ctermbg = 6 },
		TypistNewline = { ctermfg = 6 },
		TypistDeleted = { ctermfg = dark and 95 or 181, cterm = { strikethrough = true } },
		TypistHudValue = { ctermfg = 6, cterm = { bold = true } },
		TypistResultTitle = { ctermfg = 6, cterm = { bold = true } },
		TypistResultValue = { ctermfg = 6, cterm = { bold = true } },
		TypistResultGood = { ctermfg = 2, cterm = { bold = true } },
		TypistResultBad = { ctermfg = 1, cterm = { bold = true } },
	}
	for name, extra in pairs(cterm) do
		groups[name] = vim.tbl_extend("force", groups[name], extra)
	end

	local overrides = require("typist.config").options.highlights or {}
	for name, spec in pairs(groups) do
		vim.api.nvim_set_hl(0, name, overrides[name] or spec)
	end
end

function M.setup()
	M.apply()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("typist_highlights", { clear = true }),
		callback = M.apply,
	})
end

return M
