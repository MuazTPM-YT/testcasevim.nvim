local M = {}

local config = {
	compile_cmd = 'g++ -std=c++17 -O2 -Wall -Wextra -Wshadow -fsanitize=address,undefined -D_GLIBCXX_DEBUG "%s" -o "%s"',
	width = 0.85,
	height = 0.8,
	gap = 4,
}

local state = {
	input_buf = nil,
	output_buf = nil,
	input_win = nil,
	output_win = nil,
}

local function close_windows()
	for _, win in ipairs({ state.input_win, state.output_win }) do
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
	state = { input_buf = nil, output_buf = nil, input_win = nil, output_win = nil }
end

local function create_float(title, width, height, row, col)
	local buf = vim.api.nvim_create_buf(false, true)

	local opts = {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
	}

	local win = vim.api.nvim_open_win(buf, false, opts)

	return buf, win
end

local function set_output(lines)
	vim.schedule(function()
		if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
			vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, lines)
		end
	end)
end

local function compile_and_run(current_file, input_text)
	local executable = "/tmp/" .. vim.fn.fnamemodify(current_file, ":t:r") .. "_testcase"
	local compile_cmd = string.format(config.compile_cmd, current_file, executable)

	set_output({ "Compiling..." })

	vim.fn.jobstart(compile_cmd, {
		on_exit = function(_, compile_code)
			if compile_code ~= 0 then
				set_output({
					"=== COMPILATION FAILED ===",
					"Check your code for errors.",
				})
				vim.schedule(function()
					vim.notify("Compilation failed!", vim.log.levels.ERROR)
				end)
				return
			end

			set_output({ "Running..." })

			-- Run with proper stdin handling
			local job_id = vim.fn.jobstart(executable, {
				stdout_buffered = true,
				stderr_buffered = true,
				stdin = "pipe", -- Enable stdin pipe
				on_stdout = function(_, data)
					if data and #data > 0 then
						local filtered = {}
						for _, line in ipairs(data) do
							if line ~= "" or #filtered > 0 then
								table.insert(filtered, line)
							end
						end
						if #filtered > 0 then
							set_output(filtered)
						end
					end
				end,
				on_stderr = function(_, data)
					if data and #data > 0 and data[1] ~= "" then
						local err = { "=== RUNTIME ERROR ===" }
						vim.list_extend(err, data)
						set_output(err)
					end
				end,
				on_exit = function(_, code)
					if code ~= 0 then
						vim.schedule(function()
							vim.notify(string.format("Program exited with code %d", code), vim.log.levels.WARN)
						end)
					end
				end,
			})

			-- Send all input at once and close stdin
			if job_id > 0 then
				vim.fn.chansend(job_id, input_text)
				vim.fn.chanclose(job_id, "stdin")
			end
		end,
		on_stderr = function(_, data)
			if data and #data > 0 and data[1] ~= "" then
				local err = { "=== COMPILATION ERROR ===" }
				vim.list_extend(err, data)
				set_output(err)
			end
		end,
	})
end

function M.run()
	local current_file = vim.fn.expand("%:p")
	local file_ext = vim.fn.expand("%:e")

	if not (file_ext == "cpp" or file_ext == "cc" or file_ext == "cxx") then
		vim.notify("Not a C++ file!", vim.log.levels.ERROR)
		return
	end

	vim.cmd("write")
	close_windows()

	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local total_width = math.floor(editor_width * config.width)
	if total_width % 2 == 1 then
		total_width = total_width - 1
	end
	local pane_width = math.floor((total_width - config.gap) / 2)
	local pane_height = math.floor(editor_height * config.height)
	local start_row = math.floor((editor_height - pane_height) / 2)
	local start_col_left = math.floor((editor_width - total_width) / 2)
	local start_col_right = start_col_left + pane_width + config.gap

	state.input_buf, state.input_win = create_float("Input", pane_width, pane_height, start_row, start_col_left)
	state.output_buf, state.output_win = create_float("Output", pane_width, pane_height, start_row, start_col_right)

	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, {})
	set_output({ "Waiting for input...", "", "Press <CR> in normal mode to run" })

	vim.api.nvim_set_current_win(state.input_win)

	-- Close with q
	vim.keymap.set("n", "q", close_windows, { buffer = state.input_buf, noremap = true, silent = true })
	vim.keymap.set("n", "q", close_windows, { buffer = state.output_buf, noremap = true, silent = true })

	-- Run with Enter in normal mode
	vim.keymap.set("n", "<CR>", function()
		local input_lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
		local input_text = table.concat(input_lines, "\n")
		compile_and_run(current_file, input_text)
	end, { buffer = state.input_buf, noremap = true, silent = true })

	vim.cmd("startinsert")
end

return M
