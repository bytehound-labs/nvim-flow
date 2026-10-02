local M = {}
local uv = vim.uv or vim.loop

function M.normalize(path)
	if not path or path == "" then
		return nil
	end

	if path:sub(1, 1) ~= "/" then
		path = vim.fn.fnamemodify(path, ":p")
	end

	return vim.fs.normalize(path)
end

function M.to_absolute(path)
	return M.normalize(path)
end

function M.split_filename(basename)
	local filename, ext = basename:match("^(.*)%.([^%.]+)$")
	if not filename then
		return basename, "", ""
	end
	return filename, ext, "." .. ext
end

function M.detect_repo_root(filepath)
	local start = vim.fs.dirname(filepath)
	if vim.fs.root then
		return vim.fs.root(start, { ".git" })
	end

	local dir = start
	while dir and dir ~= "" do
		if uv.fs_stat(dir .. "/.git") then
			return dir
		end
		local parent = vim.fs.dirname(dir)
		if not parent or parent == dir then
			break
		end
		dir = parent
	end
	return nil
end

function M.detect_repo_name(filepath)
	local root = M.detect_repo_root(filepath)
	if root then
		return vim.fs.basename(root)
	end
	return ""
end

function M.resolve_execution_cwd(filepath, policy)
	if policy == nil then
		policy = "repo"
	end
	if policy ~= "repo" and policy ~= "nvim" then
		return nil, ("invalid cwd policy `%s`; expected `repo` or `nvim`"):format(tostring(policy))
	end

	if policy == "nvim" then
		local current = M.normalize(vim.fn.getcwd())
		if not current then
			return nil, "unable to determine Neovim's current working directory"
		end
		return current
	end

	local absolute = M.to_absolute(filepath)
	if not absolute then
		return nil, "cannot resolve a working directory without a file path"
	end
	return M.detect_repo_root(absolute) or vim.fs.dirname(absolute)
end

function M.resolve_cwd_override(override, base)
	if type(override) ~= "string" or override == "" then
		return nil, "cwd override must be a non-empty directory path"
	end

	local absolute
	if vim.fn.isabsolutepath(override) == 1 then
		absolute = vim.fs.normalize(override)
	else
		absolute = vim.fs.normalize(base .. "/" .. override)
	end

	local stat = uv.fs_stat(absolute)
	if not stat or stat.type ~= "directory" then
		return nil, ("cwd override is not an existing directory: %s"):format(absolute)
	end
	return absolute
end

function M.build_context(filepath)
	local absolute = M.to_absolute(filepath)
	local dir = vim.fs.dirname(absolute)
	local basename = vim.fs.basename(absolute)
	local filename, ext, dotext = M.split_filename(basename)
	return {
		filepath = absolute,
		dir = dir,
		basename = basename,
		filename = filename,
		ext = ext,
		dotext = dotext,
		folder = vim.fs.basename(dir),
		repo = M.detect_repo_name(absolute),
	}
end

return M
