local flow = require("nvim-flow")
local lock = require("nvim-flow.lock")
local preview = require("nvim-flow.preview")
local runner = require("nvim-flow.runner")
local debug_runner = require("nvim-flow.debug_runner")

local function write_file(filepath, contents)
	vim.fn.mkdir(vim.fs.dirname(filepath), "p")
	local file = assert(io.open(filepath, "w"))
	file:write(contents)
	file:close()
end

local function open_markdown(filepath, lines)
	write_file(filepath, "# Saved content\n")
	vim.cmd("edit! " .. vim.fn.fnameescape(filepath))
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
end

local function wait_for_output(expected)
	return vim.wait(5000, function()
		for _, line in ipairs(runner.get_last_output()) do
			if line:find(expected, 1, true) then
				return true
			end
		end
		return false
	end, 25)
end

describe("nvim-flow run_here integration", function()
	local root = nil

	before_each(function()
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		runner.last_cmd_def = nil
		runner.last_command = nil
		lock.clear()
		flow.setup({ output_mode = "buffer", show_command = false, terminal_height = 5 })
	end)

	after_each(function()
		lock.clear()
		vim.cmd("silent! only")
		vim.cmd("silent! %bwipeout!")
		if root then
			vim.fn.delete(root, "rf")
		end
	end)

	it("runs the entry under the cursor from a .flow.yml buffer", function()
		local flow_file = root .. "/proj/.flow.yml"
		vim.fn.mkdir(root .. "/proj", "p")
		local fh = assert(io.open(flow_file, "w"))
		fh:write("first:\n  cmd: echo one\n\nsecond:\n  cmd: echo two\n")
		fh:close()

		vim.cmd("edit " .. vim.fn.fnameescape(flow_file))
		vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- inside `second`

		flow.run_here()

		assert.is_not_nil(runner.last_cmd_def)
		assert.are.equal("second", runner.last_cmd_def.source_key)
		assert.is_true(runner.last_command:find("echo two", 1, true) ~= nil)
	end)

	it("does not run when the buffer is not a flow config file", function()
		local other = root .. "/notes.txt"
		local fh = assert(io.open(other, "w"))
		fh:write("hello\n")
		fh:close()
		vim.cmd("edit " .. vim.fn.fnameescape(other))

		flow.run_here()
		assert.is_nil(runner.last_cmd_def)
	end)

	it("dispatches the run keymap to a YAML cursor entry", function()
		local filepath = root .. "/.flow.yml"
		write_file(filepath, "run:\n  cmd: printf 'yaml-keymap-run\\n'\n")
		flow.setup({
			output_mode = "buffer",
			show_command = false,
			terminal_height = 5,
			keymaps = { run = "<F4>" },
		})
		vim.cmd("edit " .. vim.fn.fnameescape(filepath))
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F4>", true, false, true), "x", false)

		assert.is_true(wait_for_output("yaml-keymap-run"))
		assert.are.equal("run", runner.last_cmd_def.source_key)
	end)

	it("keeps YAML cursor execution independent of the Markdown parser", function()
		local filepath = root .. "/.flow.yml"
		write_file(filepath, "run:\n  cmd: echo yaml-without-markdown-parser\n")
		vim.cmd("edit " .. vim.fn.fnameescape(filepath))
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		local original = vim.treesitter.get_string_parser
		vim.treesitter.get_string_parser = function()
			error("missing markdown parser")
		end
		local ok, err = pcall(flow.run_here)
		vim.treesitter.get_string_parser = original

		assert.is_true(ok, err)
		assert.is_not_nil(runner.last_cmd_def)
		assert.are.equal("run", runner.last_cmd_def.source_key)
	end)

	it("runs a Markdown shell block from the live buffer in both output modes", function()
		local filepath = root .. "/README.md"
		local buffer_lines = { "# Commands", "```bash", "printf 'markdown-buffer-run\\n'", "```" }

		for _, output_mode in ipairs({ "buffer", "terminal" }) do
			vim.cmd("silent! only")
			open_markdown(filepath, buffer_lines)
			flow.setup({
				output_mode = output_mode,
				show_command = false,
				terminal_height = 5,
			})

			flow.run_here()

			assert.is_not_nil(runner.last_cmd_def)
			assert.are.equal("README.md:2", runner.last_cmd_def.source_key)
			assert.is_true(runner.last_command:find("printf 'markdown-buffer-run", 1, true) ~= nil)
			assert.is_true(wait_for_output("markdown-buffer-run"))
		end
	end)

	it("dispatches the run keymap to a Markdown block", function()
		local filepath = root .. "/notes.markdown"
		flow.setup({
			output_mode = "buffer",
			show_command = false,
			terminal_height = 5,
			keymaps = { run = "<F5>" },
		})
		open_markdown(filepath, { "# Commands", "```sh", "printf 'markdown-keymap-run\\n'", "```" })

		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F5>", true, false, true), "x", false)

		assert.is_true(wait_for_output("markdown-keymap-run"))
		assert.are.equal("notes.markdown:2", runner.last_cmd_def.source_key)
	end)

	it("previews and debugs the selected Markdown block without executing it", function()
		local filepath = root .. "/preview.md"
		open_markdown(filepath, { "# Commands", "```bash", "echo selected", "```" })

		local captured_preview = nil
		local original_preview_open = preview.open
		preview.open = function(command, opts)
			captured_preview = { command = command, opts = opts }
		end

		local captured_debug = nil
		local original_debug_run = debug_runner.run
		debug_runner.run = function(cmd_def)
			captured_debug = vim.deepcopy(cmd_def)
			return true
		end

		flow.preview()
		flow.debug()
		preview.open = original_preview_open
		debug_runner.run = original_debug_run

		assert.is_not_nil(captured_preview)
		assert.are.equal("echo selected", captured_preview.command)
		assert.are.equal("Flow Preview (preview.md:2)", captured_preview.opts.title)
		assert.is_not_nil(captured_debug)
		assert.are.equal("#!/usr/bin/env bash\necho selected", captured_debug.cmd)
		assert.is_nil(runner.last_cmd_def)
	end)

	it("preserves the Markdown block snapshot across debug keymap cleanup", function()
		local filepath = root .. "/debug.md"
		open_markdown(filepath, { "# Commands", "```bash", "echo debug-snapshot", "```" })
		local other = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(other, root .. "/other.txt")
		vim.g.nvim_flow_debug_test_other_buf = other
		vim.cmd([[
			function! CloseAll() abort
				lua vim.api.nvim_set_current_buf(vim.g.nvim_flow_debug_test_other_buf)
			endfunction
		]])
		flow.setup({
			output_mode = "buffer",
			show_command = false,
			terminal_height = 5,
			keymaps = { debug = "<F6>" },
		})

		local captured_debug = nil
		local original_debug_run = debug_runner.run
		debug_runner.run = function(cmd_def)
			captured_debug = vim.deepcopy(cmd_def)
			return true
		end
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F6>", true, false, true), "x", false)
		debug_runner.run = original_debug_run
		vim.cmd("delfunction CloseAll")
		vim.g.nvim_flow_debug_test_other_buf = nil

		assert.is_not_nil(captured_debug)
		assert.are.equal("debug.md:2", captured_debug.source_key)
		assert.is_true(captured_debug.cmd:find("echo debug-snapshot", 1, true) ~= nil)
	end)

	it("keeps FlowRun and FlowEdit on YAML resolution for Markdown files", function()
		local project = root .. "/project"
		local filepath = project .. "/README.md"
		local flow_file = project .. "/.flow.yml"
		vim.fn.mkdir(project .. "/.git", "p")
		write_file(flow_file, ".md:\n  cmd: printf 'yaml-flow-run\\n'\n")
		open_markdown(filepath, { "# Commands", "```bash", "echo markdown", "```" })

		flow.run()

		assert.is_not_nil(runner.last_cmd_def)
		assert.are.equal(".md", runner.last_cmd_def.source_key)
		assert.is_true(runner.last_command:find("yaml-flow-run", 1, true) ~= nil)

		flow.setup({
			output_mode = "buffer",
			show_command = false,
			terminal_height = 5,
			edit_open_command = "edit",
		})
		flow.edit()

		assert.are.equal(vim.fs.normalize(flow_file), vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
	end)
end)
