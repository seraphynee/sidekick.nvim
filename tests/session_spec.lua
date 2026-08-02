---@module 'luassert'

local Config = require("sidekick.config")
local Util = require("sidekick.util")

describe("Herdr session backend", function()
  local orig_exec
  local orig_tools
  local sep = string.char(0)

  local function json(value)
    local stdout = vim.json.encode(value)
    return { vim.split(stdout, "\n", { plain = true, trimempty = true }), stdout }
  end

  local function tool(name, pattern)
    return {
      name = name,
      cmd = { name },
      is_proc = function(_, proc)
        return proc.cmd:find(pattern, 1, true) ~= nil
      end,
    }
  end

  local function fixture()
    local calls = {}
    local responses = {
      ["herdr" .. sep .. "pane" .. sep .. "list"] = json({
        result = {
          panes = {
            {
              pane_id = "w1:p2",
              terminal_id = "term_abc123",
              workspace_id = "w1",
              tab_id = "t1",
              cwd = "/repo",
            },
            {
              pane_id = "w1:p3",
              terminal_id = "term_unrelated",
              workspace_id = "w1",
              tab_id = "t1",
              cwd = "/repo",
            },
            {
              pane_id = "w1:p4",
              workspace_id = "w1",
              tab_id = "t1",
              cwd = "/repo",
            },
          },
        },
      }),
      ["herdr" .. sep .. "pane" .. sep .. "get" .. sep .. "w1:p2"] = json({
        result = {
          pane = {
            pane_id = "w1:p2",
            terminal_id = "term_abc123",
            workspace_id = "w1",
            tab_id = "t1",
            cwd = "/repo",
          },
        },
      }),
      ["herdr" .. sep .. "pane" .. sep .. "get" .. sep .. "w1:p3"] = json({
        result = {
          pane = {
            pane_id = "w1:p3",
            terminal_id = "term_unrelated",
            workspace_id = "w1",
            tab_id = "t1",
            cwd = "/repo",
          },
        },
      }),
      ["herdr" .. sep .. "pane" .. sep .. "get" .. sep .. "w1:p4"] = json({
        result = {
          pane = {
            pane_id = "w1:p4",
            workspace_id = "w1",
            tab_id = "t1",
            cwd = "/repo",
          },
        },
      }),
      ["herdr" .. sep .. "pane" .. sep .. "process-info" .. sep .. "w1:p2"] = json({
        result = {
          processes = {
            {
              pid = 1234,
              name = "claude",
              argv = { "claude" },
              cwd = "/repo",
            },
          },
        },
      }),
      ["herdr" .. sep .. "pane" .. sep .. "process-info" .. sep .. "w1:p3"] = json({
        result = {
          processes = {
            {
              pid = 2345,
              name = "bash",
              argv = { "bash" },
              cwd = "/repo",
            },
          },
        },
      }),
      ["herdr" .. sep .. "pane" .. sep .. "process-info" .. sep .. "w1:p4"] = json({
        result = {
          processes = {},
        },
      }),
    }

    local function exec(cmd)
      local key = table.concat(cmd, sep)
      calls[#calls + 1] = cmd
      local response = responses[key]
      assert.is_truthy(response, "Unexpected Herdr command: " .. key:gsub(sep, " "))
      return response[1], response[2]
    end

    return calls, exec
  end

  before_each(function()
    orig_exec = Util.exec
    orig_tools = Config.tools
  end)

  after_each(function()
    Util.exec = orig_exec
    Config.tools = orig_tools
  end)

  it("discovers running tools from Herdr panes", function()
    local calls, exec = fixture()
    Util.exec = exec
    Config.tools = function()
      return { tool("claude", "claude") }
    end

    local states = require("sidekick.cli.session.herdr").sessions()

    assert.are.equal(1, #states)
    local state = states[1]
    assert.are.equal("herdr: term_abc123", state.id)
    assert.are.equal("term_abc123", state.mux_session)
    assert.are.equal("w1:p2", state.herdr_pane_id)
    assert.are.equal("/repo", state.cwd)
    assert.are.equal("claude", state.tool.name)
    assert.are.same({ 1234 }, state.pids)
  end)
end)
