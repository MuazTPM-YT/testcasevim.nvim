-- Floating windows, rendering and highlights.
local config = require("testcasevim.config")
local diagnostics = require("testcasevim.diagnostics")
local util = require("testcasevim.util")

local M = {}

local uv = vim.uv or vim.loop

local NS = vim.api.nvim_create_namespace("testcasevim")
local AUGROUP = "TestcaseVim"

-- Window decorations available on this Neovim. Exposed on the module so the
-- older-Neovim fallback path stays reachable in tests.
M.caps = {
	title = vim.fn.has("nvim-0.9") == 1,
	footer = vim.fn.has("nvim-0.10") == 1,
}

--- The single live session. `nil` fields mean "not open".
M.state = {
	open = false,
	file = nil,
	basename = nil,
	lang_key = nil,
	spec = nil,
	input_buf = nil,
	input_win = nil,
	output_buf = nil,
	output_win = nil,
	seq = 0,
	phase = "idle", -- idle | compiling | running | done
	spinner_index = 1,
	spinner_timer = nil,
	render_timer = nil,
	render_pending = false,
	jumps = {},
	out = nil,
	follow = true,
	last_line_count = 0,
}

----------------------------------------------------------------------
-- Highlights
----------------------------------------------------------------------

local function link(name, targets)
	for _, target in ipairs(targets) do
		if vim.fn.hlexists(target) == 1 then
			vim.api.nvim_set_hl(0, name, { link = target, default = true })
			return
		end
	end
	vim.api.nvim_set_hl(0, name, { default = true })
end

function M.setup_highlights()
	link("TestcaseVimTitle", { "Title" })
	link("TestcaseVimSection", { "Function", "Identifier" })
	link("TestcaseVimDim", { "Comment" })
	link("TestcaseVimOk", { "DiagnosticOk", "String" })
	link("TestcaseVimError", { "DiagnosticError", "ErrorMsg" })
	link("TestcaseVimWarn", { "DiagnosticWarn", "WarningMsg" })
	link("TestcaseVimInfo", { "DiagnosticInfo", "Directory" })
	link("TestcaseVimHint", { "DiagnosticHint", "Special" })
	link("TestcaseVimLoc", { "DiagnosticHint", "Special" })
	link("TestcaseVimExpr", { "Identifier", "Normal" })
	link("TestcaseVimValue", { "String", "Constant" })
	link("TestcaseVimKey", { "Special", "Statement" })
end

----------------------------------------------------------------------
-- Output model
----------------------------------------------------------------------

--- Fresh, empty result model.
function M.new_output()
	return {
		compile = { diags = {}, counts = {}, extra = {}, failed = false, ran = false },
		stdout = { lines = {}, truncated = false },
		debug = { entries = {}, count = 0, truncated = false },
		runtime = { lines = {}, headline = nil, location = nil, truncated = false },
		status = {
			exit_code = nil,
			compile_ms = nil,
			run_ms = nil,
			timed_out = false,
			stopped = false,
			error = nil,
		},
	}
end

----------------------------------------------------------------------
-- Canvas: lines + extmarks built together
----------------------------------------------------------------------

local Canvas = {}
Canvas.__index = Canvas

local function canvas()
	return setmetatable({ lines = {}, marks = {}, jumps = {} }, Canvas)
end

