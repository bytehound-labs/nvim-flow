local M = {}

local uv = vim.uv or vim.loop
local ansi = require("nvim-flow.ansi")

M.last_output_lines = {}
M.last_command = nil
M.last_cmd_def = nil
M.last_terminal_buf = nil
M.last_terminal_win = nil

local current_buffer_job = nil

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_lines(text)
	local lines = {}
	text = (text or ""):gsub("\r\n", "\n")
	if text:sub(-1) ~= "\n" then
		text = text .. "\n"
	end
	for line in text:gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	return lines
end

local function max_line_width(lines)
	local max_width = 1
	for _, line in ipairs(lines) do
		max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
	end
	return max_width
end

local function normalize_output_line(line)
	line = (line or ""):gsub("\r+$", "")
	if line:find("\r", 1, true) then
		line = line:gsub(".*\r", "")
	end
	return line
end

function M.display_command(cmd)
	local lines = split_lines(cmd)
	local start_idx = 1
	if lines[1] and lines[1]:match("^#!") then
		start_idx = 2
	end

	local display_lines = {}
	for i = start_idx, #lines do
		table.insert(display_lines, lines[i])
	end
	return table.concat(display_lines, "\n")
end

local function build_script(cmd, show_command)
	local lines = split_lines(cmd)
	local hashbang = "#!/usr/bin/env bash"
	local start_idx = 1

	if lines[1] and lines[1]:match("^#!") then
		hashbang = lines[1]
		start_idx = 2
	end

	local clean_lines = {}
	for i = start_idx, #lines do
		if trim(lines[i]) ~= "clear" then
			table.insert(clean_lines, lines[i])
		end
	end

	local script_path = vim.fn.tempname()
	local fh, open_err = io.open(script_path, "w")
	if not fh then
		return nil, open_err
	end

	fh:write(hashbang .. "\n")
	if show_command then
		local display_cmd = M.display_command(cmd)
		fh:write("cat <<'NVIM_FLOW_CONTENT_EOF'\n")
		fh:write(display_cmd)
		if display_cmd:sub(-1) ~= "\n" then
			fh:write("\n")
		end
		fh:write("NVIM_FLOW_CONTENT_EOF\n")
		fh:write(("__nvim_flow_sep_len=%d\n"):format(max_line_width(split_lines(display_cmd))))
		fh:write('__nvim_flow_cols=$(tput cols 2>/dev/null || printf "%s" "$__nvim_flow_sep_len")\n')
		fh:write('case "$__nvim_flow_cols" in ""|*[!0-9]*) __nvim_flow_cols="$__nvim_flow_sep_len" ;; esac\n')
		fh:write(
			'if [ "$__nvim_flow_cols" -lt "$__nvim_flow_sep_len" ]; then __nvim_flow_sep_len="$__nvim_flow_cols"; fi\n'
		)
		fh:write('if [ "$__nvim_flow_sep_len" -lt 1 ]; then __nvim_flow_sep_len=1; fi\n')
		fh:write("printf '%*s\\n' \"$__nvim_flow_sep_len\" '' | tr ' ' '-'\n")
	end

	fh:write(table.concat(clean_lines, "\n"))
	fh:write("\n")
	fh:close()

	if uv and uv.fs_chmod then
		uv.fs_chmod(script_path, 493)
	else
		vim.fn.system({ "chmod", "+x", script_path })
	end

	return script_path
end

local function cleanup_script(script_path)
	if uv and uv.fs_unlink then
		uv.fs_unlink(script_path)
	else
		os.remove(script_path)
	end
end

-- Open a `terminal_height` split above/below the source window showing
-- `target_buf` and return its window handle, falling back to :topleft/:botright
-- when the nvim_open_win split API is unavailable.
local function open_split_window(target_buf, source_win, terminal_position, terminal_height)
	local opened, open_result = pcall(vim.api.nvim_open_win, target_buf, true, {
		split = terminal_position == "top" and "above" or "below",
		win = source_win,
		height = terminal_height,
	})
	if opened then
		return open_result
	end

	if terminal_position == "top" then
		vim.cmd(("topleft %dsplit"):format(terminal_height))
	else
		vim.cmd(("botright %dsplit"):format(terminal_height))
	end
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, target_buf)
	return win
end

