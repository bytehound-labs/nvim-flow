local yaml = require("nvim-flow.yaml")
local template = require("nvim-flow.template")
local path = require("nvim-flow.path")

local M = {}

local uv = vim.uv or vim.loop

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_list(tbl)
	if type(tbl) ~= "table" then
		return false
	end

	local count = 0
	for key, _ in pairs(tbl) do
		if type(key) ~= "number" then
			return false
		end
		count = count + 1
	end

	for i = 1, count do
		if tbl[i] == nil then
			return false
		end
	end

	return true
end

local function is_meta_key(key)
	return type(key) == "string" and key:sub(1, 2) == "__"
end

local function ordered_entry_keys(tbl)
	if type(tbl) ~= "table" then
		return {}
	end

	local keys = {}
	local seen = {}
	local order = rawget(tbl, "__order")
	if type(order) == "table" then
		for _, key in ipairs(order) do
			if tbl[key] ~= nil and not is_meta_key(key) and not seen[key] then
				table.insert(keys, key)
				seen[key] = true
			end
		end
	end

	local extras = {}
	for key, _ in pairs(tbl) do
		if not is_meta_key(key) and not seen[key] then
			table.insert(extras, key)
		end
	end
	table.sort(extras, function(a, b)
		return tostring(a) < tostring(b)
	end)

	for _, key in ipairs(extras) do
		table.insert(keys, key)
	end

	return keys
end

local function remove_order_key(order, key)
	for idx, existing in ipairs(order) do
		if existing == key then
			table.remove(order, idx)
			return
		end
	end
end

local function merge_orders(base_order, override_order)
	local out = vim.deepcopy(base_order)
	for i = #override_order, 1, -1 do
		local key = override_order[i]
		remove_order_key(out, key)
		table.insert(out, 1, key)
	end
	return out
end

local function deep_merge(base, override)
	local out = vim.deepcopy(base)
	local base_order = ordered_entry_keys(base)
	local override_order = ordered_entry_keys(override)

	for _, key in ipairs(override_order) do
		local value = override[key]
		if type(out[key]) == "table" and type(value) == "table" and not is_list(out[key]) and not is_list(value) then
			out[key] = deep_merge(out[key], value)
		else
			out[key] = vim.deepcopy(value)
		end
	end

	rawset(out, "__order", merge_orders(base_order, override_order))
	return out
end

local function file_exists(filepath)
	return uv.fs_stat(filepath) ~= nil
end

local function escape_lua_pattern(text)
	return (text:gsub("([^%w])", "%%%1"))
end

local function count_indent(line)
	local _, finish = line:find("^%s*")
	return finish or 0
end

local function find_top_level_key_line(lines, key)
	local key_pattern = "^" .. escape_lua_pattern(key) .. ":%s*"
	for idx, line in ipairs(lines) do
		if line:match(key_pattern) then
			return idx
		end
	end
	return nil
end

local function find_cmd_line_in_key_block(lines, key_line)
	local key_indent = count_indent(lines[key_line] or "")
	for idx = key_line + 1, #lines do
		local line = lines[idx]
		local line_trim = trim(line)
		if line_trim ~= "" then
			local line_indent = count_indent(line)
			if line_indent <= key_indent then
				break
			end
			if line_trim:match("^cmd:%s*") then
				return idx
			end
		end
	end
	return key_line
end

function M.find_config_files(filepath, opts)
	opts = opts or {}

	local config_file = opts.config_file or ".flow.yml"
	local stop_at_home = opts.stop_at_home ~= false
	local home = path.normalize(opts.home or uv.os_homedir())
	local dir = vim.fs.dirname(path.to_absolute(filepath))

	local files = {}
	while dir and dir ~= "" do
		local candidate = dir .. "/" .. config_file
		if file_exists(candidate) then
			table.insert(files, candidate)
		end

		if stop_at_home and dir == home then
			break
		end

		local parent = vim.fs.dirname(dir)
		if not parent or parent == dir then
			break
		end
		dir = parent
	end

	return files
end

