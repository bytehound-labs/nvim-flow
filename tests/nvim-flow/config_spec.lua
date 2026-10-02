local config = require("nvim-flow.config")

local function write_file(path, contents)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local fh = assert(io.open(path, "w"))
	fh:write(contents)
	fh:close()
end

local function contains(value, needle)
	return value:find(needle, 1, true) ~= nil
end

describe("nvim-flow config resolution", function()
	local root = nil

	before_each(function()
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
	end)

	after_each(function()
		if root then
			vim.fn.delete(root, "rf")
		end
	end)

	it("merges configs from file dir to home with closer files winning", function()
		local home = root .. "/home"
		local repo = home .. "/repo"
		local src = repo .. "/src"
		local target = src .. "/main.py"

		write_file(
			home .. "/.flow.yml",
			[[
default:
  cmd: echo home-default
py:
  cmd: echo home-py {{filename}}
]]
		)

		write_file(
			repo .. "/.flow.yml",
			[[
py:
  cmd: echo repo-py {{filename}}
]]
		)

		write_file(target, "print('hello')\n")

		local cmd_def = assert(config.resolve(target, {
			config_file = ".flow.yml",
			stop_at_home = true,
			home = home,
		}))

		assert.is_true(contains(cmd_def.cmd, "echo repo-py main"))
	end)

	it("keeps legacy key matching and supports optional match arrays", function()
		local home = root .. "/home"
		local repo = home .. "/repo"
		local src = repo .. "/src"
		local py_target = src .. "/worker.py"
		local lua_target = src .. "/plugin.lua"

		write_file(
			home .. "/.flow.yml",
			[[
python-group:
  match: [py, pyw]
  cmd: echo from-match {{ext}}
lua:
  cmd: echo from-legacy {{ext}}
]]
		)

		write_file(py_target, "print('hello')\n")
		write_file(lua_target, "print('hello')\n")

		local py_cmd = assert(config.resolve(py_target, {
			config_file = ".flow.yml",
			stop_at_home = true,
			home = home,
		}))
		local lua_cmd = assert(config.resolve(lua_target, {
			config_file = ".flow.yml",
			stop_at_home = true,
			home = home,
		}))

		assert.is_true(contains(py_cmd.cmd, "echo from-match py"))
		assert.is_true(contains(lua_cmd.cmd, "echo from-legacy lua"))
	end)

	it("uses basename before match entries", function()
		local home = root .. "/home"
		local repo = home .. "/repo"
		local src = repo .. "/src"
		local target = src .. "/special.py"

		write_file(
			home .. "/.flow.yml",
			[[
python-group:
  match: [py]
  cmd: echo from-match
special.py:
  cmd: echo from-basename
]]
		)

		write_file(target, "print('hello')\n")

		local cmd_def = assert(config.resolve(target, {
			config_file = ".flow.yml",
			stop_at_home = true,
			home = home,
		}))

		assert.is_true(contains(cmd_def.cmd, "echo from-basename"))
	end)

	it("uses deterministic match order and prefers closer files", function()
		local home = root .. "/home"
		local repo = home .. "/repo"
		local src = repo .. "/src"
		local target = src .. "/worker.py"

		write_file(
			home .. "/.flow.yml",
			[[
match-first:
  match: [py]
  cmd: echo from-home-first
match-second:
  match: [py]
  cmd: echo from-home-second
]]
		)

		write_file(
			repo .. "/.flow.yml",
			[[
repo-match:
  match: [py]
  cmd: echo from-repo
]]
		)

		write_file(target, "print('hello')\n")

		local cmd_def = assert(config.resolve(target, {
			config_file = ".flow.yml",
			stop_at_home = true,
			home = home,
		}))

		assert.is_true(contains(cmd_def.cmd, "echo from-repo"))
	end)

	it("does not match filename without extension", function()
		local home = root .. "/home"
		local repo = home .. "/repo"
		local src = repo .. "/src"
		local target = src .. "/worker.py"

		write_file(
			home .. "/.flow.yml",
			[[
worker:
  cmd: echo from-filename
py:
  cmd: echo from-extension
]]
		)

		write_file(target, "print('hello')\n")

		local cmd_def = assert(config.resolve(target, {
			config_file = ".flow.yml",
			stop_at_home = true,
			home = home,
		}))

		assert.is_true(contains(cmd_def.cmd, "echo from-extension"))
		assert.is_false(contains(cmd_def.cmd, "echo from-filename"))
	end)

	it("finds source flow file and line for resolved key", function()
		local home = root .. "/home"
		local repo = home .. "/repo"
		local src = repo .. "/tasks"
		local target = src .. "/sync.yaml"

		write_file(
			home .. "/.flow.yml",
			[[
default:
  cmd: echo home-default
]]
		)

		write_file(
			repo .. "/.flow.yml",
			[[
# repo-specific tasks

sync.yaml:
  cmd: bash ./ansible-run.sh --tags "sync"
]]
		)

		write_file(target, "hosts: []\n")

		local cmd_def = assert(config.resolve(target, {
			config_file = ".flow.yml",
			stop_at_home = true,
			home = home,
		}))
		assert.are.equal("sync.yaml", cmd_def.source_key)

		local location = assert(config.find_source_location(cmd_def.source_key, cmd_def.source_files))
		assert.are.equal(repo .. "/.flow.yml", location.file)
		assert.are.equal(4, location.line)
	end)

	it("finds source location in nearest file and jumps to cmd when cmd is not first field", function()
		local home = root .. "/home"
		local repo = home .. "/repo"
		local src = repo .. "/tasks"
		local target = src .. "/sync.yaml"

		write_file(
			home .. "/.flow.yml",
			[[
sync.yaml:
  cmd: echo home-sync
]]
		)

		write_file(
			repo .. "/.flow.yml",
			[[
# repo-specific tasks
sync.yaml:
  runner: terminal
  cmd: echo repo-sync
]]
		)

		write_file(target, "hosts: []\n")

		local cmd_def = assert(config.resolve(target, {
			config_file = ".flow.yml",
			stop_at_home = true,
			home = home,
		}))
		assert.are.equal("sync.yaml", cmd_def.source_key)
		assert.is_true(contains(cmd_def.cmd, "echo repo-sync"))

		local location = assert(config.find_source_location(cmd_def.source_key, cmd_def.source_files))
		assert.are.equal(repo .. "/.flow.yml", location.file)
		assert.are.equal(4, location.line)
	end)

	it("uses the nearest repository root as the execution directory", function()
		local repo = root .. "/repo"
		local nested_repo = repo .. "/packages/service"
		local target = nested_repo .. "/src/main.py"
		write_file(nested_repo .. "/.git/HEAD", "ref: refs/heads/main\n")
		write_file(target, "print('hello')\n")
		write_file(nested_repo .. "/.flow.yml", "py:\n  cmd: python {{filepath}}\n")

		local cmd_def = assert(config.resolve(target))
		assert.are.equal(vim.fs.normalize(nested_repo), cmd_def.cwd)
	end)

	it("falls back to the context file directory outside a repository", function()
		local target = root .. "/outside/notes.md"
		write_file(target, "# Notes\n")
		write_file(root .. "/outside/.flow.yml", "md:\n  cmd: echo notes\n")

		local cmd_def = assert(config.resolve(target))
		assert.are.equal(vim.fs.normalize(root .. "/outside"), cmd_def.cwd)
	end)

	it("uses the captured Neovim directory when requested", function()
		local repo = root .. "/repo"
		local target = repo .. "/README.md"
		write_file(repo .. "/.git/HEAD", "ref: refs/heads/main\n")
		write_file(target, "# Readme\n")
		write_file(repo .. "/.flow.yml", "md:\n  cmd: echo run\n")
		local expected = vim.fs.normalize(vim.fn.getcwd())

		local cmd_def = assert(config.resolve(target, { cwd = "nvim" }))
		assert.are.equal(expected, cmd_def.cwd)
	end)

	it("resolves YAML cwd overrides relative to the repo and expands templates", function()
		local repo = root .. "/repo"
		local target_dir = repo .. "/packages/api service"
		local flow_file = repo .. "/.flow.yml"
		vim.fn.mkdir(repo .. "/.git", "p")
		vim.fn.mkdir(target_dir, "p")
		write_file(flow_file, "relative:\n  cwd: packages/api service\n  cmd: pwd\n")

		local relative = assert(config.resolve_at(flow_file, "relative"))
		assert.are.equal(vim.fs.normalize(target_dir), relative.cwd)

		local templated =
			assert(config.resolve_at(flow_file, "relative", {}, "relative:\n  cwd: '{{dir}}'\n  cmd: pwd\n"))
		assert.are.equal(vim.fs.normalize(repo), templated.cwd)
	end)

	it("resolves a YAML cwd placeholder against the matched file context", function()
		local repo = root .. "/repo"
		local target = repo .. "/src/app.py"
		local target_cwd = repo .. "/src/app-cwd"
		local flow_file = repo .. "/.flow.yml"
		write_file(repo .. "/.git/HEAD", "ref: refs/heads/main\n")
		write_file(target, "print('hello')\n")
		vim.fn.mkdir(target_cwd, "p")
		write_file(
			flow_file,
			"run-app:\n  match: ['**/app.py']\n  cwd: '{{dir}}/{{filename}}-cwd'\n  cmd: echo no file placeholder\n"
		)

		local cmd_def = assert(config.resolve_at(flow_file, "run-app"))
		assert.are.equal(vim.fs.normalize(target_cwd), cmd_def.cwd)
	end)

	it("rejects invalid cwd policies and YAML overrides", function()
		local repo = root .. "/repo"
		local flow_file = repo .. "/.flow.yml"
		vim.fn.mkdir(repo .. "/.git", "p")

		local invalid_policy, policy_err =
			config.resolve_at(flow_file, "run", { cwd = "outside" }, "run:\n  cmd: echo run\n")
		assert.is_nil(invalid_policy)
		assert.is_true(policy_err:find("invalid cwd policy", 1, true) ~= nil)

		local invalid_type, type_err = config.resolve_at(flow_file, "run", {}, "run:\n  cwd: 42\n  cmd: echo run\n")
		assert.is_nil(invalid_type)
		assert.is_true(type_err:find("cwd must be a non-empty directory path", 1, true) ~= nil)

		local missing_dir, missing_err =
			config.resolve_at(flow_file, "run", {}, "run:\n  cwd: missing\n  cmd: echo run\n")
		assert.is_nil(missing_dir)
		assert.is_true(missing_err:find("not an existing directory", 1, true) ~= nil)
	end)
end)

