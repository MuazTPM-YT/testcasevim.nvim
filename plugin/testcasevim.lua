-- User commands. Everything is required lazily so loading this file stays cheap.
if vim.g.loaded_testcasevim then
	return
end
vim.g.loaded_testcasevim = true

local function cmd(name, fn, desc)
	vim.api.nvim_create_user_command(name, fn, { desc = desc })
end

cmd("Testcase", function()
	require("testcasevim").run()
end, "Open the test-case panes for the current file")

cmd("TestcaseRun", function()
	require("testcasevim").execute()
end, "Compile & run the current test case")

cmd("TestcaseStop", function()
	require("testcasevim").stop()
end, "Stop the running program")

cmd("TestcaseClose", function()
	require("testcasevim").close()
end, "Close the test-case panes")

cmd("TestcaseDebug", function()
	require("testcasevim").set_debug()
end, "Switch to DEBUG build mode")

cmd("TestcaseRelease", function()
	require("testcasevim").set_release()
end, "Switch to RELEASE build mode")

cmd("TestcaseToggleMode", function()
	require("testcasevim").toggle_mode()
end, "Toggle between DEBUG and RELEASE build modes")