function M.load_file(filepath)
	local parsed, err = yaml.decode_file(filepath)
	if not parsed then
		return nil, ("Failed parsing %s: %s"):format(filepath, err)
	end
	if type(parsed) ~= "table" then
		return {}
	end
	return parsed
end

function M.load_merged(filepath, opts)
	opts = opts or {}

	local files = M.find_config_files(filepath, opts)
	local config_file = opts.config_file or ".flow.yml"
	if #files == 0 then
		return nil, nil, ("No `%s` found while walking up from %s"):format(config_file, filepath)
	end

	local merged = {}
	for i = #files, 1, -1 do
		local parsed, parse_err = M.load_file(files[i])
		if not parsed then
			return nil, nil, parse_err
		end
		merged = deep_merge(merged, parsed)
	end
	return merged, files
end

function M.find_source_location(source_key, source_files)
	if type(source_key) ~= "string" or source_key == "" then
		return nil, "invalid flow source key"
	end
	if type(source_files) ~= "table" or #source_files == 0 then
		return nil, "no source flow files available"
	end

	for _, flow_file in ipairs(source_files) do
		local ok, lines = pcall(vim.fn.readfile, flow_file)
		if not ok then
			return nil, ("failed reading %s"):format(flow_file)
		end
		local key_line = find_top_level_key_line(lines, source_key)
		if key_line then
			local line = find_cmd_line_in_key_block(lines, key_line)
			return {
				file = flow_file,
				line = line,
			}
		end
	end

	return nil, ("unable to locate `%s` in resolved flow files"):format(source_key)
end

-- Inverse of find_top_level_key_line: given raw config lines and a 1-based
-- cursor line, return the nearest top-level (indent-0, non-comment) key at or
-- above the cursor, i.e. the flow entry the cursor sits in.
function M.find_key_at_line(lines, lnum)
	if type(lines) ~= "table" then
		return nil
	end

	local total = #lines
	if total == 0 then
		return nil
	end

	local start = tonumber(lnum) or total
	if start < 1 then
		start = 1
	elseif start > total then
		start = total
	end

	for idx = start, 1, -1 do
		local line = lines[idx]
		if type(line) == "string" and line:match("%S") and count_indent(line) == 0 and not line:match("^#") then
			local key = line:match("^([^%s:][^:]-):")
			if key then
				return key, idx
			end
		end
	end

	return nil
end

local function has_glob(pattern)
	return pattern:find("[%*%?%[]") ~= nil
end

local function glob_match(pattern, value)
	local regpat = vim.fn.glob2regpat(pattern)
	return vim.fn.match(value, regpat) ~= -1
end

