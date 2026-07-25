-- Compile / run orchestration.
--
-- Every run gets a sequence number; callbacks from a superseded or cancelled
-- job are ignored, so a slow program can never write into the output of the
-- run that replaced it.
local config = require("testcasevim.config")
local diagnostics = require("testcasevim.diagnostics")
local lang = require("testcasevim.lang")
local ui = require("testcasevim.ui")
local util = require("testcasevim.util")

local M = {}

local uv = vim.uv or vim.loop

local seq = 0
local jobs = { compile = nil, run = nil }
local timeout_timer = nil

----------------------------------------------------------------------
-- Job / timer bookkeeping
----------------------------------------------------------------------

local function clear_timeout()
	if timeout_timer then
		timeout_timer:stop()
		if not timeout_timer:is_closing() then
			timeout_timer:close()
		end
		timeout_timer = nil
	end
end

local function kill(kind)
	local id = jobs[kind]
	jobs[kind] = nil
	if id and id > 0 then
		pcall(vim.fn.jobstop, id)
	end
end

--- Cancel everything in flight. Safe to call when nothing is running.
function M.stop_all()
	seq = seq + 1
	clear_timeout()
	kill("compile")
	kill("run")
end

function M.is_busy()
	return jobs.compile ~= nil or jobs.run ~= nil
end

--- Cancel the current run and report it in the output pane.
function M.stop()
	if not M.is_busy() then
		return false
	end
	local out = ui.state.out
	M.stop_all()
	if out then
		out.status.stopped = true
	end
	ui.state.phase = "done"
	ui.stop_spinner()
	ui.render(true)
	return true
end

----------------------------------------------------------------------
-- Paths
----------------------------------------------------------------------

local function cache_root()
	return vim.fn.stdpath("cache") .. "/testcasevim"
end

local function build_vars(file, lang_key)
	local stem = vim.fn.fnamemodify(file, ":t:r")
	local dir = vim.fn.fnamemodify(file, ":h")
	local id = util.hash(file)
	local vars = {
		src = file,
		dir = dir,
		stem = stem,
		exe = "",
		outdir = "",
		class = stem,
	}

	if lang_key == "java" then
		vars.outdir = string.format("%s/classes/%s", cache_root(), id)
		if not util.ensure_dir(vars.outdir) then
			return nil, "could not create build directory: " .. vars.outdir
		end
	else
		local bin_dir = cache_root() .. "/bin"
		if not util.ensure_dir(bin_dir) then
			return nil, "could not create build directory: " .. bin_dir
		end
		local suffix = vim.fn.has("win32") == 1 and ".exe" or ""
		vars.exe = string.format("%s/%s-%s%s", bin_dir, util.slugify(stem), id, suffix)
		vars.outdir = bin_dir
	end

	return vars, nil
end

----------------------------------------------------------------------
-- Output collection
----------------------------------------------------------------------

