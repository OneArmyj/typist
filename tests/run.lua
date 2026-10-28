-- Minimal test runner: nvim --headless -l tests/run.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local passed, failed = 0, 0
_G.it = function(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. name .. "\n  " .. tostring(err))
	end
end
_G.eq = function(expected, actual, msg)
	if not vim.deep_equal(expected, actual) then
		error((msg or "") .. "\n  expected: " .. vim.inspect(expected) .. "\n  actual:   " .. vim.inspect(actual), 2)
	end
end

for _, spec in ipairs({ "engine_spec", "session_spec", "diff_spec" }) do
	require(spec)
end
print(("%d passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qall!")
