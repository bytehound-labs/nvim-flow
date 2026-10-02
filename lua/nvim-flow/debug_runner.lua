local M = {}

local function split_words(line)
	local words = {}
	for word in (line or ""):gmatch("%S+") do
		table.insert(words, word)
	end
	return words
end

local function normalize_arg(arg)
	if not arg then
		return arg
	end
	arg = arg:gsub("^'({.-})'$", "%1")
	arg = arg:gsub('^"(.-)"$', "%1")
	arg = arg:gsub("^'(.-)'$", "%1")
	return arg
end

local function command_line_from_script(cmd)
	local first_line = cmd:match("([^\n]+)")
	if first_line and first_line:match("^#!") then
		return cmd:match("^#![^\n]*\n([^\n]+)")
	end
	return first_line
end

local function parse_command(cmd)
	local line = command_line_from_script(cmd or "")
	if not line then
		return nil
	end

	local words = split_words(line)
	if #words == 0 then
		return nil
	end

	local adapter = words[1]
	local program = nil
	local module = nil
	local args_start = nil

	if adapter == "python" or adapter == "python3" then
		adapter = "python"
		if words[2] == "-m" then
			module = words[3]
			args_start = 4
		else
			program = words[2]
			args_start = 3
		end
	elseif adapter == "uv" then
		adapter = "python"
		if words[2] == "run" and words[3] == "python" and words[4] == "-m" then
			module = words[5]
			args_start = 6
		elseif words[2] == "run" and words[3] == "-m" then
			module = words[4]
			args_start = 5
		elseif words[2] == "run" and words[3] == "python" then
			program = words[4]
			args_start = 5
		elseif words[2] == "run" then
			program = words[3]
			args_start = 4
		elseif words[2] == "-m" then
			module = words[3]
			args_start = 4
		else
			program = words[2]
			args_start = 3
		end
	elseif adapter == "node" then
		program = words[2]
		args_start = 3
	else
		return nil
	end

	local args = {}
	for i = args_start or (#words + 1), #words do
		table.insert(args, normalize_arg(words[i]))
	end

	return {
		adapter = adapter,
		program = normalize_arg(program),
		module = normalize_arg(module),
		args = args,
	}
end

local function find_venv_python(start_filepath)
	local current_dir = start_filepath and vim.fs.dirname(start_filepath) or vim.fn.getcwd()
	if not current_dir or current_dir == "" then
		current_dir = vim.fn.getcwd()
	end

	while current_dir and current_dir ~= "/" do
		local venv_python = current_dir .. "/.venv/bin/python"
		if vim.fn.executable(venv_python) == 1 then
			return venv_python
		end
		local parent = vim.fs.dirname(current_dir)
		if not parent or parent == current_dir then
			break
		end
		current_dir = parent
	end

	return "python"
end

local function build_adapter_config(parsed, cmd_def)
	if parsed.adapter == "python" then
		local cfg = {
			name = "python",
			type = "python",
			request = "launch",
			console = "integratedTerminal",
			cwd = cmd_def.cwd,
			pythonPath = function()
				return find_venv_python(cmd_def.filepath)
			end,
		}
		if parsed.module and parsed.module ~= "" then
			cfg.module = parsed.module
		else
			cfg.program = parsed.program
		end
		if #parsed.args > 0 then
			cfg.args = parsed.args
		end
		return cfg
	end

	if parsed.adapter == "node" then
		local cfg = {
			name = "node",
			type = "node",
			request = "launch",
			console = "integratedTerminal",
			cwd = cmd_def.cwd,
			program = parsed.program,
		}
		if #parsed.args > 0 then
			cfg.args = parsed.args
		end
		return cfg
	end

	return nil
end

function M.run(cmd_def)
	local ok_dap, dap = pcall(require, "dap")
	if not ok_dap then
		vim.notify("nvim-flow: debug runner requires nvim-dap", vim.log.levels.ERROR)
		return false
	end

	local parsed = parse_command(cmd_def.cmd)
	if not parsed then
		-- Unrecognized command (e.g. dotnet); fall through to existing dap config
		dap.continue()
		return true
	end

	local config = build_adapter_config(parsed, cmd_def)
	if not config then
		dap.continue()
		return true
	end

	if not config.module and not config.program then
		dap.continue()
		return true
	end

	local filetype = vim.bo.filetype
	dap.configurations[filetype] = {}
	table.insert(dap.configurations[filetype], config)
	dap.continue()
	return true
end

return M
