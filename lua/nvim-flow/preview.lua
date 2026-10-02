local M = {}

local preview_ns = vim.api.nvim_create_namespace("nvim-flow-preview")

local function split_lines(text)
	local lines = {}
	text = (text or ""):gsub("\r\n", "\n")
	if text == "" then
		return { "" }
	end
	if text:sub(-1) ~= "\n" then
		text = text .. "\n"
	end
	for line in text:gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	return lines
end

function M.open(command, opts)
	opts = opts or {}
	local lines = split_lines(command)
	if opts.cwd and opts.cwd ~= "" then
		local with_cwd = { "Working directory: " .. opts.cwd, "" }
		vim.list_extend(with_cwd, lines)
		lines = with_cwd
	end

	local width = 40
	for _, line in ipairs(lines) do
		width = math.max(width, #line + 2)
	end
	width = math.min(width, math.floor(vim.o.columns * 0.9))

	local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))
	if height < 3 then
		height = 3
	end

	local row = math.floor((vim.o.lines - height) / 2 - 1)
	local col = math.floor((vim.o.columns - width) / 2)
	if row < 0 then
		row = 0
	end
	if col < 0 then
		col = 0
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "sh"
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = width,
		height = height,
		row = row,
		col = col,
		title = opts.title or "Flow Preview",
		title_pos = "center",
	})

	local closed = false
	local function close_preview()
		if closed then
			return
		end
		closed = true
		vim.on_key(nil, preview_ns)
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	vim.on_key(function()
		close_preview()
	end, preview_ns)

	vim.api.nvim_create_autocmd("WinClosed", {
		once = true,
		callback = function(event)
			if tonumber(event.match) == win then
				vim.on_key(nil, preview_ns)
			end
		end,
	})

	return win
end

return M
