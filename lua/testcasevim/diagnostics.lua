-- Turning raw compiler / runtime noise into something precise and readable.
local M = {}

----------------------------------------------------------------------
-- Compiler diagnostics
----------------------------------------------------------------------

-- `file:line:col: severity: message`  (gcc, clang)
-- `file:line: severity: message`      (javac)
local function match_header(line)
	local file, lnum, col, sev, msg = line:match("^(.-):(%d+):(%d+):%s+([%a ]-):%s*(.*)$")
	if not file then
		file, lnum, sev, msg = line:match("^(.-):(%d+):%s+([%a ]-):%s*(.*)$")
		col = nil
	end
	if not file or file == "" then
		return nil
	end
	sev = vim.trim(sev or ""):lower()
	if sev == "fatal error" then
		sev = "error"
	end
	if sev ~= "error" and sev ~= "warning" and sev ~= "note" then
		return nil
	end
	return {
		file = file,
		lnum = tonumber(lnum),
		col = col and tonumber(col) or nil,
		severity = sev,
		message = msg or "",
		context = {},
	}
end

--- Parse compiler stderr into a list of diagnostics.
--- Source excerpts (the `   5 | int x;` / `     | ^` lines gcc prints) are
--- attached to the diagnostic they belong to instead of floating loose.
---@return table[] diagnostics, table counts, string[] leftovers
function M.parse_compiler(lines)
	local diags, leftovers = {}, {}
	local counts = { error = 0, warning = 0, note = 0 }
	local current

	for _, raw in ipairs(lines) do
		local line = raw
		local diag = match_header(line)
		if diag then
			diags[#diags + 1] = diag
			counts[diag.severity] = (counts[diag.severity] or 0) + 1
			current = diag
		elseif current and (line:match("^%s*%d*%s*|") or line:match("^%s+[%^~|]") or line:match("^%s%s+%S")) then
			current.context[#current.context + 1] = line
		elseif line:match("^%S.*:%s+In .+:$") or line:match("^%S.*:%s+At global scope:$") then
			-- "main.cpp: In function 'int main()':" — scope banner.
			current = nil
			leftovers[#leftovers + 1] = line
		elseif line:match("^%d+ errors?$") or line:match("^%d+ warnings?$") then
			-- javac's own tally; the section header already shows it.
			current = nil
		elseif line:match("%S") then
			current = nil
			leftovers[#leftovers + 1] = line
		end
	end

	return diags, counts, leftovers
end

--- "2 errors · 1 warning"
function M.summarize_counts(counts, sep)
	local parts = {}
	local order = { { "error", "error", "errors" }, { "warning", "warning", "warnings" }, { "note", "note", "notes" } }
	for _, item in ipairs(order) do
		local n = counts[item[1]] or 0
		if n > 0 then
			parts[#parts + 1] = string.format("%d %s", n, n == 1 and item[2] or item[3])
		end
	end
	return table.concat(parts, sep or " · ")
end

----------------------------------------------------------------------
-- Runtime stderr classification
----------------------------------------------------------------------

-- Anything matching these means "this is a real failure, not a debug print".
-- Once one matches, the rest of stderr belongs to the same report.
local FAILURE_PATTERNS = {
	"AddressSanitizer",
	"LeakSanitizer",
	"ThreadSanitizer",
	"MemorySanitizer",
	"UndefinedBehaviorSanitizer",
	"^%s*==%d+==",
	"^SUMMARY:%s",
	"runtime error:",
	"Segmentation fault",
	"Bus error",
	"Floating point exception",
	"terminate called",
	"^%s*what%(%):",
	"[Aa]ssertion .* failed",
	"%*%*%* stack smashing detected",
	"%*%*%* buffer overflow detected",
	"free%(%): ",
	"double free",
	"malloc%(%): ",
	"corrupted size vs%. prev_size",
	"std::bad_alloc",
	"std::out_of_range",
	"Error: attempt to", -- _GLIBCXX_DEBUG
	"^/usr/include/c%+%+/",
	"^%s*#%d+%s+0x%x+",
	-- Python
	"^Traceback %(most recent call last%)",
	"^%s*File \"[^\"]+\", line %d+",
	"^%u[%w_]*Error:",
	"^%u[%w_]*Exception:",
	"^SystemExit",
	"^KeyboardInterrupt",
	-- Java
	"^Exception in thread",
	"^%s*at [%w_$%.]+%(",
	"^Caused by:",
	"^[%w_%.]*%.[%u][%w_]*Exception",
	"^[%w_%.]*%.[%u][%w_]*Error",
	"^%s*%.%.%. %d+ more",
	"Error: Could not find or load main class",
	"Error: Main method not found",
}

--- Does this stderr line look like a crash/diagnostic rather than a trace?
function M.is_failure_line(line)
	for _, pat in ipairs(FAILURE_PATTERNS) do
		if line:find(pat) then
			return true
		end
	end
	return false
end

-- `func:line [expr] = [value]` — the classic competitive-programming
-- `dbg(...)` macro, which is what `-DDEBUG` builds emit on stderr.
function M.parse_trace(line)
	local where, lnum, expr, value = line:match("^%s*([%w_:~<>%s%*&%(%),%.]-):(%d+)%s+%[(.-)%]%s*=%s*%[(.*)%]%s*$")
	if where and where ~= "" then
		return {
			location = string.format("%s:%s", vim.trim(where), lnum),
			expr = vim.trim(expr),
			value = vim.trim(value),
		}
	end
	-- `[expr] = [value]` without a location prefix.
	local e, v = line:match("^%s*%[(.-)%]%s*=%s*%[(.*)%]%s*$")
	if e then
		return { location = "", expr = vim.trim(e), value = vim.trim(v) }
	end
	return nil
end

----------------------------------------------------------------------
-- Condensing sanitizer / interpreter reports
----------------------------------------------------------------------

-- Pure noise: shadow-byte dumps, separator rules, build ids.
local NOISE = {
	"^=====+$",
	"^%s*ABORTING%s*$",
	"^%s*=?>?0x%x+:%s*%x%x %x%x",
	"^%s*%x%x %x%x %x%x %x%x",
	"^%s*%^%s*$",
}

-- Everything from here on is reference material, not evidence.
local STOP = {
	"^Shadow bytes around the buggy address:",
	"^Shadow byte legend",
}

local function is_noise(line)
	for _, pat in ipairs(NOISE) do
		if line:find(pat) then
			return true
		end
	end
	return false
end

local function is_frame(line)
	return line:match("^%s*#%d+%s") ~= nil
end

--- Drop the parts of a crash report that never help, and collapse runs of
--- frames that live outside the user's own file.
function M.condense(lines, basename)
	local out = {}
	local pending, single = 0, nil

	local function flush_frames()
		if pending == 1 and single then
			out[#out + 1] = single
		elseif pending > 1 then
			out[#out + 1] = string.format("    … %d frames in system libraries", pending)
		end
		pending, single = 0, nil
	end

	local skipping_signature = false

	for _, raw in ipairs(lines) do
		local line = raw:gsub("%s*%(BuildId:%s*%x+%)", "")

		-- _GLIBCXX_DEBUG prints the full template signature of the offending
		-- method; the headline already says what went wrong.
		if skipping_signature then
			if line:match("%S") then
				goto continue
			end
			skipping_signature = false
		elseif line:match("^%s*In function:%s*$") then
			skipping_signature = true
			goto continue
		end

		local stop = false
		for _, pat in ipairs(STOP) do
			if line:find(pat) then
				stop = true
				break
			end
		end
		if stop then
			break
		end

		if is_noise(line) then
			-- skip
		elseif is_frame(line) then
			local user_frame = basename and basename ~= "" and line:find(basename, 1, true) ~= nil
			if user_frame then
				flush_frames()
				out[#out + 1] = line
			else
				pending = pending + 1
				single = (pending == 1) and line or nil
			end
		else
			flush_frames()
			out[#out + 1] = line
		end

		::continue::
	end
	flush_frames()

	-- Collapse the blank runs left behind by removed lines.
	local squashed = {}
	for _, line in ipairs(out) do
		if line:match("%S") or (#squashed > 0 and squashed[#squashed]:match("%S")) then
			squashed[#squashed + 1] = line
		end
	end
	return squashed
end

----------------------------------------------------------------------
-- One-line diagnosis of a failed run
----------------------------------------------------------------------

local function first_user_frame(lines, basename)
	if not basename or basename == "" then
		return nil
	end
	local pat = vim.pesc(basename) .. ":(%d+)"
	for _, line in ipairs(lines) do
		local lnum = line:match(pat)
		if lnum then
			return string.format("%s:%s", basename, lnum)
		end
		-- Java stack frames: `at Main.solve(Main.java:23)`
		local jfile, jline = line:match("%(([%w_%$%.]+%.java):(%d+)%)")
		if jfile == basename then
			return string.format("%s:%s", jfile, jline)
		end
	end
	return nil
end

--- Condense a crash report into a single precise headline.
---@return string|nil headline, string|nil location
function M.diagnose(lines, basename)
	local joined = table.concat(lines, "\n")
	local headline

	local asan, access, size = nil, nil, nil
	asan = joined:match("ERROR: AddressSanitizer: ([%w%-_]+)")
	if asan then
		access, size = joined:match("(%u+) of size (%d+)")
		if access then
			headline = string.format("%s — %s of size %s", asan:gsub("%-", " "), access, size)
		else
			headline = (asan:gsub("%-", " "))
		end
	end

	if not headline then
		local ub = joined:match("runtime error: ([^\n]+)")
		if ub then
			headline = "undefined behaviour — " .. ub
		end
	end

	if not headline then
		local leak = joined:match("ERROR: LeakSanitizer: ([^\n]+)")
		if leak then
			headline = "memory leak — " .. leak
		end
	end

	if not headline then
		local what = joined:match("terminate called after throwing an instance of '([^']+)'")
		if what then
			local msg = joined:match("what%(%):%s*([^\n]+)")
			headline = "uncaught exception " .. what .. (msg and (" — " .. msg) or "")
		end
	end

	if not headline then
		-- _GLIBCXX_DEBUG wraps its message over several lines; rejoin it.
		for i, line in ipairs(lines) do
			local msg = line:match("^%s*Error:%s*(.+)$")
			if msg then
				local parts = { vim.trim(msg) }
				for j = i + 1, #lines do
					if not lines[j]:match("%S") or parts[#parts]:match("%.%s*$") then
						break
					end
					parts[#parts + 1] = vim.trim(lines[j])
				end
				headline = table.concat(parts, " ")
				break
			end
		end
	end

	if not headline then
		-- Python: last `SomeError: message` line wins.
		for i = #lines, 1, -1 do
			local err, msg = lines[i]:match("^(%u[%w_%.]*Error):%s*(.*)$")
			if not err then
				err, msg = lines[i]:match("^([%w_%.]*Exception):%s*(.*)$")
			end
			if err then
				headline = err .. (msg ~= "" and (" — " .. msg) or "")
				break
			end
		end
	end

	if not headline then
		-- Java: `Exception in thread "main" java.lang.Foo: message`
		local exc, msg = joined:match("Exception in thread \"[^\"]*\" ([%w_%.$]+)[:%s]*([^\n]*)")
		if exc then
			headline = exc:gsub("^java%.lang%.", "") .. (msg ~= "" and (" — " .. msg) or "")
		end
	end

	if not headline then
		local assertion = joined:match("([^\n]*[Aa]ssertion[^\n]*failed[^\n]*)")
		if assertion then
			headline = vim.trim(assertion)
		end
	end

	if not headline then
		return nil, nil
	end

	headline = vim.trim(headline:gsub("%s+", " "))
	if #headline > 160 then
		headline = headline:sub(1, 159) .. "…"
	end
	return headline, first_user_frame(lines, basename)
end

return M
