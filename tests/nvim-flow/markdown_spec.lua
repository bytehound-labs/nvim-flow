local lock = require("nvim-flow.lock")
local markdown = require("nvim-flow.markdown")

local function write_file(filepath, contents)
	vim.fn.mkdir(vim.fs.dirname(filepath), "p")
	local file = assert(io.open(filepath, "w"))
	file:write(contents)
	file:close()
end

local function lines(text)
	return vim.split(text, "\n", { plain = true, trimempty = false })
end

describe("nvim-flow Markdown resolution", function()
	local root = nil
	local document = nil

	before_each(function()
		root = vim.fn.tempname()
		document = root .. "/project/README.md"
		vim.fn.mkdir(root .. "/project/.git", "p")
		lock.clear()
	end)

	after_each(function()
		lock.clear()
		if root then
			vim.fn.delete(root, "rf")
		end
	end)

	it("resolves shell fences with additional info-string text", function()
		local cmd_def =
			assert(markdown.resolve_at(document, { "# Commands", "", "```bash title=hello", "echo hello", "```" }, 4))

		assert.are.equal("README.md:3", cmd_def.source_key)
		assert.are.equal("#!/usr/bin/env bash\necho hello", cmd_def.cmd)
		assert.are.equal(vim.fs.normalize(document), cmd_def.filepath)
		assert.are.same({ vim.fs.normalize(document) }, cmd_def.source_files)
		assert.are.equal(3, cmd_def.block_line)
	end)

	it("runs the selected block when the cursor is on an opening or closing fence", function()
		local buffer = { "```sh", "echo hello", "```", "after" }

		for _, cursor_line in ipairs({ 1, 3 }) do
			local block = assert(markdown.extract_block(buffer, cursor_line))
			assert.are.equal("echo hello", block.command)
		end
	end)

	it("supports tilde fences, longer delimiters, and preserves shell text", function()
		local buffer = {
			"  ````shell",
			"    printf '%s' 'a > b'",
			"  cat <<'EOF'",
			"  > literal heredoc content",
			"  EOF",
			"  ```",
			"  ````",
		}
		local block = assert(markdown.extract_block(buffer, 3))

		assert.are.equal("  printf '%s' 'a > b'\ncat <<'EOF'\n> literal heredoc content\nEOF\n```", block.command)

		local tilde = assert(markdown.extract_block({ "~~~sh", "echo tilde", "~~~" }, 2))
		assert.are.equal("echo tilde", tilde.command)
	end)

	it("extracts shell commands from blockquotes, lists, and nested combinations", function()
		local cases = {
			{
				lines = { "> ```sh", "> echo quoted", "> echo > result.txt", "> ```" },
				command = "echo quoted\necho > result.txt",
			},
			{
				lines = { "- item", "  ```bash", "  echo listed", "  ```" },
				command = "echo listed",
			},
			{
				lines = { "- parent", "  - child", "    ```bash", "    echo nested list", "    ```" },
				command = "echo nested list",
			},
			{
				lines = { "> - item", ">   ```shell", ">   echo nested", ">   echo > nested.txt", ">   ```" },
				command = "echo nested\necho > nested.txt",
			},
			{
				lines = { "> > ```sh", "> > echo nested quote", "> > ```" },
				command = "echo nested quote",
			},
			{
				lines = { ">   ```sh", ">     echo nested indent", ">   ```" },
				command = "  echo nested indent",
			},
		}

		for _, case in ipairs(cases) do
			local block = assert(markdown.extract_block(case.lines, 3))
			assert.are.equal(case.command, block.command)
		end
	end)

	it("handles a nested closing fence at end of file without a trailing newline", function()
		local block = assert(markdown.extract_block({ "- item", "  ```sh", "  echo at eof", "  ```" }, 4))
		assert.are.equal("echo at eof", block.command)
	end)

	it("removes only Tree-sitter-identified container prefixes", function()
		local block =
			assert(markdown.extract_block({ "```bash", "> literal shell text", "echo > output.txt", "```" }, 2))

		assert.are.equal("> literal shell text\necho > output.txt", block.command)
	end)

	it("rejects prose, unlabeled fences, and unsupported languages", function()
		local prose, prose_err = markdown.extract_block({ "Run this command:", "text" }, 1)
		assert.is_nil(prose)
		assert.is_true(prose_err:find("not inside", 1, true) ~= nil)

		for _, language in ipairs({ "", "python", "console", "shellsession" }) do
			local buffer = { "```" .. language, "echo not executed", "```" }
			local block, err = markdown.extract_block(buffer, 2)
			assert.is_nil(block)
			assert.is_true(err:find("supported shell fences", 1, true) ~= nil)
		end
	end)

	it("rejects empty, unclosed, and out-of-container fences", function()
		local empty, empty_err = markdown.extract_block({ "```bash", "```" }, 1)
		assert.is_nil(empty)
		assert.is_true(empty_err:find("empty", 1, true) ~= nil)

		local unclosed, unclosed_err = markdown.extract_block({ "```bash", "echo incomplete" }, 2)
		assert.is_nil(unclosed)
		assert.is_true(unclosed_err:find("no matching closing fence", 1, true) ~= nil)

		local outside, outside_err = markdown.extract_block({ "> ```sh", "> echo incomplete", "", "```" }, 2)
		assert.is_nil(outside)
		assert.is_true(outside_err:find("no matching closing fence", 1, true) ~= nil)

		local list_outside, list_outside_err =
			markdown.extract_block({ "- item", "  ```sh", "  echo incomplete", "```" }, 3)
		assert.is_nil(list_outside)
		assert.is_true(list_outside_err:find("no matching closing fence", 1, true) ~= nil)
	end)

	it("uses document context for project variables and ignores a lock", function()
		local locked = root .. "/elsewhere/target.py"
		write_file(locked, "print('locked')\n")
		lock.set(locked)

		local cmd_def = assert(markdown.resolve_at(document, lines("```sh\necho {{dir}} {{repo}} {{folder}}\n```"), 2))

		assert.is_true(cmd_def.cmd:find("echo " .. root .. "/project project project", 1, true) ~= nil)
		assert.are.equal(vim.fs.normalize(document), cmd_def.filepath)
	end)

	it("requires a locked target for file-scoped template variables", function()
		local cmd_def, err =
			markdown.resolve_at(document, lines("```bash\necho {{filepath}} {{filename}} {{ext}}\n```"), 2)

		assert.is_nil(cmd_def)
		assert.is_true(err:find(":FlowSet", 1, true) ~= nil)
	end)

	it("uses the locked file context for file-scoped templates", function()
		local target = root .. "/project/src/main.py"
		lock.set(target)

		local cmd_def = assert(
			markdown.resolve_at(
				document,
				lines("```sh\necho {{filepath}} {{filename}} {{ext}} {{dir}} {{repo}}\n```"),
				2
			)
		)

		assert.is_true(cmd_def.cmd:find(vim.fs.normalize(target), 1, true) ~= nil)
		assert.is_true(cmd_def.cmd:find("main py " .. root .. "/project/src project", 1, true) ~= nil)
		assert.are.equal(vim.fs.normalize(target), cmd_def.filepath)
		assert.are.same({ vim.fs.normalize(document) }, cmd_def.source_files)
	end)

	it("preserves an explicit shell shebang", function()
		local cmd_def = assert(markdown.resolve_at(document, { "```bash", "#!/bin/sh", "echo shebang", "```" }, 3))

		assert.are.equal("#!/bin/sh\necho shebang", cmd_def.cmd)
	end)

	it("reports a missing Markdown parser without falling back to another parser", function()
		local original = vim.treesitter.get_string_parser
		vim.treesitter.get_string_parser = function()
			error("missing markdown parser")
		end

		local ok, block, err = pcall(markdown.extract_block, { "```sh", "echo unavailable", "```" }, 2)
		vim.treesitter.get_string_parser = original

		assert.is_true(ok)
		assert.is_nil(block)
		assert.is_true(err:find("Tree-sitter `markdown` parser", 1, true) ~= nil)
	end)
end)
