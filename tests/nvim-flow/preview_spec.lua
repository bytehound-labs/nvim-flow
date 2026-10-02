local preview = require("nvim-flow.preview")

describe("nvim-flow preview", function()
	after_each(function()
		vim.cmd("silent! only")
	end)

	it("displays the execution directory separately from the command", function()
		local win = preview.open("echo preview", {
			cwd = "/tmp/project with spaces",
		})
		local buf = vim.api.nvim_win_get_buf(win)

		assert.are.same({
			"Working directory: /tmp/project with spaces",
			"",
			"echo preview",
		}, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		vim.api.nvim_win_close(win, true)
	end)

	it("keeps the command-only preview when no cwd is provided", function()
		local win = preview.open("echo preview")
		local buf = vim.api.nvim_win_get_buf(win)

		assert.are.same({ "echo preview" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		vim.api.nvim_win_close(win, true)
	end)
end)
