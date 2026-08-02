---@module 'luassert'

local Config = require("sidekick.config")
local Util = require("sidekick.util")

describe("Herdr session backend", function()
  local orig_exec
  local orig_tools
  local orig_create
  local orig_warn
  local orig_executable
  local orig_has
  local orig_backends
  local orig_did_setup
  local orig_attached
  local orig_emit
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
      ["herdr" .. sep .. "pane" .. sep .. "process-info" .. sep .. "--pane" .. sep .. "w1:p2"] = json({
        result = {
          process_info = {
            foreground_processes = {
              {
                pid = 1234,
                name = "claude",
                argv = { "claude" },
                cwd = "/repo",
              },
            },
          },
        },
      }),
      ["herdr" .. sep .. "pane" .. sep .. "process-info" .. sep .. "--pane" .. sep .. "w1:p3"] = json({
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
      ["herdr" .. sep .. "pane" .. sep .. "process-info" .. sep .. "--pane" .. sep .. "w1:p4"] = json({
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

  local function lifecycle_fixture()
    local calls = {}
    local responses = {
      ["herdr" .. sep .. "status" .. sep .. "server" .. sep .. "--json"] = json({
        status = "running",
        running = true,
        version = "0.7.5",
        protocol = 17,
        compatible = true,
      }),
      ["herdr" .. sep .. "workspace" .. sep .. "list"] = json({
        result = {
          workspaces = {
            {
              workspace_id = "w1",
              active_tab_id = "w1:t1",
              label = "repo",
              pane_count = 1,
              tab_count = 1,
            },
          },
          type = "workspace_list",
        },
      }),
      ["herdr" .. sep .. "pane" .. sep .. "list"] = json({
        result = {
          panes = {
            {
              pane_id = "w1:p1",
              terminal_id = "term_shell",
              workspace_id = "w1",
              tab_id = "w1:t1",
              cwd = "/repo",
              foreground_cwd = "/repo",
            },
          },
          type = "pane_list",
        },
      }),
      ["herdr" .. sep .. "tab" .. sep .. "create" .. sep .. "--workspace" .. sep .. "w1" .. sep .. "--cwd" .. sep .. "/repo" .. sep .. "--label" .. sep .. "claude" .. sep .. "--no-focus"] = json({
        result = {
          tab = { tab_id = "t2" },
          root_pane = { pane_id = "w1:p2" },
        },
      }),
      ["herdr" .. sep .. "pane" .. sep .. "run" .. sep .. "w1:p2" .. sep .. "claude"] = json({
        result = {},
      }),
      ["herdr" .. sep .. "pane" .. sep .. "get" .. sep .. "w1:p2"] = json({
        result = {
          pane = {
            pane_id = "w1:p2",
            terminal_id = "term_abc123",
            workspace_id = "w1",
            tab_id = "t2",
            cwd = "/repo",
          },
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

  local function operation_fixture()
    local calls = {}
    local responses = {
      ["herdr" .. sep .. "pane" .. sep .. "send-text" .. sep .. "w1:p2" .. sep .. "line 1\nline 2"] = { {}, "" },
      ["herdr" .. sep .. "pane" .. sep .. "send-keys" .. sep .. "w1:p2" .. sep .. "enter"] = { {}, "" },
      ["herdr" .. sep .. "pane" .. sep .. "read" .. sep .. "w1:p2" .. sep .. "--source" .. sep .. "recent-unwrapped" .. sep .. "--lines" .. sep .. "2000"] = {
        { "captured output" },
        "captured output",
      },
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
    orig_create = Config.cli.mux.create
    orig_warn = Util.warn
    local Session = require("sidekick.cli.session")
    orig_executable = vim.fn.executable
    orig_has = vim.fn.has
    orig_backends = Session.backends
    orig_did_setup = Session.did_setup
    orig_attached = Session._attached
    orig_emit = Util.emit
  end)

  after_each(function()
    Util.exec = orig_exec
    Config.tools = orig_tools
    Config.cli.mux.create = orig_create
    Util.warn = orig_warn
    vim.fn.executable = orig_executable
    vim.fn.has = orig_has
    local Session = require("sidekick.cli.session")
    Session.backends = orig_backends
    Session.did_setup = orig_did_setup
    Session._attached = orig_attached
    Util.emit = orig_emit
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

  it("creates a Herdr tab and returns a direct attach command", function()
    local calls, exec = lifecycle_fixture()
    Util.exec = exec

    local Herdr = require("sidekick.cli.session.herdr")
    local session = setmetatable({ cwd = "/repo", tool = tool("claude", "claude") }, Herdr)
    session:init()

    assert.is_false(session.external)
    assert.are.equal(50, session.priority)

    assert.are.same({
      cmd = { "herdr", "terminal", "attach", "term_abc123", "--takeover" },
      env = {
        HERDR_ENV = false,
        HERDR_PANE_ID = false,
        HERDR_TAB_ID = false,
        HERDR_WORKSPACE_ID = false,
      },
    }, session:start())
    assert.are.same({
      { "herdr", "status", "server", "--json" },
      { "herdr", "workspace", "list" },
      { "herdr", "pane", "list" },
      { "herdr", "tab", "create", "--workspace", "w1", "--cwd", "/repo", "--label", "claude", "--no-focus" },
      { "herdr", "pane", "run", "w1:p2", "claude" },
      { "herdr", "pane", "get", "w1:p2" },
    }, calls)
  end)

  it("attaches discovered Herdr sessions externally and sends in background", function()
    local calls, exec = operation_fixture()
    Util.exec = exec
    Util.emit = function() end

    local Session = require("sidekick.cli.session")
    local Herdr = require("sidekick.cli.session.herdr")
    Session.backends = {}
    Session._attached = {}
    Session.register("herdr", Herdr)

    local session = Session.new({
      backend = "herdr",
      started = true,
      id = "herdr: term_abc123",
      cwd = "/repo",
      tool = tool("claude", "claude"),
      herdr_pane_id = "w1:p2",
      herdr_terminal_id = "term_abc123",
      mux_session = "term_abc123",
    })

    assert.is_true(session.external)
    assert.are.equal(10, session.priority)
    assert.is_nil(session:attach())

    local attached = Session.attach(session)
    assert.are.equal(session, attached)
    assert.is_true(attached:is_attached())
    assert.are.equal("herdr", attached.backend)

    attached:send("line 1\nline 2")
    attached:submit()
    assert.are.same({
      { "herdr", "pane", "send-text", "w1:p2", "line 1\nline 2" },
      { "herdr", "pane", "send-keys", "w1:p2", "enter" },
    }, calls)
  end)

  it("warns and falls back to terminal attach for other create modes", function()
    local _, exec = lifecycle_fixture()
    Util.exec = exec
    Config.cli.mux.create = "split"
    local warnings = {}
    Util.warn = function(msg)
      warnings[#warnings + 1] = msg
    end

    local Herdr = require("sidekick.cli.session.herdr")
    local session = setmetatable({ cwd = "/repo", tool = tool("claude", "claude") }, Herdr)
    session:start()

    assert.is_true(#warnings > 0)
  end)

  it("sends input and reads Herdr scrollback", function()
    local calls, exec = operation_fixture()
    Util.exec = exec

    local Herdr = require("sidekick.cli.session.herdr")
    local session = setmetatable({ herdr_pane_id = "w1:p2" }, Herdr)
    session:send("line 1\nline 2")
    session:submit()

    assert.are.equal("captured output", session:dump())
    assert.are.same({
      { "herdr", "pane", "send-text", "w1:p2", "line 1\nline 2" },
      { "herdr", "pane", "send-keys", "w1:p2", "enter" },
      { "herdr", "pane", "read", "w1:p2", "--source", "recent-unwrapped", "--lines", "2000" },
    }, calls)
  end)

  it("does not close Herdr resources when detached", function()
    local calls, exec = operation_fixture()
    Util.exec = exec

    local Herdr = require("sidekick.cli.session.herdr")
    local session = setmetatable({ herdr_pane_id = "w1:p2" }, Herdr)
    session:detach()

    assert.are.same({}, calls)
  end)

  it("registers Herdr on supported Unix systems", function()
    local Session = require("sidekick.cli.session")
    vim.fn.executable = function(name)
      return name == "herdr" and 1 or 0
    end
    vim.fn.has = function(name)
      return name == "win32" and 0 or orig_has(name)
    end
    Session.backends = {}
    Session.did_setup = false

    Session.setup()

    assert.is_truthy(Session.backends.herdr)
  end)

  it("does not register Herdr when unavailable or on Windows", function()
    local Session = require("sidekick.cli.session")
    for _, platform in ipairs({ "missing", "windows" }) do
      vim.fn.executable = function(name)
        return platform ~= "missing" and name == "herdr" and 1 or 0
      end
      vim.fn.has = function(name)
        return name == "win32" and (platform == "windows" and 1 or 0) or orig_has(name)
      end
      Session.backends = {}
      Session.did_setup = false
      Session.setup()
      assert.is_nil(Session.backends.herdr)
    end
  end)
end)
