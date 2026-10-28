-- Finds comments in a range of buffer lines, so they can be shown but not typed.
local M = {}

local function add(by_row, row, s, e)
	by_row[row] = by_row[row] or {}
	table.insert(by_row[row], { s, e })
end

-- Comments as highlighted by treesitter, including injected languages.
-- Returns nil when the buffer has no parser.
local function from_treesitter(buf, first, last)
	local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
	if not ok or not parser then
		return nil
	end
	-- Only the rows we need: cheap even in huge files.
	parser:parse({ first, last + 1 })
	local by_row = {}
	parser:for_each_tree(function(tree, ltree)
		local query = vim.treesitter.query.get(ltree:lang(), "highlights")
		if not query then
			return
		end
		for id, node in query:iter_captures(tree:root(), buf, first, last + 1) do
			local name = query.captures[id]
			if name == "comment" or vim.startswith(name, "comment.") then
				local sr, sc, er, ec = node:range()
				for row = math.max(sr, first), math.min(er, last) do
					add(by_row, row, row == sr and sc or 0, row == er and ec or math.huge)
				end
			end
		end
	end)
	return by_row
end

-- Without treesitter: whole lines that start with 'commentstring'.
local function from_commentstring(buf, first, last)
	local by_row = {}
	local prefix = vim.trim((vim.bo[buf].commentstring:match("^(.-)%%s") or ""))
	if prefix == "" then
		return by_row
	end
	for i, text in ipairs(vim.api.nvim_buf_get_lines(buf, first, last + 1, false)) do
		local indent = #text:match("^%s*")
		if text:sub(indent + 1, indent + #prefix) == prefix then
			add(by_row, first + i - 1, indent, math.huge)
		end
	end
	return by_row
end

---Comment byte ranges on 0-based rows `first`..`last`, by row:
---`{ [row] = { {start, end}, ... } }`, end exclusive.
function M.ranges(buf, first, last)
	return from_treesitter(buf, first, last) or from_commentstring(buf, first, last)
end

return M
