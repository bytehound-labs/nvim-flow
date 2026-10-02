local config = require("nvim-flow.config")
local lock = require("nvim-flow.lock")
local markdown = require("nvim-flow.markdown")
local runner = require("nvim-flow.runner")
local debug_runner = require("nvim-flow.debug_runner")
local preview = require("nvim-flow.preview")
local quickfix = require("nvim-flow.quickfix")

local M = {}

local defaults = {
	config_file = ".flow.yml",
	cwd = "repo",
	terminal_height = 15,
	terminal_position = "top",
	output_mode = "buffer",
	edit_open_command = "tabedit",
	stop_at_home = true,
	show_command = true,
	keymaps = {
		run = nil,
		debug = nil,
		edit = nil,
		toggle_lock = nil,
		preview = nil,
		quickfix = nil,
	},
}

local state = {
	opts = vim.deepcopy(defaults),
}

local function notify(message, level)
	vim.notify("nvim-flow: " .. message, level or vim.log.levels.INFO)
end

local function current_filepath()
	local filepath = vim.api.nvim_buf_get_name(0)
	if filepath == "" then
		return nil
	end
	return vim.fs.normalize(filepath)
end

local function resolve_cmd_def()
	local filepath = lock.get() or current_filepath()
	if not filepath then
		notify("current buffer has no file path", vim.log.levels.WARN)
		return nil
	end

	local cmd_def, err = config.resolve(filepath, state.opts)
	if not cmd_def then
		notify(err, vim.log.levels.ERROR)
		return nil
	end
	return cmd_def
end

local function current_buffer_snapshot()
	local buf = vim.api.nvim_get_current_buf()
	return {
		buf = buf,
		name = vim.api.nvim_buf_get_name(buf),
		filetype = vim.bo[buf].filetype,
		lnum = vim.api.nvim_win_get_cursor(0)[1],
		lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
	}
end

local function normalize_snapshot(snapshot)
	snapshot = snapshot or current_buffer_snapshot()
	local buf = snapshot.buf

	if snapshot.name == nil and buf and vim.api.nvim_buf_is_valid(buf) then
		snapshot.name = vim.api.nvim_buf_get_name(buf)
	end
	if snapshot.filetype == nil and buf and vim.api.nvim_buf_is_valid(buf) then
		snapshot.filetype = vim.bo[buf].filetype
	end
	if snapshot.lnum == nil then
		snapshot.lnum = vim.api.nvim_win_get_cursor(0)[1]
	end
	if snapshot.lines == nil then
		if not buf or not vim.api.nvim_buf_is_loaded(buf) then
			return nil, "source buffer is no longer available"
		end
		snapshot.lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	end
	return snapshot
end

local function is_flow_config_name(name)
	return name ~= "" and vim.fs.basename(name) == (state.opts.config_file or ".flow.yml")
end

local function is_markdown_snapshot(snapshot)
	if is_flow_config_name(snapshot.name or "") then
		return false
	end

	if snapshot.filetype == "markdown" then
		return true
	end

	local name = vim.fs.basename(snapshot.name or ""):lower()
	return name:match("%.md$") ~= nil or name:match("%.markdown$") ~= nil
end

local function is_cursor_run_snapshot(snapshot)
	return is_flow_config_name(snapshot.name or "") or is_markdown_snapshot(snapshot)
end

local function setup_keymaps()
	local keymaps = state.opts.keymaps or {}
	local group = vim.api.nvim_create_augroup("NvimFlowKeymaps", { clear = true })

	local function pre_flow_action()
		vim.cmd("wa")
		if vim.fn.exists("*CloseAll") == 1 then
			pcall(vim.cmd, "call CloseAll()")
		end
	end

	local function run_here_from_current()
		local snapshot = current_buffer_snapshot()
		pre_flow_action()
		require("nvim-flow").run_here(snapshot)
	end

	local function set_run_mapping(bufnr)
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		if vim.bo[bufnr].buftype ~= "" then
			return
		end

		-- One keymap, context-aware: inside a flow config or Markdown buffer it
		-- runs the entry or shell block under the cursor.
		vim.keymap.set("n", keymaps.run, function()
			local bufnr = vim.api.nvim_get_current_buf()
			local snapshot = {
				name = vim.api.nvim_buf_get_name(bufnr),
				filetype = vim.bo[bufnr].filetype,
			}
			if is_cursor_run_snapshot(snapshot) then
				run_here_from_current()
			else
				pre_flow_action()
				require("nvim-flow").run()
			end
		end, { buffer = bufnr, silent = true, desc = "Flow run" })
	end

	if keymaps.run then
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(bufnr) then
				set_run_mapping(bufnr)
			end
		end

		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			pattern = "*",
			callback = function(event)
				set_run_mapping(event.buf)
			end,
		})
	end

	if keymaps.debug then
		vim.keymap.set("n", keymaps.debug, function()
			local snapshot = current_buffer_snapshot()
			local markdown_buffer = is_markdown_snapshot(snapshot)
			pre_flow_action()
			require("nvim-flow").debug(markdown_buffer and snapshot or nil)
		end, { silent = true, desc = "Flow debug" })
	end

	if keymaps.edit then
		vim.keymap.set("n", keymaps.edit, function()
			require("nvim-flow").edit()
		end, { silent = true, desc = "Flow edit" })
	end

	if keymaps.toggle_lock then
		vim.keymap.set("n", keymaps.toggle_lock, function()
			require("nvim-flow").toggle_lock()
		end, { silent = true, desc = "Flow toggle lock" })
	end

	if keymaps.preview then
		vim.keymap.set("n", keymaps.preview, function()
			require("nvim-flow").preview()
		end, { silent = true, desc = "Flow preview" })
	end

	if keymaps.quickfix then
		vim.keymap.set("n", keymaps.quickfix, function()
			require("nvim-flow").quickfix()
		end, { silent = true, desc = "Flow quickfix" })
	end