local function pattern_matches(pattern, ctx)
	pattern = trim(tostring(pattern or ""))
	if pattern == "" then
		return false
	end

	local exact_candidates = {
		ctx.basename,
		ctx.folder,
		ctx.repo,
		ctx.ext,
		ctx.dotext,
	}
	for _, candidate in ipairs(exact_candidates) do
		if pattern == candidate then
			return true
		end
	end

	if pattern:sub(-1) == "/" then
		if ctx.filepath:find("/" .. pattern, 1, true) or ctx.filepath:sub(-#pattern) == pattern then
			return true
		end
	end

	if has_glob(pattern) then
		local glob_candidates = {
			ctx.basename,
			ctx.folder,
			ctx.repo,
			ctx.ext,
			ctx.dotext,
			ctx.filepath,
			ctx.dir,
		}
		for _, candidate in ipairs(glob_candidates) do
			if glob_match(pattern, candidate) then
				return true
			end
		end
	end

	if ctx.filepath:find("/" .. pattern .. "/", 1, true) then
		return true
	end

	return false
end

function M.find_match(flow_defs, ctx)
	local basename_match = flow_defs[ctx.basename]
	if type(basename_match) == "table" then
		return ctx.basename, basename_match
	end

	for _, key in ipairs(ordered_entry_keys(flow_defs)) do
		local entry = flow_defs[key]
		if type(entry) == "table" then
			local patterns = entry.match
			if patterns ~= nil then
				if type(patterns) == "string" then
					patterns = { patterns }
				end
				if is_list(patterns) then
					for _, pattern in ipairs(patterns) do
						if pattern_matches(pattern, ctx) then
							return key, entry
						end
					end
				end
			end
		end
	end

	local folder_match = flow_defs[ctx.folder]
	if type(folder_match) == "table" then
		return ctx.folder, folder_match
	end

	local repo_match = flow_defs[ctx.repo]
	if type(repo_match) == "table" then
		return ctx.repo, repo_match
	end

	local dotext_match = flow_defs[ctx.dotext]
	if type(dotext_match) == "table" then
		return ctx.dotext, dotext_match
	end

	local ext_match = flow_defs[ctx.ext]
	if type(ext_match) == "table" then
		return ctx.ext, ext_match
	end

	local default_match = flow_defs.default
	if type(default_match) == "table" then
		return "default", default_match
	end

	return nil
end

local function normalize_runner(runner)
	if runner == nil or runner == "" then
		return "terminal"
	end

	runner = tostring(runner):gsub("_", "-")
	if runner == "vim" or runner == "terminal" then
		return "terminal"
	end
	if runner == "debug" then
		return "debug"
	end
	return nil
end

function M.normalize_cmd_def(key, entry, ctx)
	if type(entry) ~= "table" then
		return nil, ("invalid entry for key `%s`"):format(key)
	end

	if type(entry.cmd) ~= "string" then
		return nil, ("entry `%s` must define a string `cmd`"):format(key)
	end

	local cmd_def = vim.deepcopy(entry)
	cmd_def.runner = normalize_runner(cmd_def.runner)
	if not cmd_def.runner then
		return nil, ("invalid runner for `%s`; expected one of: vim, terminal, debug"):format(key)
	end

	cmd_def.cmd = template.expand(cmd_def.cmd, {
		filepath = ctx.filepath,
		dir = ctx.dir,
		filename = ctx.filename,
		ext = ctx.ext,
		repo = ctx.repo,
		folder = ctx.folder,
	})

	if not cmd_def.cmd:match("^#!") then
		cmd_def.cmd = "#!/usr/bin/env bash\n" .. cmd_def.cmd
	end

	cmd_def.source_key = key
	return cmd_def
end

function M.resolve(filepath, opts)
	opts = opts or {}
	local ctx = path.build_context(filepath)

	local flow_defs, source_files, load_err = M.load_merged(ctx.filepath, opts)
	if not flow_defs then
		return nil, load_err
	end

	local key, entry = M.find_match(flow_defs, ctx)
	if not entry then
		return nil, ("No matching flow definition found in `%s`"):format(opts.config_file or ".flow.yml")
	end

	local cmd_def, normalize_err = M.normalize_cmd_def(key, entry, ctx)
	if not cmd_def then
		return nil, normalize_err
	end

	cmd_def.filepath = ctx.filepath
	cmd_def.source_files = source_files
	return cmd_def
end

local FILE_SCOPED_VARS = { "filepath", "filename", "ext" }

-- File-scoped template vars only make sense with a concrete source file, so
-- cursor-runs resolve one lazily (only when such a var is actually used).
local function cmd_uses_file_scoped_var(cmd)
	if type(cmd) ~= "string" then
		return false
	end
	for _, name in ipairs(FILE_SCOPED_VARS) do
		if cmd:find("{{%s*" .. name .. "%s*}}") then
			return true
		end
	end
	return false
end

function M.uses_file_scoped_var(cmd)
	return cmd_uses_file_scoped_var(cmd)
end

local function looks_like_path_pattern(value)
	if type(value) ~= "string" then
		return false
	end
	return value:find("/") ~= nil or value:find("[%*%?%[%]]") ~= nil or value:match("%.[%w]+$") ~= nil
end

local function glob_under(root, pattern)
	local full
	if pattern:sub(1, 1) == "/" then
		full = pattern
	elseif pattern:find("/") then
		full = root .. "/" .. pattern
	else
		full = root .. "/**/" .. pattern
	end

	local ok, result = pcall(vim.fn.glob, full, true, true)
	if not ok or type(result) ~= "table" then
		return {}
	end
	return result
end

local function candidate_patterns(key, entry)
	local patterns = {}
	local seen = {}
	local function add(value)
		value = trim(tostring(value or ""))
		if value ~= "" and looks_like_path_pattern(value) and not seen[value] then
			seen[value] = true
			table.insert(patterns, value)
		end
	end

	local match = entry.match
	if type(match) == "string" then
		match = { match }
	end
	if is_list(match) then
		for _, pattern in ipairs(match) do
			add(pattern)
		end
	end
	add(key)

	return patterns
end

-- Resolve the single source file an entry references, for filling file-scoped
-- template vars: locked file wins, otherwise glob the entry's path-like
-- match/key patterns under the repo root and require exactly one match.
local function resolve_entry_file(flow_file, key, entry)
	local locked = require("nvim-flow.lock").get()
	if locked then
		return path.to_absolute(locked)
	end

	local search_base = path.detect_repo_root(flow_file) or vim.fs.dirname(flow_file)

	local matches = {}
	local seen = {}
	for _, pattern in ipairs(candidate_patterns(key, entry)) do
		for _, found in ipairs(glob_under(search_base, pattern)) do
			local abs = path.normalize(found)
			if abs and vim.fn.filereadable(abs) == 1 and not seen[abs] then
				seen[abs] = true
				table.insert(matches, abs)
			end
		end
	end

	if #matches == 0 then
		return nil,
			("`%s` uses a file-scoped template variable but no file matched its `match`/key under %s; open the target file, or set a lock with :FlowSet"):format(
				key,
				search_base
			)
	end
	if #matches > 1 then
		table.sort(matches)
		return nil,
			("`%s` matched %d files under %s; expected exactly one. Narrow the `match`, or set a lock with :FlowSet"):format(
				key,
				#matches,
				search_base
			)
	end

	return matches[1]
end

-- Context used when an entry needs no source file: project vars derive from the
-- defining .flow.yml's own location.
local function config_context(flow_file)
	local dir = vim.fs.dirname(flow_file)
	return {
		filepath = flow_file,
		dir = dir,
		basename = vim.fs.basename(flow_file),
		filename = "",
		ext = "",
		dotext = "",
		folder = vim.fs.basename(dir),
		repo = path.detect_repo_name(flow_file),
	}
end

-- Resolve a cmd_def for a single entry `key` defined in `flow_file`, as used by
-- run-from-.flow.yml. `text` (optional) is the live buffer content, so unsaved
-- edits are honored without forcing a write.
function M.resolve_at(flow_file, key, opts, text)
	opts = opts or {}
	if type(key) ~= "string" or key == "" then
		return nil, "no flow entry under cursor"
	end
	flow_file = path.to_absolute(flow_file)

	local flow_defs, err
	if text ~= nil then
		flow_defs, err = yaml.decode(text)
		if not flow_defs then
			return nil, ("Failed parsing %s: %s"):format(flow_file, err)
		end
		if type(flow_defs) ~= "table" then
			flow_defs = {}
		end
	else
		flow_defs, err = M.load_file(flow_file)
		if not flow_defs then
			return nil, err
		end
	end

	local entry = flow_defs[key]
	if type(entry) ~= "table" then
		return nil, ("no flow entry `%s` found in %s"):format(key, vim.fs.basename(flow_file))
	end
	if type(entry.cmd) ~= "string" then
		return nil, ("entry `%s` must define a string `cmd`"):format(key)
	end

	local ctx
	if cmd_uses_file_scoped_var(entry.cmd) then
		local file, file_err = resolve_entry_file(flow_file, key, entry)
		if not file then
			return nil, file_err
		end
		ctx = path.build_context(file)
	else
		ctx = config_context(flow_file)
	end

	local cmd_def, normalize_err = M.normalize_cmd_def(key, entry, ctx)
	if not cmd_def then
		return nil, normalize_err
	end

	cmd_def.filepath = ctx.filepath
	cmd_def.source_files = { flow_file }
	return cmd_def
end

return M
