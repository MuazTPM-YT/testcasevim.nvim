local M = {}

local config = {
	compile_cmd = 'g++ -std=c++17 -O2 -Wall -Wextra -Wshadow -fsanitize=address,undefined -D_GLIBCXX_DEBUG "%s" -o "%s"',
	width = 0.8,
	height = 0.8,
}

local state = {
	input_buf = nil,
	output_buf = nil,
	input_win = nil,
	output_win = nil,
}

local function close_windows()
	if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
		vim.api.nvim_win_close(state.input_win, true)
	end
	if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
		vim.api.nvim_win_close(state.output_win, true)
	end
	state = { input_buf = nil, output_buf = nil, input_win = nil, output_win = nil }
end

local function create_float_window(title, col_start)
	local buf = vim.api.nvim_create_buf(false, true)

	local width = math.floor(vim.o.columns * config.width / 2)
	local height = math.floor(vim.o.lines * config.height)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = col_start

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

	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "modifiable", true)

	return buf, win
end

function M.run()
	local current_file = vim.fn.expand("%:p")
	local file_ext = vim.fn.expand("%:e")

	if file_ext ~= "cpp" and file_ext ~= "cc" and file_ext ~= "cxx" then
		vim.notify("Not a C++ file!", vim.log.levels.ERROR)
		return
	end

	vim.cmd("write")

	close_windows()

	local total_width = math.floor(vim.o.columns * config.width)
	local half_width = math.floor(total_width / 2)
	local start_col = math.floor((vim.o.columns - total_width) / 2)

	state.input_buf, state.input_win = create_float_window(" Input ", start_col)
	state.output_buf, state.output_win = create_float_window(" Output ", start_col + half_width)

	vim.api.nvim_set_current_win(state.input_win)

	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, {
		"-- Paste input here --",
		"-- Press <leader>r to run --",
		"-- Press q to close --",
		"",
	})

	vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, {
		"Output will be shown here...",
	})

	vim.api.nvim_buf_set_keymap(state.input_buf, "n", "q", "", {
		callback = close_windows,
		noremap = true,
		silent = true,
	})

	vim.api.nvim_buf_set_keymap(state.input_buf, "n", "<leader>r", "", {
		callback = function()
			local input_lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
			local input_text = table.concat(input_lines, "\n")

			local executable = "/tmp/" .. vim.fn.expand("%:t:r") .. "_nvim_run"
			local compile_cmd = string.format(config.compile_cmd, current_file, executable)
			local full_cmd = string.format('%s && echo "%s" | %s', compile_cmd, input_text, executable)

			vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, { "Compiling..." })

			vim.fn.jobstart(full_cmd, {
				stdout_buffered = true,
				stderr_buffered = true,
				on_stdout = function(_, data)
					if data then
						vim.schedule(function()
							vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, data)
						end)
					end
				end,
				on_stderr = function(_, data)
					if data and #data > 0 and data[1] ~= "" then
						vim.schedule(function()
							local err = { "=== COMPILATION/RUNTIME ERROR ===" }
							vim.list_extend(err, data)
							vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, err)
						end)
					end
				end,
				on_exit = function(_, code)
					if code ~= 0 then
						vim.schedule(function()
							vim.notify("Execution failed with code: " .. code, vim.log.levels.ERROR)
						end)
					end
				end,
			})
		end,
		noremap = true,
		silent = true,
	})

	vim.api.nvim_buf_set_keymap(state.output_buf, "n", "q", "", {
		callback = close_windows,
		noremap = true,
		silent = true,
	})

	vim.cmd("startinsert")
end

return M
