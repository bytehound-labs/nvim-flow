local config = require("nvim-flow.config")
local lock = require("nvim-flow.lock")
local path = require("nvim-flow.path")

local M = {}

local supported_languages = {
	bash = true,
	sh = true,
	shell = true,
}

local function node_text(node, source)
	local ok, text = pcall(vim.treesitter.get_node_text, node, source)
	if not ok or type(text) ~= "string" then
		return nil
	end
	return text
end

local function walk(node, callback)
	callback(node)
	for child in node:iter_children() do
		walk(child, callback)
	end
end

local function line_for_row(lines, row)
	return lines[row + 1] or ""
end

local function prefix_widths(root)
	local continuation_width = {}
	local quote_width = {}

	walk(root, function(node)
		local node_type = node:type()
		local start_row, start_col, end_row, end_col = node:range()
		if start_row ~= end_row then
			return
		end

		if node_type == "block_quote_marker" then
			if end_col > (quote_width[start_row] or 0) then
				quote_width[start_row] = end_col
			end
		elseif
			node_type == "block_continuation"
			and start_col == 0
			and end_col > (continuation_width[start_row] or 0)
		then
			continuation_width[start_row] = end_col
		end
	end)

	return continuation_width, quote_width
end

local function direct_child(node, child_type)
	for child in node:iter_children() do
		if child:type() == child_type then
			return child
		end
	end
	return nil
end

local function first_descendant(node, node_type)
	if node:type() == node_type then
		return node
	end
	for child in node:iter_children() do
		local found = first_descendant(child, node_type)
		if found then
			return found
		end
	end
	return nil
end

