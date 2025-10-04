local M = {}

local config = {
	compile_cmd = 'g++ -std=c++17 -O2 -Wall -Wextra -Wshadow -fsanitize=address,undefined -D_GLIBCXX_DEBUG "%s" -o "%s"',
	width = 0.8,
	height = 0.8,
	gap = 4,
}

local state = {}

local function close_windows()
	for _, win in ipairs({ state.input_win, state.output_win }) do
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	state = {}
end

local function create_float(title, side, width, height, row, col)
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
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	return buf, win
end

function M.run()
	vim.cmd("write")
	close_windows()

	local cols = vim.o.columns
	local lines = vim.o.lines
	local total_w = math.floor(cols * config.width)
	local total_h = math.floor(lines * config.height)
	if total_w % 2 == 1 then
		total_w = total_w - 1
	end
	local pane_w = math.floor((total_w - config.gap) / 2)
	local pane_h = total_h
	local start_row = math.floor((lines - total_h) / 2)
	local start_col_left = math.floor((cols - total_w) / 2)
	local start_col_right = start_col_left + pane_w + config.gap

	state.input_buf, state.input_win = create_float("Input", "left", pane_w, pane_h, start_row, start_col_left)
	state.output_buf, state.output_win = create_float("Output", "right", pane_w, pane_h, start_row, start_col_right)

	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, {})
	vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, {})

	vim.api.nvim_set_current_win(state.input_win)

	vim.keymap.set("n", "q", close_windows, { buffer = state.input_buf })
	vim.keymap.set("n", "q", close_windows, { buffer = state.output_buf })

	-- Compile and run!
	vim.keymap.set("n", "<leader>r", function()
		local current_file = vim.fn.expand("%:p")
		local file_ext = vim.fn.expand("%:e")
		if not (file_ext == "cpp" or file_ext == "cc" or file_ext == "cxx") then
			vim.notify("Not a C++ file!", vim.log.levels.ERROR)
			return
		end
		local input = table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n")
		local exec_path = "/tmp/" .. vim.fn.expand("%:t:r") .. "_nvim_run"
		local compile = string.format(config.compile_cmd, current_file, exec_path)
		local full_cmd = string.format('%s && echo "%s" | %s', compile, input, exec_path)
		vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, {})
		vim.fn.jobstart(full_cmd, {
			stdout_buffered = true,
			stderr_buffered = true,
			on_stdout = function(_, data)
				if data and #data > 0 then
					vim.schedule(function()
						vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, data)
					end)
				end
			end,
			on_stderr = function(_, data)
				if data and #data > 0 and data[1] ~= "" then
					vim.schedule(function()
						vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, data)
					end)
				end
			end,
		})
	end, { buffer = state.input_buf })

	vim.cmd("startinsert")
end

return M
