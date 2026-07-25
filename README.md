# testcasevim.nvim

Run competitive-programming test cases from inside Neovim, with clean
input/output separation and debug output that is actually readable.

Supports **C++**, **C**, **Python** and **Java**.

```
╭──────── Input · p131.cpp ────────╮ ╭──── Output · C++ · DEBUG ────╮
│ 2                                │ │ ▌ OUTPUT  2 lines            │
│ 3                                │ │                              │
│ 1 2 3                            │ │   6                          │
│ 4                                │ │   100                        │
│ 10 20 30 40                      │ │                              │
│                                  │ │ ▌ DEBUG  4 traces            │
│                                  │ │                              │
│                                  │ │   › solve:86  n, total = 3,6 │
│                                  │ │   › solve:87  a  = {1, 2, 3} │
╰──────────────────────────────────╯ ╰── ✓ exit 0 · run 6ms ────────╯
```

## Features

- **Side-by-side panes** — test input on the left, results on the right.
- **Press `<CR>`** in normal mode to compile & run.
- **Sectioned output** — program stdout, `dbg()` traces and real crashes never
  get mixed together.
- **Parsed debug traces** — `func:line [expr] = [value]` is rendered as an
  aligned table, with ANSI colour codes stripped.
- **Precise failures** — sanitizer reports, Python tracebacks and Java stack
  traces are condensed into a one-line diagnosis plus the evidence that
  matters (`✗ heap-buffer-overflow — READ of size 4 · at sol.cpp:57`).
- **Compiler diagnostics** — each error/warning with its source excerpt; press
  `<CR>` on one to jump straight to that line.
- **Timeout guard** — an infinite loop is killed instead of freezing Neovim.
- **Debug / release modes** — sanitizers and `-DDEBUG` on demand.
- **Timings** — compile and run duration in the pane footer.
- **Input is remembered** per source file, between runs and between sessions.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "MuazTPM-YT/testcasevim.nvim",
  name = "testcasevim",
  keys = {
    {
      "<leader><CR>",
      function()
        require("testcasevim").run()
      end,
      desc = "Run testcase",
    },
  },
}
```

Optional mode-switch mappings:

```lua
vim.keymap.set("n", "<C-Left>",  '<Cmd>lua require("testcasevim").set_debug()<CR>')
vim.keymap.set("n", "<C-Right>", '<Cmd>lua require("testcasevim").set_release()<CR>')
```

## Keys

| Key | Where | Action |
| --- | --- | --- |
| `<leader><CR>` | any source file | open the panes (your mapping) |
| `<CR>` | input pane | compile & run |
| `<CR>` | output pane | jump to the error under the cursor, else re-run |
| `q` | either pane | close |
| `<Tab>` | either pane | switch pane |
| `<C-c>` | either pane | stop the running program |

## Commands

`:Testcase`, `:TestcaseRun`, `:TestcaseStop`, `:TestcaseClose`,
`:TestcaseDebug`, `:TestcaseRelease`, `:TestcaseToggleMode`.

## Debug mode

`DEBUG` mode compiles with sanitizers and defines a debug flag; `RELEASE`
compiles the way a judge would.

| Language | Debug build | Release build | Debug switch |
| --- | --- | --- | --- |
| C++ | `-g -O2 -Wall -Wextra -Wshadow -fsanitize=address,undefined -D_GLIBCXX_DEBUG` | `-O2` | `-DDEBUG` |
| C | `-g -O2 -Wall -Wextra -Wshadow -fsanitize=address,undefined` | `-O2` | `-DDEBUG` |
| Python | — | — | `DEBUG=1` in the environment |
| Java | `javac -g -Xlint:all` | `javac` | `java -ea -DDEBUG=true` |

Anything your program writes to **stderr** while running is treated as debug
output and shown in its own `DEBUG` section — except lines that look like a
real failure (sanitizer reports, tracebacks, uncaught exceptions), which go to
`RUNTIME ERROR`.

The classic C++ macro works out of the box:

```cpp
#ifdef DEBUG
#define dbg(x...) cerr << "\e[91m" << __func__ << ":" << __LINE__ \
                       << " [" << #x << "] = ["; _print(x); cerr << "\e[39m" << endl;
#else
#define dbg(x...)
#endif
```

Equivalents for the other languages:

```c
/* C */
#ifdef DEBUG
#define dbg(fmt, ...) fprintf(stderr, "%s:%d [" #__VA_ARGS__ "] = [" fmt "]\n", \
                              __func__, __LINE__, __VA_ARGS__)
#else
#define dbg(fmt, ...)
#endif
```

```python
# Python
import os, sys
DEBUG = os.environ.get("DEBUG") == "1"
def dbg(**kw):
    if DEBUG:
        f = sys._getframe(1)
        for k, v in kw.items():
            print(f"{f.f_code.co_name}:{f.f_lineno} [{k}] = [{v}]", file=sys.stderr)
```

```java
// Java
static final boolean DEBUG = Boolean.getBoolean("DEBUG");
static void dbg(String expr, Object value) {
    if (DEBUG) System.err.println("dbg:0 [" + expr + "] = [" + value + "]");
}
```

## Configuration

`setup()` is optional — the defaults above are used when you never call it.

```lua
require("testcasevim").setup({
  mode = "debug",          -- starting mode: "debug" | "release"
  width = 0.85,            -- fraction of the editor used by both panes
  height = 0.8,
  gap = 4,                 -- columns between the panes
  border = "rounded",
  timeout_ms = 10000,      -- kill a run after this long (0 disables)
  max_output_lines = 5000, -- cap per section, so a runaway loop can't hang Neovim
  persist_input = true,    -- remember the test input per file
  auto_scroll = true,      -- follow output unless you scroll up
  number = true,           -- line numbers in the input pane
  pretty_debug = true,     -- parse `func:line [expr] = [value]` traces
})
```

### Custom compiler flags

Commands are argv lists, so paths with spaces are safe. Placeholders:
`{src}`, `{exe}`, `{outdir}`, `{class}`, `{dir}`, `{stem}`.

```lua
require("testcasevim").setup({
  languages = {
    cpp = {
      compile = {
        debug = { "g++", "-std=c++20", "-g", "-fsanitize=address,undefined", "-DDEBUG", "{src}", "-o", "{exe}" },
        release = { "g++", "-std=c++20", "-O2", "{src}", "-o", "{exe}" },
      },
    },
    python = { run = { "pypy3", "-u", "{src}" } },
  },
})
```

A plain string still works, using the old two-`%s` format (source, executable):

```lua
require("testcasevim").setup({
  debug_compile_cmd = 'g++ -std=c++17 -DDEBUG "%s" -o "%s"',
  release_compile_cmd = 'g++ -std=c++17 -O2 "%s" -o "%s"',
})
```

If a compiler is missing, a configured alternative is used automatically
(`g++`→`clang++`, `gcc`→`clang`, `python3`→`python`).

## Highlights

All groups link to your colourscheme's diagnostic colours by default and can
be overridden: `TestcaseVimTitle`, `TestcaseVimSection`, `TestcaseVimDim`,
`TestcaseVimOk`, `TestcaseVimError`, `TestcaseVimWarn`, `TestcaseVimInfo`,
`TestcaseVimHint`, `TestcaseVimLoc`, `TestcaseVimExpr`, `TestcaseVimValue`,
`TestcaseVimKey`.

## Notes

- Programs run with the **source file's directory** as the working directory,
  so `freopen("input.txt", ...)` works as expected.
- Build artefacts live in `stdpath("cache")/testcasevim/`, never next to your
  source files.
- Requires Neovim 0.8+ (window titles need 0.9, footers 0.10).
