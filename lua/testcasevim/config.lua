-- Configuration: defaults, language definitions and `setup()` merging.
--
-- Commands are declared as argv lists so file names never go through a shell.
-- Placeholders:
--   {src}     absolute path of the source file
--   {exe}     absolute path of the compiled binary
--   {outdir}  scratch directory for build artefacts (Java classes, ...)
--   {class}   fully qualified Java class name
--   {dir}     directory containing the source file
--   {stem}    file name without extension
local M = {}

local defaults = {
	-- "debug" or "release"; toggled by set_debug()/set_release()/toggle_mode().
	mode = "debug",

	-- Floating window geometry (fractions of the editor).
	width = 0.85,
	height = 0.8,
	gap = 4,
	border = "rounded",

	-- Kill a run after this many milliseconds (0 disables the guard).
	timeout_ms = 10000,

	-- Hard cap on captured lines per stream, so a runaway loop cannot
	-- freeze the editor.
	max_output_lines = 5000,

	-- Remember the test input per source file between runs and sessions.
	persist_input = true,

	-- Follow new output unless the cursor has been scrolled up.
	auto_scroll = true,

	-- Show line numbers in the input pane.
	number = true,

	-- Parse `func:line [expr] = [value]` traces into an aligned table.
	pretty_debug = true,

	icons = {
		ok = "✓",
		error = "✗",
		warn = "⚠",
		info = "•",
		debug = "›",
		bar = "▌",
		arrow = "→",
		spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
	},

	-- If the first executable of a command is missing, try these in order.
	fallbacks = {
		["g++"] = { "clang++", "c++" },
		["gcc"] = { "clang", "cc" },
		["python3"] = { "python", "py" },
	},

	languages = {
		cpp = {
			name = "C++",
			extensions = { "cpp", "cc", "cxx", "c++", "cp", "C", "ino" },
			filetypes = { "cpp" },
			compile = {
				debug = {
					"g++",
					"-std=c++17",
					"-O2",
					"-g",
					"-Wall",
					"-Wextra",
					"-Wshadow",
					"-fsanitize=address,undefined",
					"-fno-omit-frame-pointer",
					"-D_GLIBCXX_DEBUG",
					"-DDEBUG",
					"{src}",
					"-o",
					"{exe}",
				},
				release = { "g++", "-std=c++17", "-O2", "{src}", "-o", "{exe}" },
			},
			run = { "{exe}" },
			env = {
				debug = {
					ASAN_OPTIONS = "detect_leaks=1:abort_on_error=0:color=never",
					UBSAN_OPTIONS = "print_stacktrace=1:color=never",
				},
			},
		},

		c = {
			name = "C",
			extensions = { "c" },
			filetypes = { "c" },
			compile = {
				debug = {
					"gcc",
					"-std=c17",
					"-O2",
					"-g",
					"-Wall",
					"-Wextra",
					"-Wshadow",
					"-fsanitize=address,undefined",
					"-fno-omit-frame-pointer",
					"-DDEBUG",
					"{src}",
					"-o",
					"{exe}",
					"-lm",
				},
				release = { "gcc", "-std=c17", "-O2", "{src}", "-o", "{exe}", "-lm" },
			},
			run = { "{exe}" },
			env = {
				debug = {
					ASAN_OPTIONS = "detect_leaks=1:abort_on_error=0:color=never",
					UBSAN_OPTIONS = "print_stacktrace=1:color=never",
				},
			},
		},

		python = {
			name = "Python",
			extensions = { "py" },
			filetypes = { "python" },
			-- Interpreted: no compile step.
			compile = nil,
			run = { "python3", "-u", "{src}" },
			env = {
				debug = { DEBUG = "1", PYTHONFAULTHANDLER = "1" },
			},
		},

		java = {
			name = "Java",
			extensions = { "java" },
			filetypes = { "java" },
			compile = {
				debug = { "javac", "-g", "-Xlint:all", "-d", "{outdir}", "{src}" },
				release = { "javac", "-d", "{outdir}", "{src}" },
			},
			run = {
				debug = { "java", "-ea", "-Xss64m", "-DDEBUG=true", "-cp", "{outdir}", "{class}" },
				release = { "java", "-Xss64m", "-cp", "{outdir}", "{class}" },
			},
		},
	},
}

M.options = vim.deepcopy(defaults)

--- Backwards compatible keys from the pre-rewrite config.
--- `compile_cmd` / `debug_compile_cmd` / `release_compile_cmd` were plain
--- `string.format` templates with two `%s` (source, executable) and only ever
--- applied to C++.
local function apply_legacy(opts)
	local cpp = M.options.languages.cpp
	if type(opts.debug_compile_cmd) == "string" then
		cpp.compile.debug = opts.debug_compile_cmd
	end
	if type(opts.release_compile_cmd) == "string" then
		cpp.compile.release = opts.release_compile_cmd
	end
	-- `compile_cmd` had no mode of its own; it applied to whatever mode was active.
	if type(opts.compile_cmd) == "string" then
		cpp.compile[M.options.mode] = opts.compile_cmd
	end
end

--- Merge user options. Language tables are merged per language so overriding
--- one command does not wipe the others.
function M.setup(opts)
	opts = opts or {}
	local langs = opts.languages
	opts = vim.deepcopy(opts)
	opts.languages = nil
	M.options = vim.tbl_deep_extend("force", M.options, opts)

	if langs then
		for key, spec in pairs(langs) do
			local base = M.options.languages[key]
			if base then
				-- Lists must be replaced wholesale, not deep-merged element-wise.
				for _, field in ipairs({ "compile", "run", "extensions", "filetypes" }) do
					if spec[field] ~= nil then
						base[field] = vim.deepcopy(spec[field])
					end
				end
				for field, value in pairs(spec) do
					if field ~= "compile" and field ~= "run" and field ~= "extensions" and field ~= "filetypes" then
						base[field] = vim.deepcopy(value)
					end
				end
			else
				M.options.languages[key] = vim.deepcopy(spec)
			end
		end
	end

	if M.options.mode ~= "debug" and M.options.mode ~= "release" then
		M.options.mode = "debug"
	end

	-- Lists must replace, not merge element-wise.
	if opts.icons and opts.icons.spinner then
		M.options.icons.spinner = vim.deepcopy(opts.icons.spinner)
	end

	apply_legacy(opts)
	return M.options
end

function M.get()
	return M.options
end

return M