end

function M.setup(opts)
	if opts and opts.cwd ~= nil and opts.cwd ~= "repo" and opts.cwd ~= "nvim" then
		error(("nvim-flow: invalid cwd policy `%s`; expected `repo` or `nvim`"):format(tostring(opts.cwd)))
	end
	state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	setup_keymaps()
end

local function execute_cmd_def(cmd_def)
	if cmd_def.runner == "debug" then
		debug_runner.run(cmd_def)
		return
	end

	local ok, err = runner.run(cmd_def, state.opts)
	if not ok then
		notify(err, vim.log.levels.ERROR)
	end
end

function M.run()
	local cmd_def = resolve_cmd_def()
	if not cmd_def then
		return
	end

	execute_cmd_def(cmd_def)
end

local function resolve_cursor_cmd_def(snapshot)
	local name = snapshot.name or ""
	if name == "" then
		return nil, "current buffer has no file path"
	end

	if is_flow_config_name(name) then
		local key = config.find_key_at_line(snapshot.lines, snapshot.lnum)
		if not key then
			return nil, "cursor is not on a flow entry"
		end
		return config.resolve_at(vim.fs.normalize(name), key, state.opts, table.concat(snapshot.lines, "\n"))
	end

	if is_markdown_snapshot(snapshot) then
		return markdown.resolve_at(vim.fs.normalize(name), snapshot.lines, snapshot.lnum, state.opts)
	end

	return nil,
		("run here only works inside a `%s` buffer or a Markdown file"):format(state.opts.config_file or ".flow.yml")
end

local function resolve_action_cmd_def(snapshot)
	if not is_markdown_snapshot(snapshot) then
		return resolve_cmd_def()
	end
	if not snapshot.name or snapshot.name == "" then
		return nil, "current buffer has no file path"
	end
	return markdown.resolve_at(vim.fs.normalize(snapshot.name), snapshot.lines, snapshot.lnum, state.opts)
end

--- Run the flow entry or shell block under the cursor.
--- `snapshot` (optional) preserves cursor and buffer contents across pre-run actions.
function M.run_here(snapshot)
	local current, snapshot_err = normalize_snapshot(snapshot)
	if not current then
		notify(snapshot_err, vim.log.levels.ERROR)
		return
	end

	if not current.name or current.name == "" then
		notify("current buffer has no file path", vim.log.levels.WARN)
		return
	end

	if not is_flow_config_name(current.name or "") and not is_markdown_snapshot(current) then
		notify(
			("run here only works inside a `%s` buffer"):format(state.opts.config_file or ".flow.yml"),
			vim.log.levels.WARN
		)
		return
	end

	local cmd_def, err = resolve_cursor_cmd_def(current)
	if not cmd_def then
		notify(err, vim.log.levels.ERROR)
		return
	end

	execute_cmd_def(cmd_def)
end

function M.debug(snapshot)
	local current, snapshot_err = normalize_snapshot(snapshot)
	if not current then
		notify(snapshot_err, vim.log.levels.ERROR)
		return
	end

	local cmd_def, err = resolve_action_cmd_def(current)
	if not cmd_def then
		if err then
			notify(err, vim.log.levels.ERROR)
		end
		return
	end
	debug_runner.run(cmd_def)
end

function M.preview(snapshot)
	local current, snapshot_err = normalize_snapshot(snapshot)
	if not current then
		notify(snapshot_err, vim.log.levels.ERROR)
		return
	end

	local cmd_def, err = resolve_action_cmd_def(current)
	if not cmd_def then
		if err then
			notify(err, vim.log.levels.ERROR)
		end
		return
	end
	preview.open(runner.display_command(cmd_def.cmd), {
		title = "Flow Preview (" .. cmd_def.source_key .. ")",
		cwd = cmd_def.cwd,
	})
end

function M.edit()
	local cmd_def = resolve_cmd_def()
	if not cmd_def then
		return
	end

	local location, location_err = config.find_source_location(cmd_def.source_key, cmd_def.source_files)
	if not location then
		notify(location_err, vim.log.levels.ERROR)
		return
	end

	local open_cmd = state.opts.edit_open_command or "tabedit"
	local escaped_path = vim.fn.fnameescape(location.file)
	local opened, open_err = pcall(vim.cmd, ("%s %s"):format(open_cmd, escaped_path))
	if not opened then
		notify(("failed to open flow file via `%s`: %s"):format(open_cmd, open_err), vim.log.levels.ERROR)
		return
	end

	local line = tonumber(location.line) or 1
	pcall(vim.api.nvim_win_set_cursor, 0, { math.max(line, 1), 0 })
	vim.cmd("normal! zz")
end

function M.quickfix()
	local lines = runner.get_last_output()
	if #lines == 0 then
		notify("no terminal output available from previous FlowRun", vim.log.levels.WARN)
		return
	end

	local cwd = runner.last_cmd_def and runner.last_cmd_def.cwd or nil
	local ok, err = quickfix.populate_python(lines, "nvim-flow traceback", cwd)
	if not ok then
		notify(err, vim.log.levels.WARN)
		return
	end
	vim.cmd("copen")
end

function M.toggle_lock(filepath)
	if filepath and filepath ~= "" then
		lock.set(filepath)
		notify("file lock set: " .. filepath)
		return
	end

	local current = lock.get()
	if current then
		lock.clear()
		notify("file lock released")
		return
	end

	local active_file = current_filepath()
	if not active_file then
		notify("current buffer has no file path", vim.log.levels.WARN)
		return
	end
	lock.set(active_file)
	notify("file lock set: " .. active_file)
end

return M
