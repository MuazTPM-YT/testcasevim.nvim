local M = {}

local config = {
	compile_cmd = 'g++ -std=c++17 -O2 -Wall -Wextra -Wshadow -fsanitize=address,undefined -D_GLIBCXX_DEBUG "%s" -o "%s"',
	width = 0.7,
	height = 0.7,
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
	state.input_buf, state.output_buf, state.input_win, state.output_win = nil, nil, nil, nil
end

local function create_float_window(title, left_side, total_width, height, row, col)
	local buf = vim.api.nvim_create_buf(false, true)
	local opts = {
		relative = "editor",
		width = total_width / 2,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
		noautocmd = true,
	}
	local win = vim.api.nvim_open_win(buf, false, opts)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	return buf, win
end

function M.run()
	-- Check filetype
	local current_file = vim.fn.expand("%:p")
	local file_ext = vim.fn.expand("%:e")
	if not (file_ext == "cpp" or file_ext == "cxx" or file_ext == "cc") then
		vim.notify("Not a C++ file!", vim.log.levels.ERROR)
		return
	end
	vim.cmd("write")
	close_windows()

	-- Get proper dimensions and spacing
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local float_width = math.floor(editor_width * config.width)
	if float_width % 2 == 1 then
		float_width = float_width - 1
	end -- ensure even for split
	local float_height = math.floor(editor_height * config.height)
	local row = math.floor((editor_height - float_height) / 2)
	local col_left = math.floor((editor_width - float_width) / 2)
	local col_right = col_left + float_width // 2

	-- Create truly side-by-side blank windows
	state.input_buf, state.input_win = create_float_window("Input", true, float_width, float_height, row, col_left)
	state.output_buf, state.output_win = create_float_window("Output", false, float_width, float_height, row, col_right)

	-- **No prefilled text** at all!
	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, {})
	vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, {})

	vim.api.nvim_set_current_win(state.input_win)

	-- q closes both windows
	vim.keymap.set("n", "q", close_windows, { buffer = state.input_buf, noremap = true, silent = true })
	vim.keymap.set("n", "q", close_windows, { buffer = state.output_buf, noremap = true, silent = true })

	-- <leader>r compiles and runs
	vim.keymap.set("n", "<leader>r", function()
		local input_lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
		local input_text = table.concat(input_lines, "\n")
		local executable = "/tmp/" .. vim.fn.expand("%:t:r") .. "_nvim_run"
		local compile_cmd = string.format(config.compile_cmd, current_file, executable)
		local full_cmd = string.format('%s && echo "%s" | %s', compile_cmd, input_text, executable)
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
			on_exit = function(_, code)
				if code ~= 0 then
					vim.schedule(function()
						vim.notify(string.format("Exited with code %d", code), vim.log.levels.ERROR)
					end)
				end
			end,
		})
	end, { buffer = state.input_buf, noremap = true, silent = true })

	vim.cmd("startinsert")
end

return M
