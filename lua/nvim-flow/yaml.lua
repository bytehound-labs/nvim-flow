local M = {}

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function count_indent(line)
	local _, finish = line:find("^%s*")
	return finish or 0
end

local function split_lines(text)
	local lines = {}
	text = (text or ""):gsub("\r\n", "\n")
	if text:sub(-1) ~= "\n" then
		text = text .. "\n"
	end

	for line in text:gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	return lines
end

local function parse_list(value)
	local inner = value:sub(2, -2)
	local out = {}
	local token = {}
	local quote = nil

	for i = 1, #inner do
		local ch = inner:sub(i, i)
		if quote then
			if ch == quote then
				quote = nil
			else
				table.insert(token, ch)
			end
		else
			if ch == "'" or ch == '"' then
				quote = ch
			elseif ch == "," then
				local item = trim(table.concat(token))
				if item ~= "" then
					table.insert(out, item)
				end
				token = {}
			else
				table.insert(token, ch)
			end
		end
	end

	local item = trim(table.concat(token))
	if item ~= "" then
		table.insert(out, item)
	end

	return out
end

local function strip_inline_comment(text)
	local in_single = false
	local in_double = false
	for i = 1, #text do
		local ch = text:sub(i, i)
		if ch == "'" and not in_double then
			in_single = not in_single
		elseif ch == '"' and not in_single then
			in_double = not in_double
		elseif ch == "#" and not in_single and not in_double then
			if i == 1 or text:sub(i - 1, i - 1):match("%s") then
				return trim(text:sub(1, i - 1))
			end
		end
	end
	return text
end

local function parse_scalar(value)
	value = trim(value)
	if value == "" then
		return ""
	end

	if value:sub(1, 1) == "[" and value:sub(-1) == "]" then
		return parse_list(value)
	end

	local first = value:sub(1, 1)
	local last = value:sub(-1)
	if (first == "'" and last == "'") or (first == '"' and last == '"') then
		return value:sub(2, -2)
	end

	if value == "true" then
		return true
	end
	if value == "false" then
		return false
	end
	if value == "null" or value == "~" then
		return nil
	end

	local numeric = tonumber(value)
	if numeric ~= nil then
		return numeric
	end

	return value
end

local function collect_block(lines, index, parent_indent)
	local rows = {}
	local i = index
	while i <= #lines do
		local line = lines[i]
		local line_trim = trim(line)
		local line_indent = count_indent(line)
		if line_trim ~= "" and line_indent <= parent_indent then
			break
		end
		table.insert(rows, line)
		i = i + 1
	end

	local min_indent = nil
	for _, row in ipairs(rows) do
		if trim(row) ~= "" then
			local row_indent = count_indent(row)
			if min_indent == nil or row_indent < min_indent then
				min_indent = row_indent
			end
		end
	end

	if min_indent == nil then
		return "", i
	end

	local out = {}
	for _, row in ipairs(rows) do
		if trim(row) == "" then
			table.insert(out, "")
		else
			table.insert(out, row:sub(min_indent + 1))
		end
	end

	return table.concat(out, "\n"), i
end

local function collect_inline_continuation(lines, index, parent_indent)
	local block, next_i = collect_block(lines, index, parent_indent)
	if block == "" then
		return "", next_i
	end

	-- YAML plain multiline scalars fold newlines into spaces.
	local folded = trim(block:gsub("\n", " "))
	return folded, next_i
end

local function fold_block(block)
	return (
		block:gsub("\n+", function(line_breaks)
			if #line_breaks == 1 then
				return " "
			end
			return string.rep("\n", #line_breaks - 1)
		end)
	)
end

local function set_map_key(map, key, value)
	local order = rawget(map, "__order")
	if type(order) ~= "table" then
		order = {}
		rawset(map, "__order", order)
	end

	for idx, existing in ipairs(order) do
		if existing == key then
			table.remove(order, idx)
			break
		end
	end

	table.insert(order, key)
	map[key] = value
end

local function parse_sequence(lines, index, parent_indent)
	local list = {}
	local i = index

	while i <= #lines do
		local line = lines[i]
		local line_trim = trim(line)

		if line_trim == "" or line_trim:sub(1, 1) == "#" then
			i = i + 1
		else
			local line_indent = count_indent(line)
			if line_indent <= parent_indent then
				break
			end

			local item_value = line_trim:match("^-%s+(.*)$")
			if not item_value then
				break
			end

			table.insert(list, parse_scalar(strip_inline_comment(item_value)))
			i = i + 1
		end
	end

	return list, i
end

local function parse_map(lines, index, indent)
	local map = {}
	local i = index

	while i <= #lines do
		local line = lines[i]
		local line_trim = trim(line)

		if line_trim == "" or line_trim:sub(1, 1) == "#" then
			i = i + 1
		elseif line_trim == "---" or line_trim == "..." then
			i = i + 1
		else
			local line_indent = count_indent(line)
			if line_indent < indent then
				break
			end
			if line_indent > indent then
				break
			end

			local key, rest = line:match("^%s*([^:]+):%s*(.*)$")
			if not key then
				return nil, ("invalid yaml line %d: %s"):format(i, line)
			end

			key = trim(key)
			rest = strip_inline_comment(rest)
			local block_style = rest:match("^([|>])[+-]?$")
			if block_style then
				local block, next_i = collect_block(lines, i + 1, line_indent)
				if block_style == ">" then
					block = fold_block(block)
				end
				set_map_key(map, key, block)
				i = next_i
			elseif rest ~= "" then
				local value = parse_scalar(rest)
				local continuation, next_i = collect_inline_continuation(lines, i + 1, line_indent)
				if type(value) == "string" and continuation ~= "" then
					value = trim(value .. " " .. continuation)
				end
				set_map_key(map, key, value)
				i = next_i
			else
				local j = i + 1
				while j <= #lines do
					local next_trim = trim(lines[j])
					if next_trim == "" or next_trim:sub(1, 1) == "#" then
						j = j + 1
					else
						break
					end
				end

				if j > #lines then
					set_map_key(map, key, "")
					i = j
				else
					local next_indent = count_indent(lines[j])
					if next_indent <= line_indent then
						set_map_key(map, key, "")
						i = j
					else
						local next_trim = trim(lines[j])
						if next_trim:match("^-%s+") or next_trim == "-" then
							local seq, seq_next = parse_sequence(lines, j, line_indent)
							set_map_key(map, key, seq)
							i = seq_next
						elseif next_trim:match("^[%w_.-]+:%s*.*$") then
							local child, err_or_next = parse_map(lines, j, next_indent)
							if not child then
								return nil, err_or_next
							end
							set_map_key(map, key, child)
							i = err_or_next
						else
							local block, next_i = collect_block(lines, j, line_indent)
							set_map_key(map, key, block)
							i = next_i
						end
					end
				end
			end
		end
	end

	return map, i
end

function M.decode(text)
	local lines = split_lines(text)
	local parsed, err = parse_map(lines, 1, 0)
	if not parsed then
		return nil, err
	end
	return parsed
end

function M.decode_file(path)
	local fh, open_err = io.open(path, "r")
	if not fh then
		return nil, open_err
	end

	local content = fh:read("*a")
	fh:close()
	return M.decode(content)
end

return M