local function fence_opening(node, lines, source)
	local delimiter = direct_child(node, "fenced_code_block_delimiter")
	if not delimiter then
		return nil
	end

	local row, column = delimiter:range()
	local line = line_for_row(lines, row)
	local suffix = line:sub(column + 1)
	local indent = suffix:match("^( *)") or ""
	if #indent > 3 then
		return nil
	end

	local rest = suffix:sub(#indent + 1)
	local first = rest:sub(1, 1)
	if first ~= "`" and first ~= "~" then
		return nil
	end
	local fence = rest:match("^(`+)") or rest:match("^(~+)")
	if not fence or #fence < 3 then
		return nil
	end

	local info = direct_child(node, "info_string")
	local language_node = info and first_descendant(info, "language") or nil
	local language = language_node and node_text(language_node, source) or nil
	local prefix = (column + #indent)
	return {
		row = row,
		char = first,
		length = #fence,
		marker_column = prefix,
		language = language and language:lower() or nil,
	}
end

local function last_row(node)
	local _, _, end_row, end_column = node:range()
	if end_column == 0 then
		return math.max(end_row - 1, 0)
	end
	return end_row
end

local function container_last_row(node, block_end_row)
	local limit = block_end_row
	local parent = node:parent()
	while parent do
		local parent_type = parent:type()
		if parent_type == "block_quote" or parent_type == "list_item" then
			limit = math.min(limit, last_row(parent))
		end
		parent = parent:parent()
	end
	return limit
end

local function list_item_prefix_width(node, continuation_width)
	local parent = node:parent()
	while parent do
		if parent:type() == "list_item" then
			return continuation_width
		end
		parent = parent:parent()
	end
	return 0
end

local function opening_container_width(opening, continuation_width, quote_width)
	local width = continuation_width[opening.row] or 0
	local quote_marker_width = quote_width[opening.row] or 0
	return math.min(math.max(width, quote_marker_width), opening.marker_column)
end

local function strip_prefix(line, continuation_width, indent)
	local prefix_width = math.min(continuation_width or 0, #line)
	local remainder = line:sub(prefix_width + 1)
	local leading_spaces = remainder:match("^( *)") or ""
	local remove_indent = math.min(#leading_spaces, indent or 0)
	return remainder:sub(remove_indent + 1)
end

local function matches_closing_fence(line, opening, continuation_width)
	local prefix_width = math.min(continuation_width or 0, #line)
	local remainder = line:sub(prefix_width + 1)
	local indent = remainder:match("^( *)") or ""
	if #indent > 3 then
		return false
	end

	remainder = remainder:sub(#indent + 1)
	local fence
	if opening.char == "`" then
		fence = remainder:match("^(`+)")
	else
		fence = remainder:match("^(~+)")
	end
	if not fence or #fence < opening.length then
		return false
	end

	local trailing = remainder:sub(#fence + 1)
	return trailing:match("^[ \t]*$") ~= nil
end

local function find_closing_row(node, opening, lines, continuation_width)
	local end_row = container_last_row(node, last_row(node))
	local required_prefix_width = list_item_prefix_width(node, continuation_width[opening.row] or 0)
	for row = opening.row + 1, math.min(end_row, #lines - 1) do
		local prefix_width = continuation_width[row] or 0
		if
			prefix_width >= required_prefix_width
			and matches_closing_fence(line_for_row(lines, row), opening, prefix_width)
		then
			return row
		end
	end
	return nil
end

local function extract_body(lines, opening, closing_row, continuation_width, source_indent)
	local body = {}
	for row = opening.row + 1, closing_row - 1 do
		table.insert(body, strip_prefix(line_for_row(lines, row), continuation_width[row], source_indent))
	end

	if #body == 0 then
		return nil, "the selected shell fence is empty"
	end

	local command = table.concat(body, "\n")
	if command:match("^%s*$") then
		return nil, "the selected shell fence is empty"
	end
	return command
end

local function parse_markdown(lines)
	if not vim.treesitter or type(vim.treesitter.get_string_parser) ~= "function" then
		return nil, "Markdown execution requires Neovim's Tree-sitter string parser API"
	end

	local source = table.concat(lines, "\n")
	local ok, parser = pcall(vim.treesitter.get_string_parser, source, "markdown")
	if not ok or not parser then
		local detail = ok and "no parser was returned" or tostring(parser)
		return nil, ("Markdown execution requires the Tree-sitter `markdown` parser on runtimepath: %s"):format(detail)
	end

	local parsed, trees = pcall(function()
		return parser:parse()
	end)
	if not parsed or type(trees) ~= "table" or not trees[1] then
		local detail = parsed and "parser returned no syntax tree" or tostring(trees)
		return nil, ("failed to parse Markdown with Tree-sitter: %s"):format(detail)
	end

	return trees[1]:root(), source
end

function M.extract_block(lines, lnum)
	if type(lines) ~= "table" or #lines == 0 then
		return nil, "the current buffer has no Markdown content"
	end

	local row = math.max(1, math.min(tonumber(lnum) or 1, #lines)) - 1
	local root, source = parse_markdown(lines)
	if not root then
		return nil, source
	end

	local continuation_width, quote_width = prefix_widths(root)
	local candidates = {}
	walk(root, function(node)
		if node:type() ~= "fenced_code_block" then
			return
		end

		local opening = fence_opening(node, lines, source)
		if not opening then
			return
		end
		local closing_row = find_closing_row(node, opening, lines, continuation_width)
		if not closing_row then
			if row >= opening.row and row <= container_last_row(node, last_row(node)) then
				table.insert(candidates, {
					error = "the selected fenced code block has no matching closing fence",
					start_row = opening.row,
				})
			end
			return
		end

		if row < opening.row or row > closing_row then
			return
		end

		local source_indent =
			math.max(0, opening.marker_column - opening_container_width(opening, continuation_width, quote_width))
		local command, body_err = extract_body(lines, opening, closing_row, continuation_width, source_indent)
		table.insert(candidates, {
			command = command,
			error = body_err,
			language = opening.language,
			start_row = opening.row,
			closing_row = closing_row,
		})
	end)

	if #candidates == 0 then
		return nil, "cursor is not inside a fenced Markdown code block"
	end

	table.sort(candidates, function(left, right)
		local left_end = left.closing_row or math.huge
		local right_end = right.closing_row or math.huge
		local left_span = left_end - left.start_row
		local right_span = right_end - right.start_row
		return left_span < right_span
	end)

	local selected = candidates[1]
	if selected.error then
		return nil, selected.error
	end
	if not selected.language or not supported_languages[selected.language] then
		local language = selected.language and ("`" .. selected.language .. "`") or "unlabeled"
		return nil,
			("the selected Markdown fence is %s; supported shell fences are `sh`, `bash`, and `shell`"):format(language)
	end

	return {
		command = selected.command,
		line = selected.start_row + 1,
		language = selected.language,
	}
end

function M.resolve_at(filepath, lines, lnum)
	if type(filepath) ~= "string" or filepath == "" then
		return nil, "current buffer has no file path"
	end

	local block, err = M.extract_block(lines, lnum)
	if not block then
		return nil, err
	end

	local context_path = path.to_absolute(filepath)
	if config.uses_file_scoped_var(block.command) then
		context_path = lock.get()
		if not context_path then
			return nil,
				("Markdown block in %s uses a file-scoped template variable; open the target file or set one with :FlowSet"):format(
					vim.fs.basename(filepath)
				)
		end
	end

	local ctx = path.build_context(context_path)
	local source_key = ("%s:%d"):format(vim.fs.basename(filepath), block.line)
	local cmd_def, normalize_err = config.normalize_cmd_def(source_key, { cmd = block.command }, ctx)
	if not cmd_def then
		return nil, normalize_err
	end

	cmd_def.filepath = ctx.filepath
	cmd_def.source_files = { path.to_absolute(filepath) }
	cmd_def.block_line = block.line
	return cmd_def
end

return M
