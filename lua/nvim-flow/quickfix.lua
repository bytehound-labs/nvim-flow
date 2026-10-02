local M = {}
local path = require("nvim-flow.path")

local function resolve_filename(filename, cwd)
	if not cwd or path.is_absolute(filename) then
		return filename
	end
	return vim.fs.normalize(cwd .. "/" .. filename)
end

function M.parse_python_traceback(lines, cwd)
	local items = {}
	for i, line in ipairs(lines or {}) do
		local filename, lnum = line:match('^%s*File "([^"]+)", line (%d+), in ')
		if filename and lnum then
			local text = ""
			for j = i + 1, math.min(i + 2, #lines) do
				local next_line = lines[j]
				if next_line and next_line ~= "" then
					text = vim.trim(next_line)
					break
				end
			end

			table.insert(items, {
				filename = resolve_filename(filename, cwd),
				lnum = tonumber(lnum),
				col = 1,
				text = text ~= "" and text or line,
			})
		end
	end
	return items
end

function M.populate_python(lines, title, cwd)
	local items = M.parse_python_traceback(lines, cwd)
	if #items == 0 then
		return false, "No Python traceback entries found in the last flow output."
	end

	vim.fn.setqflist({}, " ", {
		title = title or "nvim-flow traceback",
		items = items,
	})
	return true
end

return M
