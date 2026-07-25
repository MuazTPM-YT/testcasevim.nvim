-- Language detection and command resolution.
local config = require("testcasevim.config")
local util = require("testcasevim.util")

local M = {}

--- Identify the language for a buffer/file.
--- Extension wins; filetype is the fallback so `:set ft=cpp` on an odd
--- extension still works.
---@return string|nil key, table|nil spec
function M.detect(file, filetype)
	local langs = config.get().languages
	local ext = file and vim.fn.fnamemodify(file, ":e") or ""
	local lower = ext:lower()

	for key, spec in pairs(langs) do
		for _, candidate in ipairs(spec.extensions or {}) do
			if candidate == ext then
				return key, spec
			end
		end
	end
	for key, spec in pairs(langs) do
		for _, candidate in ipairs(spec.extensions or {}) do
			if candidate:lower() == lower and lower ~= "" then
				return key, spec
			end
		end
	end
	if filetype and filetype ~= "" then
		for key, spec in pairs(langs) do
			for _, candidate in ipairs(spec.filetypes or {}) do
				if candidate == filetype then
					return key, spec
				end
			end
		end
	end
	return nil, nil
end

--- Human readable list of what `run()` accepts, for error messages.
function M.supported_summary()
	local parts = {}
	for _, spec in pairs(config.get().languages) do
		local exts = {}
		for _, e in ipairs(spec.extensions or {}) do
			exts[#exts + 1] = "." .. e
		end
		parts[#parts + 1] = string.format("%s (%s)", spec.name, table.concat(exts, ", "))
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

--- Pick the `debug`/`release` variant of a command, if the spec has one.
local function for_mode(cmd, mode)
	if type(cmd) == "table" and (cmd.debug or cmd.release) then
		return cmd[mode] or cmd.debug or cmd.release
	end
	return cmd
end

--- Swap in an available alternative when the configured tool is missing
--- (e.g. clang++ on a machine without g++).
local function resolve_executable(exe)
	if vim.fn.executable(exe) == 1 then
		return exe
	end
	for _, alt in ipairs(config.get().fallbacks[exe] or {}) do
		if vim.fn.executable(alt) == 1 then
			return alt
		end
	end
	return nil
end

--- Turn a configured command into something `jobstart` can take.
--- Returns `cmd` (list or string), and `nil, err` when the toolchain is absent.
---@return string|table|nil cmd, string|nil err
function M.build_command(cmd, mode, vars)
	cmd = for_mode(cmd, mode)
	if cmd == nil then
		return nil, nil
	end

	if type(cmd) == "function" then
		cmd = cmd(vars, mode)
		if cmd == nil then
			return nil, nil
		end
	end

	if type(cmd) == "string" then
		-- Legacy `string.format` template with two `%s` (source, executable).
		local formatted
		if cmd:find("%%s") then
			local ok, res = pcall(string.format, cmd, vars.src, vars.exe)
			if not ok then
				return nil, "invalid command template: " .. cmd
			end
			formatted = res
		else
			formatted = util.expand(cmd, vars)
		end
		local exe = formatted:match("^%s*([^%s]+)")
		if exe and not exe:find("[/\\]") and vim.fn.executable(exe) ~= 1 then
			local alt = resolve_executable(exe)
			if not alt then
				return nil, string.format("`%s` was not found in $PATH", exe)
			end
			formatted = formatted:gsub("^(%s*)" .. vim.pesc(exe), "%1" .. alt, 1)
		end
		return formatted, nil
	end

	if type(cmd) ~= "table" then
		return nil, "command must be a list, a string or a function"
	end

	local argv = util.expand_argv(cmd, vars)
	if #argv == 0 then
		return nil, "empty command"
	end
	if not argv[1]:find("[/\\]") then
		local exe = resolve_executable(argv[1])
		if not exe then
			return nil, string.format("`%s` was not found in $PATH", argv[1])
		end
		argv[1] = exe
	elseif vim.fn.executable(argv[1]) ~= 1 then
		return nil, string.format("`%s` is not executable", argv[1])
	end
	return argv, nil
end

--- Environment additions for the run step.
function M.env(spec, mode)
	local env = spec.env
	if type(env) ~= "table" then
		return nil
	end
	if env.debug or env.release then
		return env[mode]
	end
	return env
end

--- Fully qualified Java class name: `package.Stem`, read from the source.
function M.java_class(file, lines)
	local stem = vim.fn.fnamemodify(file, ":t:r")
	local package
	for _, line in ipairs(lines or {}) do
		local pkg = line:match("^%s*package%s+([%w_%.]+)%s*;")
		if pkg then
			package = pkg
			break
		end
		-- Stop scanning once real code starts.
		if line:match("^%s*[%w@]") and not line:match("^%s*import%s") and not line:match("^%s*//") then
			break
		end
	end
	if package then
		return package .. "." .. stem
	end
	return stem
end

return M
