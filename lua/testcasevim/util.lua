-- Small, dependency-free helpers shared by the rest of the plugin.
local M = {}

local uv = vim.uv or vim.loop

--- Monotonic timestamp in nanoseconds.
function M.now()
	return uv.hrtime()
end

--- Milliseconds elapsed since a timestamp taken with `M.now()`.
function M.elapsed_ms(start)
	if not start then
		return nil
	end
	return (uv.hrtime() - start) / 1e6
end

--- Human friendly duration, e.g. "412ms" / "1.24s".
function M.fmt_duration(ms)
	if not ms then
		return nil
	end
	if ms < 1000 then
		return string.format("%dms", math.floor(ms + 0.5))
	end
	return string.format("%.2fs", ms / 1000)
end

-- CSI sequences (colors, cursor moves, ...) plus a few OSC forms.
local CSI = "\27%[[%d;:?]*[ -/]*[@-~]"

--- Remove ANSI escape sequences and stray control characters from a line.
--- Tabs are kept (Neovim renders them), everything else that would show up as
--- `^[` or `^M` garbage in the output pane is dropped.
function M.strip_ansi(s)
	if type(s) ~= "string" then
		return ""
	end
	if s:find("\27", 1, true) then
		s = s:gsub("\27%][^\7\27]*\7", "") -- OSC ... BEL
		s = s:gsub("\27%][^\27]*\27\\", "") -- OSC ... ST
		s = s:gsub(CSI, "")
		s = s:gsub("\27[%(%)#%%][%w]", "") -- charset selection
		s = s:gsub("\27[@-Z\\-_]", "") -- remaining single-char escapes
	end
	if s:find("\r", 1, true) then
		-- A trailing CR is just a CRLF line ending.
		s = s:gsub("\r+$", "")
		-- An interior CR means "redraw this line"; keep only the final state.
		s = s:gsub("^.*\r", "")
	end
	s = s:gsub("[\1-\8\11\12\14-\31\127]", "")
	return s
end

--- Expand `{key}` placeholders in a string.
function M.expand(str, vars)
	return (str:gsub("{(%w+)}", function(key)
		local v = vars[key]
		return v ~= nil and tostring(v) or ("{" .. key .. "}")
	end))
end

--- Expand placeholders in every element of an argv list.
function M.expand_argv(argv, vars)
	local out = {}
	for i, part in ipairs(argv) do
		out[i] = M.expand(part, vars)
	end
	return out
end

--- Strip long, uninteresting directory prefixes so diagnostics read as
--- `sol.cpp:42` instead of `/home/…/cache/testcasevim/bin/sol.cpp:42`.
function M.shorten_paths(line, dirs)
	for _, dir in ipairs(dirs or {}) do
		if dir and dir ~= "" then
			line = line:gsub(vim.pesc(dir .. "/"), "")
		end
	end
	return line
end

--- Short, stable, filesystem-safe id for a string (used for cache paths).
function M.hash(s)
	local ok, digest = pcall(vim.fn.sha256, s)
	if ok and type(digest) == "string" then
		return digest:sub(1, 12)
	end
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 4294967296
	end
	return string.format("%08x", h)
end

--- Replace anything that is not safe in a file name.
function M.slugify(s)
	return (s:gsub("[^%w%-_%.]", "_"))
end

--- Incremental line assembler for `jobstart` stdout/stderr chunks.
---
--- `jobstart` splits data on newlines but the first element of a chunk
--- continues the previous element and the last element may be a partial line.
--- The original implementation ignored this and could split a single line of
--- output across two buffer lines.
function M.new_stream()
	return { partial = "" }
end

--- Feed a raw chunk; returns the list of *complete* lines it produced.
function M.stream_feed(stream, data)
	local lines = {}
	if not data then
		return lines
	end
	for i, chunk in ipairs(data) do
		if i == 1 then
			stream.partial = stream.partial .. chunk
		else
			lines[#lines + 1] = stream.partial
			stream.partial = chunk
		end
	end
	return lines
end

--- Return whatever is left in the buffer (call once, when the job exits).
function M.stream_flush(stream)
	local rest = stream.partial
	stream.partial = ""
	if rest ~= "" then
		return { rest }
	end
	return {}
end

--- `true` when every line in the list is empty.
function M.all_blank(lines)
	for _, line in ipairs(lines) do
		if line:match("%S") then
			return false
		end
	end
	return true
end

--- Drop trailing blank lines.
function M.trim_trailing_blank(lines)
	while #lines > 0 and not lines[#lines]:match("%S") do
		table.remove(lines)
	end
	return lines
end

--- mkdir -p that never throws.
function M.ensure_dir(path)
	if vim.fn.isdirectory(path) == 1 then
		return true
	end
	return pcall(vim.fn.mkdir, path, "p")
end

--- Notify with a consistent title, on the main loop.
function M.notify(msg, level)
	vim.schedule(function()
		vim.notify(msg, level or vim.log.levels.INFO, { title = "testcasevim" })
	end)
end

--- Signal name / meaning for a process exit code, or nil.
--- Neovim reports signal deaths as 128 + signal number.
local SIGNALS = {
	[128 + 2] = { "SIGINT", "interrupted" },
	[128 + 4] = { "SIGILL", "illegal instruction" },
	[128 + 6] = { "SIGABRT", "aborted — failed assert, uncaught exception or sanitizer stop" },
	[128 + 8] = { "SIGFPE", "arithmetic error — division or modulo by zero" },
	[128 + 9] = { "SIGKILL", "killed — usually out of memory" },
	[128 + 11] = { "SIGSEGV", "segmentation fault — bad pointer, overflow or infinite recursion" },
	[128 + 13] = { "SIGPIPE", "broken pipe" },
	[128 + 15] = { "SIGTERM", "terminated" },
}

function M.describe_exit(code)
	local sig = SIGNALS[code]
	if sig then
		return sig[1], sig[2]
	end
	if code == 1 then
		return nil, "non-zero exit"
	end
	return nil, nil
end

return M
