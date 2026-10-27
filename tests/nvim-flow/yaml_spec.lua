local yaml = require("nvim-flow.yaml")

local function contains(value, needle)
	return value:find(needle, 1, true) ~= nil
end

describe("nvim-flow yaml parser", function()
	it("parses plain multiline cmd blocks with URLs", function()
		local parsed = assert(yaml.decode([[
json:
  cmd:
    curl -k -i -X POST "https://localhost:7125/api/test" \
      -H "Content-Type: application/json" \
      --data-binary @{{filepath}}
]]))

		assert.is_true(contains(parsed.json.cmd, 'curl -k -i -X POST "https://localhost:7125/api/test"'))
		assert.is_true(contains(parsed.json.cmd, "--data-binary @{{filepath}}"))
	end)

	it("folds multiline command scalars", function()
		local parsed = assert(yaml.decode([[
tuning.py:
  cmd: >-
    uv run yok automation tuning write --machine-key=yok2 --daff
    --table=/tmp/tuning.csv
]]))

		assert.are.equal(
			"uv run yok automation tuning write --machine-key=yok2 --daff --table=/tmp/tuning.csv",
			parsed["tuning.py"].cmd
		)
	end)

	it("preserves paragraph breaks in folded block scalars", function()
		local parsed = assert(yaml.decode([[
script:
  cmd: >
    echo first

    echo second
]]))

		assert.are.equal("echo first\necho second", parsed.script.cmd)
	end)

	it("handles inline multiline scalar continuations without truncating later keys", function()
		local parsed = assert(yaml.decode([[
ioCombine.py:
  cmd: python {{filepath}} -c /tmp/iGet.xlsx
    -p /tmp/sVar.xlsx
    -o /tmp/IO.xlsx

sVar.py:
  cmd: bash /tmp/run_svar.sh

py:
  cmd: python {{filepath}}
]]))

		assert.are.equal("table", type(parsed["ioCombine.py"]))
		assert.is_true(contains(parsed["ioCombine.py"].cmd, "-p /tmp/sVar.xlsx"))
		assert.is_true(contains(parsed["ioCombine.py"].cmd, "-o /tmp/IO.xlsx"))
		assert.are.equal("bash /tmp/run_svar.sh", parsed["sVar.py"].cmd)
		assert.are.equal("python {{filepath}}", parsed.py.cmd)
	end)

	it("parses keys with inline comments", function()
		local parsed = assert(yaml.decode([[
py:
  cmd: echo from-extension

tag_generator.py: # {{{2
  cmd: echo from-basename-with-comment
]]))

		assert.are.equal("echo from-basename-with-comment", parsed["tag_generator.py"].cmd)
	end)

	it("preserves hash inside quoted scalar values", function()
		local parsed = assert(yaml.decode([[
sh:
  cmd: echo "hello # world"
]]))

		assert.are.equal('echo "hello # world"', parsed.sh.cmd)
	end)

	it("keeps URL fragments while stripping trailing inline comments", function()
		local parsed = assert(yaml.decode([[
py:
  cmd: curl https://example.com/#frag --name value # this is a comment
]]))

		assert.is_true(contains(parsed.py.cmd, "https://example.com/#frag"))
		assert.is_false(contains(parsed.py.cmd, "this is a comment"))
	end)

	it("parses match arrays with commas inside quoted elements", function()
		local parsed = assert(yaml.decode([[
python-group:
  match: ["foo,bar", py]
  cmd: echo from-match
]]))

		assert.are.same({ "foo,bar", "py" }, parsed["python-group"].match)
	end)

	it("keeps quoted json-like args while stripping trailing comments", function()
		local parsed = assert(yaml.decode([[
py:
  cmd: uv run yok tags --filters '{"Selected":"x"}' # keep json arg
]]))

		assert.is_true(contains(parsed.py.cmd, '\'{"Selected":"x"}\''))
		assert.is_false(contains(parsed.py.cmd, "keep json arg"))
	end)

	it("handles top-level comments after inline continuation and still parses later keys", function()
		local parsed = assert(yaml.decode([[
ioCombine.py:
  cmd: python {{filepath}} -c /tmp/iGet.xlsx
    -p /tmp/sVar.xlsx
    -o /tmp/IO.xlsx
# comment between entries
sVar.py:
  cmd: bash /tmp/run_svar.sh
]]))

		assert.are.equal("bash /tmp/run_svar.sh", parsed["sVar.py"].cmd)
	end)

	it("parses block-style sequences (- item syntax)", function()
		local parsed = assert(yaml.decode([[
centum_blocks.py:
  match:
    - '**/rpa/centum/blocks.py'
    - '**/rpa/centum/config/blocks.yaml'
  cmd: echo hello
]]))

		assert.are.same(
			{ "**/rpa/centum/blocks.py", "**/rpa/centum/config/blocks.yaml" },
			parsed["centum_blocks.py"].match
		)
		assert.are.equal("echo hello", parsed["centum_blocks.py"].cmd)
	end)

	it("parses block-style sequences with unquoted items", function()
		local parsed = assert(yaml.decode([[
python-group:
  match:
    - py
    - pyw
  cmd: python "{{filepath}}"
]]))

		assert.are.same({ "py", "pyw" }, parsed["python-group"].match)
	end)

	it("parses block-style sequences followed by other keys at same level", function()
		local parsed = assert(yaml.decode([[
entry:
  match:
    - foo
    - bar
  cmd: echo matched

other.py:
  cmd: echo other
]]))

		assert.are.same({ "foo", "bar" }, parsed["entry"].match)
		assert.are.equal("echo matched", parsed["entry"].cmd)
		assert.are.equal("echo other", parsed["other.py"].cmd)
	end)
end)
