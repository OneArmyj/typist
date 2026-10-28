-- Git-backed source of typing targets: the lines that changed in a buffer
-- compared to the index (or any revision), grouped into hunks.
local M = {}

-- vim.diff was renamed to vim.text.diff in 0.12.
---@diagnostic disable-next-line: deprecated
local diff = (vim.text and vim.text.diff) or vim.diff

local function run(args, cwd)
	local ok, result = pcall(function()
		return vim.system(args, { cwd = cwd, text = true }):wait(5000)
	end)
	if not ok then
		return { code = -1, stdout = "", stderr = tostring(result) }
	end
	return result
end

local function is_index(base)
	return base == nil or base == "" or base == "index"
end

---Human-readable name of a diff base, for messages.
function M.describe(base)
	return is_index(base) and "the index" or base
end

---Contents of `path` at `base` ("index" or a revision). A file that does not
---exist there yet (new / untracked) gives "".
---@return string|nil text, string|nil err
function M.base_text(path, base)
	local dir, name = vim.fs.dirname(path), vim.fs.basename(path)
	local object = (is_index(base) and "" or base) .. ":./" .. name
	local show = run({ "git", "show", object }, dir)
	if show.code == 0 then
		return show.stdout
	end
	if is_index(base) then
		-- A conflicted file has no stage-0 entry, so it would look untracked.
		local unmerged = run({ "git", "ls-files", "--unmerged", "--", name }, dir)
		if unmerged.code == 0 and unmerged.stdout ~= "" then
			return nil, "file has unresolved merge conflicts"
		end
	end
	-- The file is missing from `base`: fine if the repo (and revision) exist.
	local check = is_index(base) and run({ "git", "rev-parse", "--git-dir" }, dir)
		or run({ "git", "rev-parse", "--verify", "--quiet", base .. "^{commit}" }, dir)
	if check.code == 0 then
		return ""
	end
	if is_index(base) then
		return nil, "not inside a git repository"
	end
	return nil, ("unknown revision '%s'"):format(base)
end

---Changed hunks of `buf` against `base`, in buffer order.
---Each hunk: `{ first, last, deleted }`, 1-based buffer lines that were added
---or changed, plus the lines they replaced. Deletion-only hunks have
---`last < first`: there is nothing to type, so callers skip them.
---@return table[]|nil hunks, string|nil err
function M.hunks(buf, base)
	if vim.fn.executable("git") ~= 1 then
		return nil, "git is not installed or not on $PATH"
	end
	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" or vim.bo[buf].buftype ~= "" then
		return nil, "buffer is not a file"
	end
	if not vim.uv.fs_stat(vim.fs.dirname(path)) then
		return nil, "file's directory does not exist"
	end

	local base_text, err = M.base_text(path, base)
	if not base_text then
		return nil, err
	end
	if vim.bo[buf].fileformat == "dos" then
		base_text = base_text:gsub("\r\n", "\n")
	end
	if base_text ~= "" and base_text:sub(-1) ~= "\n" then
		base_text = base_text .. "\n"
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local current = (#lines == 1 and lines[1] == "") and "" or table.concat(lines, "\n") .. "\n"
	if current == base_text then
		return {}
	end

	local indices = diff(base_text, current, { result_type = "indices", algorithm = "histogram" }) --[[@as integer[][] ]]
	local base_lines = vim.split(base_text, "\n", { plain = true })
	local hunks = {}
	for _, h in ipairs(indices) do
		local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
		local deleted = {}
		for i = start_a, start_a + count_a - 1 do
			table.insert(deleted, base_lines[i])
		end
		if count_b > 0 then
			table.insert(hunks, { first = start_b, last = start_b + count_b - 1, deleted = deleted })
		else
			-- Pure deletion after line `start_b` (0 = top of file).
			table.insert(hunks, { first = start_b + 1, last = start_b, deleted = deleted })
		end
	end
	return hunks
end

-- Split a line into words, runs of blanks, and single other characters, as
-- `{ start, end }` byte positions (1-based, inclusive).
local function tokenize(line)
	local tokens, pos = {}, 1
	while pos <= #line do
		local s, e = line:find("^[%w_\128-\255]+", pos)
		if not s then
			s, e = line:find("^%s+", pos)
		end
		if not s then
			s, e = pos, pos
		end
		table.insert(tokens, { s, e })
		pos = e + 1
	end
	return tokens
end

local function token_text(line, tokens)
	local parts = {}
	for i, t in ipairs(tokens) do
		parts[i] = line:sub(t[1], t[2])
	end
	return #parts > 0 and table.concat(parts, "\n") .. "\n" or ""
end

local function non_blank(text)
	return #text:gsub("%s", "")
end

-- Byte ranges of `new` that are the same as in `old`, word by word, as
-- `{ start, end }` (0-based, end exclusive). Nil when the lines have too
-- little in common for that to help: then the whole line is typed.
local function unchanged_in_line(old, new)
	local a, b = tokenize(old), tokenize(new)
	if #a == 0 or #b == 0 then
		return nil
	end
	local kept, from, changed = {}, 1, 0
	for _, h in ipairs(diff(token_text(old, a), token_text(new, b), { result_type = "indices" })) do
		local start_b, count_b = h[3], h[4]
		if count_b > 0 then
			local s, e = b[start_b][1], b[start_b + count_b - 1][2]
			if s > from then
				table.insert(kept, { from - 1, s - 1 })
			end
			changed = changed + non_blank(new:sub(s, e))
			from = e + 1
		end
	end
	if from <= #new then
		table.insert(kept, { from - 1, #new })
	end
	if changed == 0 or changed * 2 > non_blank(new) then
		return nil
	end
	return kept
end

-- Largest hunk (old + new lines) that is searched for matching line pairs.
local LINEMATCH = 40

---For each line of `added` that is an edit of a line in `deleted`, the byte
---ranges that did not change: `{ [i] = { {start, end}, ... } }`. Lines that
---are new, or rewritten beyond recognition, have no entry.
---@param deleted string[]
---@param added string[]
function M.unchanged_parts(deleted, added)
	local result = {}
	if #deleted == 0 then
		return result
	end
	local old, new = table.concat(deleted, "\n") .. "\n", table.concat(added, "\n") .. "\n"
	local blocks = diff(old, new, { result_type = "indices", linematch = LINEMATCH }) --[[@as integer[][] ]]
	for _, h in ipairs(blocks) do
		local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
		-- Equal-sized blocks are line-for-line edits.
		if count_a == count_b then
			for i = 0, count_b - 1 do
				result[start_b + i] = unchanged_in_line(deleted[start_a + i], added[start_b + i])
			end
		end
	end
	return result
end

---Index of the hunk nearest to `row` (1-based). A hunk containing `row` has
---distance 0; on a tie the hunk above wins, so no change is left behind.
---@param hunks { first: integer, last: integer }[] in buffer order
function M.nearest(hunks, row)
	local nearest, best = 1, math.huge
	for i, h in ipairs(hunks) do
		local distance = (row < h.first and h.first - row) or (row > h.last and row - h.last) or 0
		if distance < best then
			nearest, best = i, distance
		end
	end
	return nearest
end

return M
