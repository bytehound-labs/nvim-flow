local quickfix = require("nvim-flow.quickfix")

describe("nvim-flow quickfix parser", function()
	it("parses python traceback entries", function()
		local items = quickfix.parse_python_traceback({
			"Traceback (most recent call last):",
			'  File "/tmp/main.py", line 12, in <module>',
			"    run()",
			'  File "/tmp/lib.py", line 3, in run',
			"    raise ValueError('boom')",
			"ValueError: boom",
		})

		assert.are.equal(2, #items)
		assert.are.equal("/tmp/main.py", items[1].filename)
		assert.are.equal(12, items[1].lnum)
		assert.are.equal("run()", items[1].text)
	end)

	it("resolves relative traceback filenames against the command cwd", function()
		local items = quickfix.parse_python_traceback({
			'  File "src/main.py", line 12, in <module>',
			"    run()",
			'  File "/tmp/shared.py", line 3, in run',
			"    raise ValueError('boom')",
			'  File "C:\\shared\\module.py", line 7, in run',
			"    return value",
		}, "/tmp/project")

		assert.are.equal("/tmp/project/src/main.py", items[1].filename)
		assert.are.equal("/tmp/shared.py", items[2].filename)
		assert.are.equal("C:\\shared\\module.py", items[3].filename)
	end)
end)