function Canvas:add(text, hl)
	self.lines[#self.lines + 1] = text or ""
	local row = #self.lines - 1
	if hl then
		self.marks[#self.marks + 1] = { row = row, line = true, hl = hl }
	end
	return row
end

function Canvas:blank()
	if #self.lines > 0 and self.lines[#self.lines] ~= "" then
		self:add("")
	end
end

function Canvas:mark(row, col, end_col, hl)
	if hl and col and end_col and end_col > col then
		self.marks[#self.marks + 1] = { row = row, col = col, end_col = end_col, hl = hl }
	end
end

--- Section banner: `▌ LABEL · detail`
function Canvas:section(label, detail, hl)
	local icons = config.get().icons
	self:blank()
	local head = string.format("%s %s", icons.bar, label)
	local text = head
	if detail and detail ~= "" then
		text = text .. "  " .. detail
	end
	local row = self:add(text)
	self:mark(row, 0, #head, hl or "TestcaseVimSection")
	if detail and detail ~= "" then
		self:mark(row, #head, #text, "TestcaseVimDim")
	end
	self:add("")
	return row
end

----------------------------------------------------------------------
-- Renderers for each section
----------------------------------------------------------------------

local INDENT = "  "

local function render_hint(c)
	local icons = config.get().icons
	c:section("READY", nil, "TestcaseVimInfo")
	c:add(INDENT .. "Type or paste your test input in the left pane,", "TestcaseVimDim")
	c:add(INDENT .. "then press <CR> in normal mode to compile & run.", "TestcaseVimDim")
	c:add("")
	local keys = {
		{ "<CR>", "compile & run" },
		{ "<Tab>", "switch pane" },
		{ "<C-c>", "stop running program" },
		{ "<leader><CR>", "close (toggle)" },
	}
	for _, item in ipairs(keys) do
		local key = string.format("%s%-14s", INDENT, item[1])
		local text = key .. icons.arrow .. " " .. item[2]
		local row = c:add(text)
		c:mark(row, #INDENT, #INDENT + #item[1], "TestcaseVimKey")
		c:mark(row, #key, #text, "TestcaseVimDim")
	end
end

local SEVERITY_HL = {
	error = "TestcaseVimError",
	warning = "TestcaseVimWarn",
	note = "TestcaseVimDim",
}

local function render_compile(c, out)
	local compile = out.compile
	if #compile.diags == 0 and #compile.extra == 0 then
		return
	end
	local icons = config.get().icons
	local failed = compile.failed
	local label = failed and "COMPILE ERROR" or "COMPILER WARNINGS"
	local detail = diagnostics.summarize_counts(compile.counts)
	local section_row = c:section(label, detail, failed and "TestcaseVimError" or "TestcaseVimWarn")
	if failed then
		c.focus = c.focus or section_row
	end

	for _, diag in ipairs(compile.diags) do
		local hl = SEVERITY_HL[diag.severity] or "TestcaseVimDim"
		local icon = diag.severity == "error" and icons.error
			or diag.severity == "warning" and icons.warn
			or icons.info
		local loc = string.format("%s:%d", vim.fn.fnamemodify(diag.file, ":t"), diag.lnum or 0)
		if diag.col then
			loc = loc .. ":" .. diag.col
		end
		local head = string.format("%s%s %s", INDENT, icon, loc)
		local row = c:add(head)
		c:mark(row, #INDENT, #INDENT + #icon, hl)
		c:mark(row, #INDENT + #icon + 1, #head, "TestcaseVimLoc")
		c.jumps[row] = { file = diag.file, lnum = diag.lnum, col = diag.col }

		if diag.message ~= "" then
			local msg_row = c:add(INDENT .. INDENT .. diag.message)
			c:mark(msg_row, 0, #(INDENT .. INDENT .. diag.message), hl)
			c.jumps[msg_row] = c.jumps[row]
		end
		for _, ctx in ipairs(diag.context) do
			local ctx_row = c:add(INDENT .. INDENT .. ctx, "TestcaseVimDim")
			c.jumps[ctx_row] = c.jumps[row]
		end
		c:add("")
	end

	for _, line in ipairs(compile.extra) do
		c:add(INDENT .. line, "TestcaseVimDim")
	end
end

local function render_stdout(c, out)
	local stdout = out.stdout
	if #stdout.lines == 0 then
		return
	end
	local n = #stdout.lines
	c:section("OUTPUT", string.format("%d %s", n, n == 1 and "line" or "lines"), "TestcaseVimOk")
	for _, line in ipairs(stdout.lines) do
		c:add(line == "" and "" or (INDENT .. line))
	end
	if stdout.truncated then
		c:add("")
		c:add(INDENT .. "… output truncated at " .. config.get().max_output_lines .. " lines", "TestcaseVimWarn")
	end
end

local function render_debug(c, out)
	local dbg = out.debug
	if #dbg.entries == 0 then
		return
	end
	local icons = config.get().icons
	local n = dbg.count
	c:section("DEBUG", string.format("%d %s", n, n == 1 and "trace" or "traces"), "TestcaseVimHint")

	-- Align the `func:line` column across the whole block.
	local loc_width, expr_width = 0, 0
	for _, entry in ipairs(dbg.entries) do
		if entry.location then
			loc_width = math.max(loc_width, vim.fn.strdisplaywidth(entry.location))
			expr_width = math.max(expr_width, vim.fn.strdisplaywidth(entry.expr or ""))
		end
	end
	expr_width = math.min(expr_width, 28)

	for _, entry in ipairs(dbg.entries) do
		if entry.raw then
			c:add(INDENT .. entry.raw)
		else
			local loc = entry.location or ""
			local loc_pad = string.rep(" ", math.max(0, loc_width - vim.fn.strdisplaywidth(loc)))
			local expr = entry.expr or ""
			local expr_pad = string.rep(" ", math.max(0, expr_width - vim.fn.strdisplaywidth(expr)))
			local prefix = string.format("%s%s %s%s  ", INDENT, icons.debug, loc, loc_pad)
			local text = prefix .. expr .. expr_pad .. "  =  " .. (entry.value or "")
			local row = c:add(text)
			c:mark(row, #INDENT, #INDENT + #icons.debug + 1 + #loc, "TestcaseVimLoc")
			c:mark(row, #prefix, #prefix + #expr, "TestcaseVimExpr")
			c:mark(row, #prefix + #expr + #expr_pad, #prefix + #expr + #expr_pad + 5, "TestcaseVimDim")
			c:mark(row, #prefix + #expr + #expr_pad + 5, #text, "TestcaseVimValue")
			if entry.file and entry.lnum then
				c.jumps[row] = { file = entry.file, lnum = entry.lnum }
			end
		end
	end
	if dbg.truncated then
		c:add("")
		c:add(INDENT .. "… debug output truncated", "TestcaseVimWarn")
	end
end

local function render_runtime(c, out)
	local rt = out.runtime
	if #rt.lines == 0 then
		return
	end
	local icons = config.get().icons
	c.focus = c.focus or c:section("RUNTIME ERROR", nil, "TestcaseVimError")

	if rt.headline then
		local head = string.format("%s%s %s", INDENT, icons.error, rt.headline)
		if rt.location then
			head = head .. " · at " .. rt.location
		end
		local row = c:add(head)
		c:mark(row, 0, #head, "TestcaseVimError")
		if rt.jump then
			c.jumps[row] = rt.jump
		end
		c:add("")
	end

	local basename = M.state.basename
	for _, line in ipairs(rt.lines) do
		local hl = "TestcaseVimDim"
		if basename and line:find(basename, 1, true) then
			hl = "TestcaseVimWarn"
		elseif line:find("ERROR:") or line:find("runtime error:") or line:find("^SUMMARY:") then
			hl = "TestcaseVimError"
		elseif not line:match("^%s*#%d+") and not line:match("^%s*at ") and not line:match("^%s*File \"") then
			hl = nil
		end
		c:add(line == "" and "" or (INDENT .. line), hl)
	end
	if rt.truncated then
		c:add("")
		c:add(INDENT .. "… error output truncated", "TestcaseVimWarn")
	end
end

local function render_empty_result(c, out)
	local status = out.status
	if status.error then
		c.focus = c.focus or c:section("CANNOT RUN", nil, "TestcaseVimError")
		for _, line in ipairs(vim.split(status.error, "\n", { plain = true })) do
			c:add(INDENT .. line, "TestcaseVimError")
		end
		return true
	end
	local nothing = #out.stdout.lines == 0
		and #out.debug.entries == 0
		and #out.runtime.lines == 0
		and #out.compile.diags == 0
		and #out.compile.extra == 0
	if nothing and M.state.phase == "done" and not status.timed_out and not status.stopped then
		local icons = config.get().icons
		c:section("NO OUTPUT", nil, "TestcaseVimDim")
		c:add(INDENT .. icons.ok .. " The program finished without writing anything.", "TestcaseVimDim")
		return true
	end
	return false
end

local function render_notices(c, out)
	local icons = config.get().icons
	local status = out.status
	if status.timed_out then
		c.focus = c.focus or c:section("TIME LIMIT", nil, "TestcaseVimError")
		c:add(
			string.format(
				"%s%s Killed after %s — the program did not finish.",
				INDENT,
				icons.error,
				util.fmt_duration(config.get().timeout_ms)
			),
			"TestcaseVimError"
		)
		c:add(INDENT .. "Check for an infinite loop, or raise `timeout_ms`.", "TestcaseVimDim")
	elseif status.stopped then
		c:section("STOPPED", nil, "TestcaseVimWarn")
		c:add(INDENT .. icons.warn .. " Run cancelled.", "TestcaseVimWarn")
	end
end

----------------------------------------------------------------------
-- Status line (window footer, or a buffer line on older Neovim)
----------------------------------------------------------------------

local function truncate(text, width)
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

--- Status shown in the output pane's footer.
--- Returns Neovim chunk pairs, dropping optional detail (timings first) until
--- the text fits inside the border.
local function status_chunks(max_width)
	local state = M.state
	local out = state.out
	local icons = config.get().icons
	local parts = {}

	local function push(text, hl, optional)
		parts[#parts + 1] = { text = text, hl = hl, optional = optional }
	end

	local function finish()
		if max_width and max_width > 0 then
			local function width()
				local w = 0
				for _, part in ipairs(parts) do
					w = w + vim.fn.strdisplaywidth(part.text)
				end
				return w
			end
			for i = #parts, 1, -1 do
				if width() <= max_width then
					break
				end
				if parts[i].optional then
					table.remove(parts, i)
				end
			end
			while width() > max_width and #parts > 1 do
				table.remove(parts, #parts)
			end
			if width() > max_width and parts[1] then
				parts[1].text = truncate(parts[1].text, max_width)
			end
		end
		local chunks = {}
		for _, part in ipairs(parts) do
			chunks[#chunks + 1] = { part.text, part.hl }
		end
		return chunks
	end

	if state.phase == "compiling" or state.phase == "running" then
		local frames = icons.spinner
		local frame = frames[((state.spinner_index - 1) % #frames) + 1]
		push(" " .. frame .. " ", "TestcaseVimInfo")
		push(state.phase == "compiling" and "compiling" or "running", "TestcaseVimDim")
		if state.phase == "running" and out and out.status.compile_ms then
			push(" · compiled in " .. util.fmt_duration(out.status.compile_ms), "TestcaseVimDim", true)
		end
		push(" ", "TestcaseVimDim")
		return finish()
	end

	if not out or state.phase == "idle" then
		push(" press ", "TestcaseVimDim")
		push("<CR>", "TestcaseVimKey")
		push(" to run ", "TestcaseVimDim")
		return finish()
	end

	local status = out.status
	if status.error then
		push(" " .. icons.error .. " unavailable ", "TestcaseVimError")
		return finish()
	end
	if out.compile.failed then
		local detail = diagnostics.summarize_counts(out.compile.counts)
		push(" " .. icons.error .. " compile failed ", "TestcaseVimError")
		if detail ~= "" then
			push("· " .. detail .. " ", "TestcaseVimDim", true)
		end
		return finish()
	end
	if status.stopped then
		push(" " .. icons.warn .. " stopped ", "TestcaseVimWarn")
		return finish()
	end
	if status.timed_out then
		push(" " .. icons.error .. " timeout ", "TestcaseVimError")
		push("· killed after " .. util.fmt_duration(config.get().timeout_ms) .. " ", "TestcaseVimDim", true)
		return finish()
	end

	local code = status.exit_code or 0
	if code == 0 then
		push(" " .. icons.ok .. " exit 0", "TestcaseVimOk")
	else
		local signal, meaning = util.describe_exit(code)
		local text = string.format(" %s exit %d", icons.error, code)
		if signal then
			text = text .. " (" .. signal .. ")"
		elseif meaning and code ~= 1 then
			text = text .. " (" .. meaning .. ")"
		end
		push(text, "TestcaseVimError")
	end

	local timings = {}
	if status.compile_ms then
		timings[#timings + 1] = "compile " .. util.fmt_duration(status.compile_ms)
	end
	if status.run_ms then
		timings[#timings + 1] = "run " .. util.fmt_duration(status.run_ms)
	end
	if #timings > 0 then
		push(" · " .. table.concat(timings, " · "), "TestcaseVimDim", true)
	end
	push(" ", "TestcaseVimDim")
	return finish()
end

local function chunks_to_string(chunks)
	local parts = {}
	for _, chunk in ipairs(chunks) do
		parts[#parts + 1] = chunk[1]
	end
	return table.concat(parts)
end

----------------------------------------------------------------------
-- Window management
----------------------------------------------------------------------

--- Geometry for both panes. `width`/`height` are fractions of the editor and
--- include the borders, and everything is clamped so the panes always fit —
--- even in a very small terminal.
local function layout()
	local opts = config.get()
	local chrome = opts.border == "none" and 0 or 2 -- columns/rows taken by a border
	local editor_width = vim.o.columns
	local editor_height = math.max(6, vim.o.lines - vim.o.cmdheight - 1)
	local gap = math.max(0, opts.gap)

	local pane_width = math.floor((editor_width * opts.width - gap) / 2) - chrome
	pane_width = math.max(8, math.min(pane_width, math.floor((editor_width - gap - chrome * 2) / 2)))

	local pane_height = math.floor(editor_height * opts.height) - chrome
	pane_height = math.max(3, math.min(pane_height, editor_height - chrome))

	local total = (pane_width + chrome) * 2 + gap
	local row = math.max(0, math.floor((editor_height - pane_height - chrome) / 2)) + chrome / 2
	local left = math.max(0, math.floor((editor_width - total) / 2)) + chrome / 2

	return {
		width = pane_width,
		height = pane_height,
		row = row,
		left = left,
		right = left + pane_width + chrome + gap,
	}
end

local function input_title()
	local state = M.state
	local name = state.basename or "input"
	return { { " Input ", "TestcaseVimTitle" }, { "· " .. truncate(name, 30) .. " ", "TestcaseVimDim" } }
end

local function output_title()
	local state = M.state
	local opts = config.get()
	local mode = opts.mode
	local lang = state.spec and state.spec.name or "?"
	return {
		{ " Output ", "TestcaseVimTitle" },
		{ "· " .. lang .. " ", "TestcaseVimDim" },
		{ "· " .. mode:upper() .. " ", mode == "debug" and "TestcaseVimWarn" or "TestcaseVimOk" },
	}
end

local function win_valid(win)
	return win and vim.api.nvim_win_is_valid(win)
end

local function buf_valid(buf)
	return buf and vim.api.nvim_buf_is_valid(buf)
end

M.win_valid = win_valid

local function create_window(buf, title, geom, side)
	local opts = config.get()
	local win_opts = {
		relative = "editor",
		width = geom.width,
		height = geom.height,
		row = geom.row,
		col = side == "left" and geom.left or geom.right,
		style = "minimal",
		border = opts.border,
		zindex = 50,
	}
	if M.caps.title then
		win_opts.title = title
		win_opts.title_pos = "center"
	end
	local win = vim.api.nvim_open_win(buf, false, win_opts)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].breakindent = true
	vim.wo[win].cursorline = true
	vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder,CursorLine:CursorLine"
	-- Keep `:edit`, pickers and jump-lists from hijacking a pane (0.10+).
	pcall(function()
		vim.wo[win].winfixbuf = true
	end)
	return win
end

--- Patch a float's config while preserving the fields we do not touch.
--- Passing a partial table to `nvim_win_set_config` is not reliable across
--- Neovim versions, so the current config is read back and merged.
function M.update_win_config(win, patch)
	if not win_valid(win) then
		return
	end
	local ok, current = pcall(vim.api.nvim_win_get_config, win)
	if not ok or type(current) ~= "table" or current.relative == "" then
		return
	end
	current.win = nil
	for key, value in pairs(patch) do
		current[key] = value
	end
	pcall(vim.api.nvim_win_set_config, win, current)
end

--- Refresh titles / footers without rebuilding the buffer.
function M.refresh_chrome()
	local state = M.state
	if not state.open then
		return
	end
	if win_valid(state.input_win) and M.caps.title then
		M.update_win_config(state.input_win, { title = input_title(), title_pos = "center" })
	end
	if win_valid(state.output_win) then
		local cfg = {}
		if M.caps.title then
			cfg.title = output_title()
			cfg.title_pos = "center"
		end
		if M.caps.footer then
			-- Leave room for the rounded corners on both sides.
			cfg.footer = status_chunks(vim.api.nvim_win_get_width(state.output_win) - 4)
			cfg.footer_pos = "center"
		end
		if next(cfg) then
			M.update_win_config(state.output_win, cfg)
		end
	end
end

function M.resize()
	local state = M.state
	if not state.open then
		return
	end
	local geom = layout()
	for _, item in ipairs({ { state.input_win, geom.left }, { state.output_win, geom.right } }) do
		M.update_win_config(item[1], {
			relative = "editor",
			width = geom.width,
			height = geom.height,
			row = geom.row,
			col = item[2],
		})
	end
	M.refresh_chrome()
end

----------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------

--- The output pane follows new lines until the user scrolls up, and starts
--- following again as soon as the cursor is back on the last line.
local function update_follow()
	local state = M.state
	if not state.open or not win_valid(state.output_win) or not buf_valid(state.output_buf) then
		return
	end
	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, state.output_win)
	if not ok then
		return
	end
	state.follow = cursor[1] >= vim.api.nvim_buf_line_count(state.output_buf)
end

local function render_now()
	local state = M.state
	state.render_pending = false
	if not state.open or not buf_valid(state.output_buf) then
		return
	end

	local c = canvas()
	local out = state.out

	if not out then
		render_hint(c)
	else
		local handled = render_empty_result(c, out)
		render_compile(c, out)
		if not out.compile.failed then
			render_stdout(c, out)
			render_debug(c, out)
			render_runtime(c, out)
			render_notices(c, out)
			if
				not handled
				and state.phase ~= "done"
				and #c.lines == 0
			then
				c:section(state.phase == "compiling" and "COMPILING" or "RUNNING", nil, "TestcaseVimInfo")
				c:add(INDENT .. "waiting for output…", "TestcaseVimDim")
			end
		end
		if #c.lines == 0 then
			render_hint(c)
		end
	end

	if not M.caps.footer then
		c:blank()
		c:add(chunks_to_string(status_chunks(nil)), "TestcaseVimDim")
	end

	util.trim_trailing_blank(c.lines)
	if #c.lines == 0 then
		c.lines = { "" }
	end

	local should_follow = config.get().auto_scroll and state.follow

	vim.bo[state.output_buf].modifiable = true
	pcall(vim.api.nvim_buf_set_lines, state.output_buf, 0, -1, false, c.lines)
	vim.bo[state.output_buf].modifiable = false
	vim.bo[state.output_buf].modified = false

	vim.api.nvim_buf_clear_namespace(state.output_buf, NS, 0, -1)
	for _, mark in ipairs(c.marks) do
		if mark.row < #c.lines then
			local line = c.lines[mark.row + 1]
			if mark.line then
				pcall(vim.api.nvim_buf_set_extmark, state.output_buf, NS, mark.row, 0, { line_hl_group = mark.hl })
			else
				local end_col = math.min(mark.end_col, #line)
				local col = math.min(mark.col, #line)
				if end_col > col then
					pcall(vim.api.nvim_buf_set_extmark, state.output_buf, NS, mark.row, col, {
						end_col = end_col,
						hl_group = mark.hl,
					})
				end
			end
		end
	end

	state.jumps = c.jumps
	state.last_line_count = #c.lines

	-- When a run fails, put the diagnosis at the top of the view instead of
	-- scrolling past it to the end of a long report.
	local focused = false
	if state.phase == "done" and c.focus and win_valid(state.output_win) then
		local win_height = vim.api.nvim_win_get_height(state.output_win)
		local win_width = math.max(1, vim.api.nvim_win_get_width(state.output_win))
		local rows = 0
		for _, line in ipairs(c.lines) do
			rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / win_width))
		end
		if rows > win_height then
			pcall(vim.api.nvim_win_set_cursor, state.output_win, { c.focus + 1, 0 })
			pcall(vim.api.nvim_win_call, state.output_win, function()
				vim.cmd("normal! zt")
			end)
			state.follow = false
			focused = true
		end
	end

	if not focused and should_follow and win_valid(state.output_win) then
		pcall(vim.api.nvim_win_set_cursor, state.output_win, { #c.lines, 0 })
	end

	M.refresh_chrome()
end

--- Coalesce renders so a chatty program cannot stall the editor.
function M.render(immediate)
	local state = M.state
	if not state.open then
		return
	end
	if immediate then
		-- Job callbacks and mappings already run on the main loop, so redraw
		-- straight away; only defer when the API is off-limits.
		if vim.in_fast_event() then
			vim.schedule(render_now)
		else
			render_now()
		end
		return
	end
	if state.render_pending then
		return
	end
	state.render_pending = true
	if state.render_timer then
		state.render_timer:stop()
	else
		state.render_timer = uv.new_timer()
	end
	state.render_timer:start(40, 0, function()
		vim.schedule(render_now)
	end)
end

----------------------------------------------------------------------
-- Spinner
----------------------------------------------------------------------

function M.start_spinner()
	local state = M.state
	if state.spinner_timer then
		return
	end
	state.spinner_timer = uv.new_timer()
	state.spinner_timer:start(
		80,
		80,
		vim.schedule_wrap(function()
			if not state.open or (state.phase ~= "compiling" and state.phase ~= "running") then
				M.stop_spinner()
				return
			end
			state.spinner_index = state.spinner_index + 1
			M.refresh_chrome()
		end)
	)
end

function M.stop_spinner()
	local state = M.state
	local timer = state.spinner_timer
	state.spinner_timer = nil
	if timer then
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
	end
end

----------------------------------------------------------------------
-- Input persistence
----------------------------------------------------------------------

local function cache_dir()
	return vim.fn.stdpath("cache") .. "/testcasevim"
end

local function input_path(file)
	local dir = cache_dir() .. "/input"
	return dir, string.format("%s/%s-%s.txt", dir, util.slugify(vim.fn.fnamemodify(file, ":t:r")), util.hash(file))
end

function M.load_input(file)
	if not config.get().persist_input then
		return nil
	end
	local _, path = input_path(file)
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if ok and type(lines) == "table" then
		return lines
	end
	return nil
end

function M.save_input(file, lines)
	if not config.get().persist_input or not file or file == "" then
		return
	end
	local dir, path = input_path(file)
	if not util.ensure_dir(dir) then
		return
	end
	pcall(vim.fn.writefile, lines, path)
end

function M.current_input()
	local state = M.state
	if not buf_valid(state.input_buf) then
		return {}
	end
	return vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
end

----------------------------------------------------------------------
-- Keymaps
----------------------------------------------------------------------

local function map(buf, mode, lhs, fn, desc)
	vim.keymap.set(mode, lhs, fn, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
		desc = "testcasevim: " .. desc,
	})
end

local function jump_to_location()
	local state = M.state
	if not win_valid(state.output_win) then
		return false
	end
	local row = vim.api.nvim_win_get_cursor(state.output_win)[1] - 1
	local target = state.jumps[row]
	if not target or not target.file then
		return false
	end
	local file = target.file
	if vim.fn.filereadable(file) ~= 1 then
		-- Compilers print paths relative to the compile cwd.
		local candidate = vim.fn.fnamemodify(state.file or "", ":h") .. "/" .. file
		if vim.fn.filereadable(candidate) == 1 then
			file = candidate
		else
			return false
		end
	end
	M.close()
	vim.cmd("edit " .. vim.fn.fnameescape(file))
	pcall(vim.api.nvim_win_set_cursor, 0, { target.lnum or 1, math.max(0, (target.col or 1) - 1) })
	vim.cmd("normal! zz")
	return true
end

local function focus_other()
	local state = M.state
	local current = vim.api.nvim_get_current_win()
	local target = current == state.input_win and state.output_win or state.input_win
	if win_valid(target) then
		vim.api.nvim_set_current_win(target)
	end
end

local function setup_keymaps()
	local state = M.state
	local run = function()
		require("testcasevim").execute()
	end

	-- Only <CR>, <Tab> and <C-c> are taken, so the panes keep the user's own
	-- normal/insert mappings. Close with the toggle mapping or `:q`.
	map(state.input_buf, "n", "<CR>", run, "compile & run")

	map(state.output_buf, "n", "<CR>", function()
		if not jump_to_location() then
			run()
		end
	end, "jump to error / re-run")

	local runner = require("testcasevim.runner")
	for _, buf in ipairs({ state.input_buf, state.output_buf }) do
		map(buf, "n", "<Tab>", focus_other, "switch pane")
		map(buf, "n", "<S-Tab>", focus_other, "switch pane")
		map(buf, { "n", "x" }, "<C-c>", function()
			require("testcasevim").stop()
		end, "stop running program")
		-- Insert mode: stop a run if there is one, else keep <C-c>'s usual meaning.
		vim.keymap.set("i", "<C-c>", function()
			if runner.is_busy() then
				vim.schedule(runner.stop) -- expr mappings run under textlock
				return ""
			end
			return "<C-c>"
		end, { buffer = buf, expr = true, silent = true, desc = "testcasevim: stop running program" })
	end
end

----------------------------------------------------------------------
-- Open / close
----------------------------------------------------------------------

local function setup_autocmds()
	local state = M.state
	local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			if M.state.open then
				M.resize()
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(args)
			local win = tonumber(args.match)
			if not M.state.open then
				return
			end
			if win == M.state.input_win or win == M.state.output_win then
				vim.schedule(M.close)
			end
		end,
	})

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			M.setup_highlights()
			if M.state.open then
				M.render(true)
			end
		end,
	})

	-- `:w` inside the input pane stores the test case instead of erroring.
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = state.input_buf,
		callback = function()
			M.save_input(M.state.file, M.current_input())
			if buf_valid(M.state.input_buf) then
				vim.bo[M.state.input_buf].modified = false
			end
		end,
	})

	-- If a pane buffer disappears some other way, tear the session down.
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = state.input_buf,
		callback = function()
			vim.schedule(M.close)
		end,
	})

	-- Tail-follow only while the cursor sits on the last line.
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		buffer = state.output_buf,
		callback = update_follow,
	})
end

--- A session only counts as open while both panes still exist *and* still
--- show our buffers; anything else is a leftover that must be torn down.
function M.is_open()
	local state = M.state
	if not state.open then
		return false
	end
	if not win_valid(state.input_win) or not win_valid(state.output_win) then
		return false
	end
	if not buf_valid(state.input_buf) or not buf_valid(state.output_buf) then
		return false
	end
	return vim.api.nvim_win_get_buf(state.input_win) == state.input_buf
		and vim.api.nvim_win_get_buf(state.output_win) == state.output_buf
end

--- Open (or re-focus) the panes for `file`.
function M.open(file, lang_key, spec)
	local state = M.state

	if M.is_open() then
		if state.file == file then
			state.spec = spec
			state.lang_key = lang_key
			M.refresh_chrome()
			if win_valid(state.input_win) then
				vim.api.nvim_set_current_win(state.input_win)
			end
			return
		end
		M.close()
	elseif state.open then
		M.close()
	end

	M.setup_highlights()

	local geom = layout()

	local input_buf = vim.api.nvim_create_buf(false, true)
	local output_buf = vim.api.nvim_create_buf(false, true)

	state.open = true
	state.file = file
	state.basename = vim.fn.fnamemodify(file, ":t")
	state.lang_key = lang_key
	state.spec = spec
	state.input_buf = input_buf
	state.output_buf = output_buf
	state.phase = "idle"
	state.out = nil
	state.jumps = {}
	state.follow = true

	for _, buf in ipairs({ input_buf, output_buf }) do
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
	end
	vim.bo[input_buf].filetype = "testcasevim-input"
	vim.bo[output_buf].filetype = "testcasevim-output"
	vim.bo[output_buf].modifiable = false
	pcall(vim.api.nvim_buf_set_name, input_buf, "testcasevim://input")
	pcall(vim.api.nvim_buf_set_name, output_buf, "testcasevim://output")

	state.input_win = create_window(input_buf, input_title(), geom, "left")
	state.output_win = create_window(output_buf, output_title(), geom, "right")

	vim.wo[state.input_win].number = config.get().number
	vim.wo[state.input_win].signcolumn = "no"
	vim.wo[state.output_win].number = false

	local saved = M.load_input(file)
	if saved and #saved > 0 then
		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, saved)
	end
	vim.bo[input_buf].modified = false

	setup_keymaps()
	setup_autocmds()

	M.render(true)

	vim.api.nvim_set_current_win(state.input_win)
	if saved and #saved > 0 then
		pcall(vim.api.nvim_win_set_cursor, state.input_win, { #saved, 0 })
	else
		vim.cmd("startinsert")
	end
end

--- Tear everything down: jobs, timers, autocmds, windows and buffers.
function M.close()
	local state = M.state
	if not state.open then
		return
	end

	require("testcasevim.runner").stop_all()

	if config.get().persist_input and state.file and buf_valid(state.input_buf) then
		M.save_input(state.file, M.current_input())
	end

	M.stop_spinner()
	if state.render_timer then
		state.render_timer:stop()
		if not state.render_timer:is_closing() then
			state.render_timer:close()
		end
		state.render_timer = nil
	end
	state.render_pending = false

	pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)

	local wins = { state.input_win, state.output_win }
	local bufs = { state.input_buf, state.output_buf }

	state.open = false
	state.input_win, state.output_win = nil, nil
	state.input_buf, state.output_buf = nil, nil
	state.phase = "idle"
	state.out = nil
	state.jumps = {}

	for _, win in ipairs(wins) do
		if win_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
	for _, buf in ipairs(bufs) do
		if buf_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
end

return M