-- Return focus to the source buffer's window after a run, re-displaying the
-- source buffer if its window was replaced and falling back to another window.
local function restore_source_window(source_win, source_buf)
	local target_win = source_win
	if not vim.api.nvim_win_is_valid(target_win) then
		target_win = nil
	end

	if target_win and vim.api.nvim_win_get_buf(target_win) ~= source_buf then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if vim.api.nvim_win_get_buf(win) == source_buf then
				target_win = win
				break
			end
		end
	end

	if not target_win then
		target_win = vim.api.nvim_tabpage_list_wins(0)[1]
		if target_win and vim.api.nvim_buf_is_valid(source_buf) then
			vim.api.nvim_win_set_buf(target_win, source_buf)
		end
	end

	if target_win and vim.api.nvim_win_is_valid(target_win) then
		if vim.api.nvim_buf_is_valid(source_buf) and vim.api.nvim_win_get_buf(target_win) ~= source_buf then
			vim.api.nvim_win_set_buf(target_win, source_buf)
		end
		vim.api.nvim_set_current_win(target_win)
	end
end

function M._build_script_for_test(cmd, show_command)
	return build_script(cmd, show_command)
end

function M._cleanup_script_for_test(script_path)
	cleanup_script(script_path)
end

function M.get_last_output()
	if M.last_terminal_buf and vim.api.nvim_buf_is_valid(M.last_terminal_buf) then
		M.last_output_lines = vim.api.nvim_buf_get_lines(M.last_terminal_buf, 0, -1, false)
	end
	return vim.deepcopy(M.last_output_lines)
end

local function build_buffer_header(cmd)
	local display_cmd = M.display_command(cmd)
	local display_lines = split_lines(display_cmd)
	local sep_width = max_line_width(display_lines)
	if sep_width < 1 then
		sep_width = 1
	end
	local header = {}
	for _, line in ipairs(display_lines) do
		table.insert(header, line)
	end
	table.insert(header, string.rep("-", sep_width))
	return header
end

local function build_buffer_name(cmd_def, exit_code)
	local source_key = cmd_def.source_key or "run"
	if exit_code == nil then
		return ("flow://%s [running]"):format(source_key)
	end
	if exit_code == 0 then
		return ("flow://%s [done]"):format(source_key)
	end
	return ("flow://%s [failed:%d]"):format(source_key, exit_code)
end

local function job_is_running(job_id)
	if type(job_id) ~= "number" or job_id <= 0 then
		return false
	end
	local status = vim.fn.jobwait({ job_id }, 0)[1]
	return status == -1
end

