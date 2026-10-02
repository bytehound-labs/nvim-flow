local debug_runner = require("nvim-flow.debug_runner")

describe("nvim-flow debug runner", function()
	local original_dap = nil

	before_each(function()
		original_dap = package.loaded.dap
		package.loaded.dap = {
			configurations = {},
			continue = function() end,
		}
	end)

	after_each(function()
		package.loaded.dap = original_dap
	end)

	it("builds python program launch config from flow command", function()
		local ok = debug_runner.run({
			cmd = "#!/usr/bin/env bash\npython /tmp/example.py --name value",
			filepath = "/tmp/example.py",
			cwd = "/tmp",
		})

		assert.is_true(ok)
		local cfg = package.loaded.dap.configurations[vim.bo.filetype][1]
		assert.are.equal("python", cfg.type)
		assert.are.equal("/tmp/example.py", cfg.program)
		assert.are.equal("/tmp", cfg.cwd)
		assert.are.same({ "--name", "value" }, cfg.args)
	end)

	it("builds python module launch config for uv run -m", function()
		local ok = debug_runner.run({
			cmd = "#!/usr/bin/env bash\nuv run -m app.main --foo bar",
			filepath = "/tmp/example.py",
			cwd = "/tmp",
		})

		assert.is_true(ok)
		local cfg = package.loaded.dap.configurations[vim.bo.filetype][1]
		assert.are.equal("python", cfg.type)
		assert.are.equal("app.main", cfg.module)
		assert.are.equal("/tmp", cfg.cwd)
		assert.are.same({ "--foo", "bar" }, cfg.args)
	end)

	it("strips quotes from program path in flow command", function()
		local ok = debug_runner.run({
			cmd = '#!/usr/bin/env bash\npython "/tmp/example.py" --name value',
			filepath = "/tmp/example.py",
			cwd = "/tmp",
		})

		assert.is_true(ok)
		local cfg = package.loaded.dap.configurations[vim.bo.filetype][1]
		assert.are.equal("python", cfg.type)
		assert.are.equal("/tmp/example.py", cfg.program)
		assert.are.equal("/tmp", cfg.cwd)
		assert.are.same({ "--name", "value" }, cfg.args)
	end)

	it("falls through to dap.continue for unrecognized commands like dotnet", function()
		local continued = false
		package.loaded.dap.continue = function()
			continued = true
		end
		-- Pre-populate a config to verify it is NOT overwritten
		package.loaded.dap.configurations.cs = { { type = "netcoredbg", name = "existing" } }

		vim.bo.filetype = "cs"
		local ok = debug_runner.run({
			cmd = "#!/usr/bin/env bash\ndotnet run",
			filepath = "/tmp/Controllers/TestController.cs",
		})

		assert.is_true(ok)
		assert.is_true(continued)
		-- Existing config should be preserved (not replaced)
		assert.are.equal("netcoredbg", package.loaded.dap.configurations.cs[1].type)
	end)

	it("sets the resolved cwd on generated Node configurations", function()
		local ok = debug_runner.run({
			cmd = "#!/usr/bin/env bash\nnode scripts/check.js",
			filepath = "/tmp/scripts/check.js",
			cwd = "/tmp/project",
		})

		assert.is_true(ok)
		local cfg = package.loaded.dap.configurations[vim.bo.filetype][1]
		assert.are.equal("node", cfg.type)
		assert.are.equal("/tmp/project", cfg.cwd)
	end)
end)