local function push_stdout(out, lines)
	local limit = config.get().max_output_lines
	local bucket = out.stdout
	for _, line in ipairs(lines) do
		if #bucket.lines >= limit then
			bucket.truncated = true
			return
		end
		bucket.lines[#bucket.lines + 1] = util.strip_ansi(line)
	end
end

local function push_debug(out, line)
	local limit = config.get().max_output_lines
	local bucket = out.debug
	bucket.count = bucket.count + 1
	if #bucket.entries >= limit then
		bucket.truncated = true
		return
	end
	if config.get().pretty_debug then
		local trace = diagnostics.parse_trace(line)
		if trace then
			bucket.entries[#bucket.entries + 1] = trace
			return
		end
	end
	bucket.entries[#bucket.entries + 1] = { raw = line }
end

local function push_runtime(out, line, dirs)
	local limit = config.get().max_output_lines
	local bucket = out.runtime
	if #bucket.lines >= limit then
		bucket.truncated = true
		return
	end
	-- Sanitizer reports prefix every line with the pid; it adds nothing here.
	line = line:gsub("^==%d+==%s?", "")
	bucket.lines[#bucket.lines + 1] = util.shorten_paths(line, dirs)
end

----------------------------------------------------------------------
-- Run step
----------------------------------------------------------------------

local function finish(ctx, out)
	local rt = out.runtime
	rt.lines = diagnostics.condense(rt.lines, ctx.basename)
	util.trim_trailing_blank(rt.lines)
	util.trim_trailing_blank(out.stdout.lines)

	if #rt.lines > 0 then
		local headline, location = diagnostics.diagnose(rt.lines, ctx.basename)
		rt.headline = headline
		rt.location = location
		if location then
			local lnum = location:match(":(%d+)$")
			rt.jump = { file = ctx.file, lnum = tonumber(lnum) }
		end
	end

	-- A crash with no report at all still deserves an explanation.
	if not rt.headline and out.status.exit_code and out.status.exit_code ~= 0 then
		local signal, meaning = util.describe_exit(out.status.exit_code)
		if signal then
			rt.headline = string.format("%s — %s", signal, meaning)
			if #rt.lines == 0 then
				rt.lines = { string.format("The program was terminated by %s.", signal) }
			end
		end
	end

	ui.state.phase = "done"
	ui.stop_spinner()
	ui.render(true)
end

local function start_run(ctx, my_seq, out)
	local spec = ctx.spec
	local cmd, err = lang.build_command(spec.run, ctx.mode, ctx.vars)
	if err or not cmd then
		out.status.error = err or "no run command configured for " .. spec.name
		ui.state.phase = "done"
		ui.stop_spinner()
		ui.render(true)
		return
	end

	local stdout_stream = util.new_stream()
	local stderr_stream = util.new_stream()
	local in_failure = false
	local started = util.now()
	local settled = false -- guards against on_exit and the timeout both finishing

	local function handle_stderr(lines)
		for _, raw in ipairs(lines) do
			local line = util.strip_ansi(raw)
			if in_failure then
				push_runtime(out, line, ctx.short_dirs)
			elseif diagnostics.is_failure_line(line) then
				in_failure = true
				push_runtime(out, line, ctx.short_dirs)
			elseif line:match("%S") then
				push_debug(out, line)
			end
		end
	end

	local opts = {
		cwd = vim.fn.isdirectory(ctx.vars.dir) == 1 and ctx.vars.dir or nil,
		stdin = "pipe",
		on_stdout = function(_, data)
			if my_seq ~= seq then
				return
			end
			push_stdout(out, util.stream_feed(stdout_stream, data))
			ui.render()
		end,
		on_stderr = function(_, data)
			if my_seq ~= seq then
				return
			end
			handle_stderr(util.stream_feed(stderr_stream, data))
			ui.render()
		end,
		on_exit = function(_, code)
			if my_seq ~= seq or settled then
				return
			end
			settled = true
			jobs.run = nil
			clear_timeout()
			push_stdout(out, util.stream_flush(stdout_stream))
			handle_stderr(util.stream_flush(stderr_stream))
			out.status.run_ms = util.elapsed_ms(started)
			out.status.exit_code = code
			finish(ctx, out)
		end,
	}

	local env = lang.env(spec, ctx.mode)
	if env and next(env) then
		opts.env = env
	end

	ui.state.phase = "running"
	ui.render(true)

	local ok, job = pcall(vim.fn.jobstart, cmd, opts)
	if not ok or type(job) ~= "number" or job <= 0 then
		out.status.error = string.format(
			"could not start the program (%s)",
			type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)
		)
		ui.state.phase = "done"
		ui.stop_spinner()
		ui.render(true)
		return
	end
	jobs.run = job

	-- Feed the test case, then close stdin so blocking reads return EOF.
	local input = ctx.input or ""
	if input ~= "" and not input:match("\n$") then
		input = input .. "\n"
	end
	if input ~= "" then
		pcall(vim.fn.chansend, job, input)
	end
	pcall(vim.fn.chanclose, job, "stdin")

	local limit = config.get().timeout_ms
	if limit and limit > 0 then
		clear_timeout()
		timeout_timer = uv.new_timer()
		timeout_timer:start(
			limit,
			0,
			vim.schedule_wrap(function()
				if my_seq ~= seq or settled or jobs.run == nil then
					return
				end
				settled = true
				out.status.timed_out = true
				kill("run")
				clear_timeout()
				push_stdout(out, util.stream_flush(stdout_stream))
				handle_stderr(util.stream_flush(stderr_stream))
				out.status.run_ms = util.elapsed_ms(started)
				finish(ctx, out)
			end)
		)
	end
end

----------------------------------------------------------------------
-- Compile step
----------------------------------------------------------------------

local function start_compile(ctx, my_seq, out, cmd)
	local collected = {}
	local stdout_stream = util.new_stream()
	local stderr_stream = util.new_stream()
	local started = util.now()

	local function collect(stream, data)
		for _, raw in ipairs(util.stream_feed(stream, data)) do
			collected[#collected + 1] = util.shorten_paths(util.strip_ansi(raw), ctx.short_dirs)
		end
	end

	ui.state.phase = "compiling"
	ui.render(true)

	local ok, job = pcall(vim.fn.jobstart, cmd, {
		cwd = vim.fn.isdirectory(ctx.vars.dir) == 1 and ctx.vars.dir or nil,
		stdin = "null",
		on_stdout = function(_, data)
			if my_seq == seq then
				collect(stdout_stream, data)
			end
		end,
		on_stderr = function(_, data)
			if my_seq == seq then
				collect(stderr_stream, data)
			end
		end,
		on_exit = function(_, code)
			if my_seq ~= seq then
				return
			end
			jobs.compile = nil
			for _, rest in ipairs(util.stream_flush(stdout_stream)) do
				collected[#collected + 1] = util.shorten_paths(util.strip_ansi(rest), ctx.short_dirs)
			end
			for _, rest in ipairs(util.stream_flush(stderr_stream)) do
				collected[#collected + 1] = util.shorten_paths(util.strip_ansi(rest), ctx.short_dirs)
			end

			local diags, counts, extra = diagnostics.parse_compiler(collected)
			out.compile.diags = diags
			out.compile.counts = counts
			out.compile.extra = util.trim_trailing_blank(extra)
			out.compile.failed = code ~= 0
			out.compile.ran = true
			out.status.compile_ms = util.elapsed_ms(started)

			if code ~= 0 then
				-- A compiler can fail without emitting a parsable diagnostic.
				if #diags == 0 and #out.compile.extra == 0 then
					out.compile.extra = { string.format("The compiler exited with code %d.", code) }
				end
				ui.state.phase = "done"
				ui.stop_spinner()
				ui.render(true)
				return
			end

			start_run(ctx, my_seq, out)
		end,
	})

	if not ok or type(job) ~= "number" or job <= 0 then
		out.status.error = string.format(
			"could not start the compiler (%s)",
			type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)
		)
		ui.state.phase = "done"
		ui.stop_spinner()
		ui.render(true)
		return
	end
	jobs.compile = job
end

----------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------

--- Compile (when the language needs it) and run `ctx.file` with `ctx.input`.
---@param ctx table { file, basename, lang_key, spec, mode, input, source_lines }
function M.execute(ctx)
	M.stop_all()
	seq = seq + 1
	local my_seq = seq

	local out = ui.new_output()
	ui.state.out = out
	ui.state.follow = true
	ui.state.phase = "compiling"

	local vars, err = build_vars(ctx.file, ctx.lang_key)
	if not vars then
		out.status.error = err
		ui.state.phase = "done"
		ui.render(true)
		return
	end
	if ctx.lang_key == "java" then
		vars.class = lang.java_class(ctx.file, ctx.source_lines)
	end
	ctx.vars = vars
	-- Paths worth hiding from diagnostics: they add width, never meaning.
	ctx.short_dirs = { vars.dir, vars.outdir, cache_root() .. "/bin", cache_root() }

	ui.start_spinner()

	local cmd, cmd_err = lang.build_command(ctx.spec.compile, ctx.mode, vars)
	if cmd_err then
		out.status.error = cmd_err
		ui.state.phase = "done"
		ui.stop_spinner()
		ui.render(true)
		return
	end

	if cmd then
		start_compile(ctx, my_seq, out, cmd)
	else
		start_run(ctx, my_seq, out)
	end
end

return M