function M.is_buffer_job_running(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	local ok, job_id = pcall(function()
		return vim.b[bufnr].nvim_flow_job_id
	end)
	if not ok then
		return false
	end

	return job_is_running(job_id)
end

function M.interrupt_buffer_job(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not M.is_buffer_job_running(bufnr) then
		return false
	end

	vim.fn.chansend(vim.b[bufnr].nvim_flow_job_id, string.char(3))
	return true
end

--- Send raw text to a running buffer-mode job's stdin (PTY).
--- Text is sent verbatim; include a trailing "\n" to submit a line.
---@param bufnr number|nil Buffer handle (defaults to current)
---@param text string Text to send
---@return boolean sent
function M.send_buffer_input(bufnr, text)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if type(text) ~= "string" or not M.is_buffer_job_running(bufnr) then
		return false
	end

	vim.fn.chansend(vim.b[bufnr].nvim_flow_job_id, text)
	return true
end

--- Prompt for a line of input and send it (with newline) to a buffer-mode job.
---@param bufnr number|nil Buffer handle (defaults to current)
function M.prompt_buffer_input(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not M.is_buffer_job_running(bufnr) then
		return
	end

	vim.ui.input({ prompt = "flow input> " }, function(input)
		if input == nil then
			return
		end
		M.send_buffer_input(bufnr, input .. "\n")
	end)
end

local function run_buffer(cmd_def, opts)
	local show_command = opts.show_command ~= false
	local terminal_height = tonumber(opts.terminal_height) or 15
	local terminal_position = opts.terminal_position == "bottom" and "bottom" or "top"
	local source_win = vim.api.nvim_get_current_win()
	local source_buf = vim.api.nvim_get_current_buf()

	local script_path, script_err = build_script(cmd_def.cmd, false)
	if not script_path then
		return false, script_err
	end

	M.last_output_lines = {}
	M.last_command = cmd_def.cmd
	M.last_cmd_def = vim.deepcopy(cmd_def)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.b[buf].nvim_flow_terminal = 1
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	local buf_name = build_buffer_name(cmd_def)
	pcall(vim.api.nvim_buf_set_name, buf, buf_name)

	local buf_win = open_split_window(buf, source_win, terminal_position, terminal_height)

	vim.wo[buf_win].wrap = true
	vim.wo[buf_win].linebreak = true
	vim.wo[buf_win].number = false
	vim.wo[buf_win].relativenumber = false
	vim.wo[buf_win].signcolumn = "no"

	M.last_terminal_buf = buf
	M.last_terminal_win = buf_win

	local header_lines = {}
	if show_command then
		header_lines = build_buffer_header(cmd_def.cmd)
	end

	vim.bo[buf].modifiable = true
	if #header_lines > 0 then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, header_lines)
	end
	vim.bo[buf].modifiable = false

	-- Start at the bottom so streamed output auto-follows until the user scrolls up.
	if vim.api.nvim_win_is_valid(buf_win) and vim.api.nvim_win_get_buf(buf_win) == buf then
		local initial_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
		pcall(vim.api.nvim_win_set_cursor, buf_win, { initial_line, 0 })
	end

	local collected = { "" }
	-- Rendering the whole buffer is O(lines), so doing it on every stdout chunk
	-- starves input handling during fast output (e.g. a key like `k` to stop the
	-- auto-follow is delayed by several lines). Coalesce chunks and render at most
	-- once per interval so the event loop stays responsive.
	local render_pending = false
	local render_done = false
	local RENDER_THROTTLE_MS = 40

	local function output_lines_snapshot()
		local lines = vim.deepcopy(collected)

		if #lines > 0 and lines[#lines] == "" then
			table.remove(lines)
		end

		for i, line in ipairs(lines) do
			lines[i] = ansi.sanitize(normalize_output_line(line))
		end

		local filtered = {}
		for _, line in ipairs(lines) do
			if not line:match("^stty:.*Inappropriate ioctl") then
				table.insert(filtered, line)
			end
		end

		return filtered
	end

	local function render_output(exit_code)
		local lines = output_lines_snapshot()
		local all_lines = {}
		for _, hl in ipairs(header_lines) do
			table.insert(all_lines, hl)
		end
		for _, ol in ipairs(lines) do
			table.insert(all_lines, ol)
		end

		M.last_output_lines = ansi.strip_lines(vim.deepcopy(all_lines))

		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end

		local should_follow = false
		if vim.api.nvim_win_is_valid(buf_win) and vim.api.nvim_win_get_buf(buf_win) == buf then
			local cursor_line = vim.api.nvim_win_get_cursor(buf_win)[1]
			local buffer_line_count = vim.api.nvim_buf_line_count(buf)
			should_follow = cursor_line >= buffer_line_count
		end

		if exit_code ~= nil then
			pcall(vim.api.nvim_buf_set_name, buf, build_buffer_name(cmd_def, exit_code))
		end

		local display_lines = ansi.strip_lines(vim.deepcopy(lines))
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, #header_lines, -1, false, display_lines)
		ansi.clear_buffer(buf, #header_lines, -1)
		ansi.highlight_buffer(buf, lines, #header_lines)
		vim.bo[buf].modifiable = false

		if should_follow and vim.api.nvim_win_is_valid(buf_win) and vim.api.nvim_win_get_buf(buf_win) == buf then
			local line_count = math.max(vim.api.nvim_buf_line_count(buf), 1)
			vim.api.nvim_win_set_cursor(buf_win, { line_count, 0 })
		end
	end

	local function schedule_render()
		if render_pending or render_done then
			return
		end
		render_pending = true
		vim.defer_fn(function()
			render_pending = false
			if render_done then
				return
			end
			render_output()
		end, RENDER_THROTTLE_MS)
	end

	local function on_output(job_id, data, _)
		if current_buffer_job and job_id ~= current_buffer_job then
			return
		end

		if not data or #data == 0 then
			return
		end
		collected[#collected] = collected[#collected] .. (data[1] or "")
		for i = 2, #data do
			table.insert(collected, data[i])
		end

		schedule_render()
	end

	local function on_exit(job_id, exit_code)
		if vim.api.nvim_buf_is_valid(buf) then
			if vim.b[buf].nvim_flow_job_id == job_id then
				vim.b[buf].nvim_flow_job_id = nil
			end
			pcall(vim.keymap.del, "n", "<C-c>", { buffer = buf })
			for _, key in ipairs({ "i", "a", "I", "A" }) do
				pcall(vim.keymap.del, "n", key, { buffer = buf })
			end
		end

		-- Ignore stale callbacks from superseded runs
		if job_id ~= current_buffer_job then
			cleanup_script(script_path)
			return
		end
		current_buffer_job = nil

		render_done = true
		render_pending = false
		render_output(exit_code)

		cleanup_script(script_path)
	end

	-- Run under a PTY so terminal-aware programs (including code that
	-- calls `stty size`) see a real terminal size, while we still render
	-- the captured output into a normal buffer.
	local env = vim.fn.environ()
	env.COLUMNS = tostring(vim.api.nvim_win_get_width(buf_win))
	env.LINES = tostring(vim.api.nvim_win_get_height(buf_win))

	local job = vim.fn.jobstart(script_path, {
		env = env,
		pty = true,
		cwd = cmd_def.cwd,
		width = vim.api.nvim_win_get_width(buf_win),
		height = vim.api.nvim_win_get_height(buf_win),
		on_stdout = on_output,
		on_exit = on_exit,
	})

	if job <= 0 then
		cleanup_script(script_path)
		restore_source_window(source_win, source_buf)
		return false, "failed to start job"
	end

	current_buffer_job = job
	vim.b[buf].nvim_flow_job_id = job
	vim.keymap.set("n", "<C-c>", function()
		M.interrupt_buffer_job(buf)
	end, {
		buffer = buf,
		silent = true,
		nowait = true,
		desc = "Flow interrupt",
	})

	-- The output buffer is a non-terminal scratch buffer, so the usual insert
	-- keys do nothing. While the PTY job is alive, repurpose them to prompt for
	-- a line of input and forward it to the job's stdin (e.g. answering a y/n
	-- prompt), mirroring pressing `i` to interact in terminal mode.
	for _, key in ipairs({ "i", "a", "I", "A" }) do
		vim.keymap.set("n", key, function()
			M.prompt_buffer_input(buf)
		end, {
			buffer = buf,
			silent = true,
			nowait = true,
			desc = "Flow send input",
		})
	end

	restore_source_window(source_win, source_buf)
	return true
end

function M.run(cmd_def, opts)
	opts = opts or {}

	if opts.output_mode == "buffer" then
		return run_buffer(cmd_def, opts)
	end

	local show_command = opts.show_command ~= false
	local terminal_height = tonumber(opts.terminal_height) or 15
	local terminal_position = opts.terminal_position == "bottom" and "bottom" or "top"
	local source_win = vim.api.nvim_get_current_win()
	local source_buf = vim.api.nvim_get_current_buf()

	local script_path, script_err = build_script(cmd_def.cmd, show_command)
	if not script_path then
		return false, script_err
	end

	M.last_output_lines = {}
	M.last_command = cmd_def.cmd
	M.last_cmd_def = vim.deepcopy(cmd_def)
	local term_buf = vim.api.nvim_create_buf(true, false)
	vim.b[term_buf].nvim_flow_terminal = 1
	local term_win = open_split_window(term_buf, source_win, terminal_position, terminal_height)
	M.last_terminal_buf = term_buf
	M.last_terminal_win = term_win

	local function capture_terminal_output()
		if term_buf and vim.api.nvim_buf_is_valid(term_buf) then
			M.last_output_lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
		end
	end

	vim.api.nvim_set_current_win(term_win)
	local job = vim.fn.termopen(script_path, {
		cwd = cmd_def.cwd,
		on_exit = function()
			vim.schedule(function()
				-- Only capture if this terminal is still the active one
				if M.last_terminal_buf == term_buf then
					capture_terminal_output()
				end
				cleanup_script(script_path)
			end)
		end,
	})

	if job <= 0 then
		cleanup_script(script_path)
		restore_source_window(source_win, source_buf)
		return false, "failed to start terminal job"
	end

	vim.cmd("normal! G")
	restore_source_window(source_win, source_buf)

	return true
end

function M._build_buffer_header_for_test(cmd)
	return build_buffer_header(cmd)
end

return M