describe("nvim-flow find_key_at_line", function()
	local text = table.concat({
		"# header comment", -- 1
		"first:", -- 2
		"  cmd: echo one", -- 3
		"", -- 4
		"# between comment", -- 5
		"second:", -- 6
		"  match: '**/x.py'", -- 7
		"  # inner comment", -- 8
		"  cmd: |", -- 9
		"    echo two", -- 10
		"    echo three", -- 11
	}, "\n")
	local lines = vim.split(text, "\n", { plain = true })

	it("returns the key when the cursor is on the key line", function()
		assert.are.equal("first", config.find_key_at_line(lines, 2))
		assert.are.equal("second", config.find_key_at_line(lines, 6))
	end)

	it("returns the enclosing key from inside a block", function()
		assert.are.equal("first", config.find_key_at_line(lines, 3))
		assert.are.equal("second", config.find_key_at_line(lines, 8))
		assert.are.equal("second", config.find_key_at_line(lines, 10))
		assert.are.equal("second", config.find_key_at_line(lines, 11))
	end)

	it("returns nil above the first entry", function()
		assert.is_nil(config.find_key_at_line(lines, 1))
	end)

	it("clamps out-of-range line numbers", function()
		assert.are.equal("second", config.find_key_at_line(lines, 999))
	end)
end)

