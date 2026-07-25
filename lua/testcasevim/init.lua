-- testcasevim.nvim — run competitive-programming test cases from Neovim.
--
--   <leader><CR>  (user mapping) open the input/output panes
--   <CR>          compile & run the current test case
--   q             close the panes
--
-- Supported: C++, C, Python and Java.
local config = require("testcasevim.config")
local lang = require("testcasevim.lang")
local ui = require("testcasevim.ui")
local util = require("testcasevim.util")

local M = {}

----------------------------------------------------------------------
-- Mode
----------------------------------------------------------------------

local function set_mode(mode, quiet)
	config.get().mode = mode
	ui.refresh_chrome()
	if not quiet then
		if mode == "debug" then
			util.notify("DEBUG mode — sanitizers on, -DDEBUG defined")
		else
			util.notify("RELEASE mode — optimised, no debug output")
		end
	end
	return mode
end

function M.set_debug()
	return set_mode("debug")
end

function M.set_release()
	return set_mode("release")
end

function M.toggle_mode()
	return set_mode(config.get().mode == "debug" and "release" or "debug")
end

function M.get_mode()
	return config.get().mode
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function is_plugin_buffer(buf)
	local state = ui.state
	return buf == state.input_buf or buf == state.output_buf
end

--- Persist the source buffer before compiling, so the run matches what is
--- on screen. Never throws: an unwritable buffer just runs from disk.
local function write_source(file)
	local buf = vim.fn.bufnr(file)
	if buf <= 0 or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if not vim.bo[buf].modified or vim.bo[buf].buftype ~= "" or not vim.bo[buf].modifiable then
		return
	end
	pcall(vim.api.nvim_buf_call, buf, function()
		vim.cmd("silent! write")
	end)
end

--- First lines of the source, used to work out the Java class name.
local function source_lines(file)
	local buf = vim.fn.bufnr(file)
	if buf > 0 and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
		return vim.api.nvim_buf_get_lines(buf, 0, 60, false)
	end
	local ok, lines = pcall(vim.fn.readfile, file, "", 60)
	return ok and lines or {}
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Open (or focus) the test-case panes for the current file.
function M.run()
	if is_plugin_buffer(vim.api.nvim_get_current_buf()) then
		if ui.win_valid(ui.state.input_win) then
			vim.api.nvim_set_current_win(ui.state.input_win)
		end
		return
	end

	local file = vim.fn.expand("%:p")
	if file == "" or vim.bo.buftype ~= "" then
		util.notify("Open a source file first.", vim.log.levels.ERROR)
		return
	end

	local key, spec = lang.detect(file, vim.bo.filetype)
	if not key then
		util.notify(
			string.format(
				"%s is not supported.\nSupported: %s",
				vim.fn.fnamemodify(file, ":t"),
				lang.supported_summary()
			),
			vim.log.levels.ERROR
		)
		return
	end

	write_source(file)
	ui.open(file, key, spec)
end

--- Compile and run the test case currently in the input pane.
function M.execute()
	local state = ui.state
	if not ui.is_open() then
		M.run()
		if not ui.is_open() then
			return
		end
		state = ui.state
	end

	local file = state.file
	local key, spec = state.lang_key, state.spec
	if not file or not spec then
		return
	end

	if vim.fn.filereadable(file) ~= 1 then
		state.out = ui.new_output()
		state.out.status.error = "the source file no longer exists:\n" .. file
		state.phase = "done"
		ui.render(true)
		return
	end

	write_source(file)

	local input_lines = ui.current_input()
	ui.save_input(file, input_lines)

	require("testcasevim.runner").execute({
		file = file,
		basename = state.basename,
		lang_key = key,
		spec = spec,
		mode = config.get().mode,
		input = table.concat(input_lines, "\n"),
		source_lines = source_lines(file),
	})
end

--- Stop a running program without closing the panes.
function M.stop()
	if not require("testcasevim.runner").stop() then
		util.notify("Nothing is running.", vim.log.levels.WARN)
	end
end

--- Close the panes (and kill anything still running).
function M.close()
	ui.close()
end

function M.is_open()
	return ui.is_open()
end

function M.setup(opts)
	config.setup(opts)
	ui.setup_highlights()
	return M
end

return M
