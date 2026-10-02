local path = require("nvim-flow.path")

describe("nvim-flow path helpers", function()
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

	it("detects repo root even when vim.fs.root is unavailable", function()
		local repo = root .. "/my-repo"
		local src = repo .. "/src"
		local file = src .. "/main.py"
		vim.fn.mkdir(repo .. "/.git", "p")
		vim.fn.mkdir(src, "p")
		local fh = assert(io.open(file, "w"))
		fh:write("print('x')\n")
		fh:close()

		local original_root = vim.fs.root
		vim.fs.root = nil
		local ok, detected = pcall(path.detect_repo_name, file)
		vim.fs.root = original_root

		assert.is_true(ok)
		assert.are.equal("my-repo", detected)
	end)

	it("detects directory and worktree-style git markers", function()
		local repo = root .. "/repo"
		local nested = repo .. "/packages/api"
		local target = nested .. "/README.md"
		vim.fn.mkdir(nested, "p")
		local git_file = assert(io.open(repo .. "/.git", "w"))
		git_file:write("gitdir: /tmp/worktrees/repo\n")
		git_file:close()

		assert.are.equal(vim.fs.normalize(repo), path.detect_repo_root(target))

		local original_root = vim.fs.root
		vim.fs.root = nil
		local ok, detected = pcall(path.detect_repo_root, target)
		vim.fs.root = original_root
		assert.is_true(ok)
		assert.are.equal(vim.fs.normalize(repo), detected)

		vim.fn.delete(repo .. "/.git")
		vim.fn.mkdir(repo .. "/.git", "p")
		local nested_repo = nested .. "/subpackage"
		vim.fn.mkdir(nested_repo .. "/.git", "p")
		assert.are.equal(vim.fs.normalize(nested_repo), path.detect_repo_root(nested_repo .. "/src/main.lua"))
	end)

	it("identifies POSIX and Windows absolute paths", function()
		assert.is_true(path.is_absolute("/tmp/project/file.lua"))
		assert.is_true(path.is_absolute("C:\\project\\file.lua"))
		assert.is_true(path.is_absolute("\\\\server\\share\\file.lua"))
		assert.is_false(path.is_absolute("packages/project/file.lua"))
		assert.is_false(path.is_absolute("C:project\\file.lua"))
		assert.is_false(path.is_absolute(nil))
	end)

	it("resolves repo, non-repo, and Neovim cwd policies", function()
		local repo = root .. "/project"
		local nested = repo .. "/docs/guide.md"
		vim.fn.mkdir(repo .. "/.git", "p")
		vim.fn.mkdir(repo .. "/docs", "p")
		local outside = root .. "/outside/notes.md"
		vim.fn.mkdir(vim.fs.dirname(outside), "p")

		assert.are.equal(vim.fs.normalize(repo), path.resolve_execution_cwd(nested, "repo"))
		assert.are.equal(vim.fs.normalize(vim.fs.dirname(outside)), path.resolve_execution_cwd(outside, "repo"))
		assert.are.equal(vim.fs.normalize(vim.fn.getcwd()), path.resolve_execution_cwd(nested, "nvim"))

		local cwd, err = path.resolve_execution_cwd(nested, "unknown")
		assert.is_nil(cwd)
		assert.is_true(err:find("invalid cwd policy", 1, true) ~= nil)
	end)

	it("resolves explicit cwd paths relative to their base and validates directories", function()
		local base = root .. "/project"
		local nested = base .. "/packages/api service"
		vim.fn.mkdir(nested, "p")

		assert.are.equal(vim.fs.normalize(nested), path.resolve_cwd_override("packages/api service", base))
		assert.are.equal(vim.fs.normalize(nested), path.resolve_cwd_override(nested, base))

		local missing, err = path.resolve_cwd_override("missing", base)
		assert.is_nil(missing)
		assert.is_true(err:find("not an existing directory", 1, true) ~= nil)
	end)
end)