describe("nvim-flow resolve_at (run from .flow.yml)", function()
	local root = nil
	local lock = require("nvim-flow.lock")

	before_each(function()
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		lock.clear()
	end)

	after_each(function()
		lock.clear()
		if root then
			vim.fn.delete(root, "rf")
		end
	end)

	it("runs a var-free entry using the config file's own context", function()
		local flow_file = root .. "/proj/.flow.yml"
		vim.fn.mkdir(root .. "/proj/.git", "p")
		write_file(flow_file, "deploy:\n  cmd: echo deploy {{repo}} {{folder}}\n")

		local cmd_def = assert(config.resolve_at(flow_file, "deploy", { config_file = ".flow.yml" }))
		assert.are.equal("deploy", cmd_def.source_key)
		assert.is_true(contains(cmd_def.cmd, "echo deploy proj proj"))
		assert.are.equal(vim.fs.normalize(root .. "/proj"), cmd_def.cwd)
	end)

	it("fills {{filepath}} from a match glob that resolves to exactly one file", function()
		local flow_file = root .. "/proj/.flow.yml"
		vim.fn.mkdir(root .. "/proj/.git", "p")
		local target = root .. "/proj/src/app.py"
		write_file(target, "print('x')\n")
		write_file(flow_file, "run-app:\n  match: ['**/app.py']\n  cmd: python {{filepath}}\n")

		local cmd_def = assert(config.resolve_at(flow_file, "run-app", { config_file = ".flow.yml" }))
		assert.are.equal(vim.fs.normalize(target), cmd_def.filepath)
		assert.is_true(contains(cmd_def.cmd, "python " .. vim.fs.normalize(target)))
	end)

	it("resolves a bare-basename key for file-scoped vars", function()
		local flow_file = root .. "/proj/.flow.yml"
		vim.fn.mkdir(root .. "/proj/.git", "p")
		local target = root .. "/proj/nested/demo.py"
		write_file(target, "print('x')\n")
		write_file(flow_file, "demo.py:\n  cmd: python {{filepath}} --name mike\n")

		local cmd_def = assert(config.resolve_at(flow_file, "demo.py", { config_file = ".flow.yml" }))
		assert.are.equal(vim.fs.normalize(target), cmd_def.filepath)
	end)

	it("errors when a file-scoped var matches no file", function()
		local flow_file = root .. "/proj/.flow.yml"
		vim.fn.mkdir(root .. "/proj/.git", "p")
		write_file(flow_file, "run-app:\n  match: ['**/missing.py']\n  cmd: python {{filepath}}\n")

		local cmd_def, err = config.resolve_at(flow_file, "run-app", { config_file = ".flow.yml" })
		assert.is_nil(cmd_def)
		assert.is_true(contains(err, "no file matched"))
	end)

	it("errors when a file-scoped var matches multiple files", function()
		local flow_file = root .. "/proj/.flow.yml"
		vim.fn.mkdir(root .. "/proj/.git", "p")
		write_file(root .. "/proj/a/app.py", "x\n")
		write_file(root .. "/proj/b/app.py", "x\n")
		write_file(flow_file, "run-app:\n  match: ['**/app.py']\n  cmd: python {{filepath}}\n")

		local cmd_def, err = config.resolve_at(flow_file, "run-app", { config_file = ".flow.yml" })
		assert.is_nil(cmd_def)
		assert.is_true(contains(err, "expected exactly one"))
	end)

	it("prefers the locked file for file-scoped vars", function()
		local flow_file = root .. "/proj/.flow.yml"
		vim.fn.mkdir(root .. "/proj/.git", "p")
		local locked = root .. "/elsewhere/main.py"
		write_file(locked, "x\n")
		lock.set(locked)
		write_file(flow_file, "run-app:\n  match: ['**/app.py']\n  cmd: python {{filepath}}\n")

		local cmd_def = assert(config.resolve_at(flow_file, "run-app", { config_file = ".flow.yml" }))
		assert.are.equal(vim.fs.normalize(locked), cmd_def.filepath)
		assert.is_true(contains(cmd_def.cmd, "python " .. vim.fs.normalize(locked)))
	end)

	it("honors live buffer text over the file on disk", function()
		local flow_file = root .. "/proj/.flow.yml"
		write_file(flow_file, "deploy:\n  cmd: echo OLD\n")

		local cmd_def = assert(config.resolve_at(flow_file, "deploy", {}, "deploy:\n  cmd: echo NEW\n"))
		assert.is_true(contains(cmd_def.cmd, "echo NEW"))
		assert.is_false(contains(cmd_def.cmd, "echo OLD"))
	end)

	it("errors for an unknown key", function()
		local flow_file = root .. "/proj/.flow.yml"
		write_file(flow_file, "deploy:\n  cmd: echo hi\n")

		local cmd_def, err = config.resolve_at(flow_file, "nope", { config_file = ".flow.yml" })
		assert.is_nil(cmd_def)
		assert.is_true(contains(err, "no flow entry"))
	end)
end)
