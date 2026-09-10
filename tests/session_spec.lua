---@module 'luassert'

local Config = require("sidekick.config")
local Util = require("sidekick.util")

describe("Herdr session backend", function()
  local orig_exec
  local orig_tools
  local orig_executable
  local orig_has
  local orig_backends
  local orig_did_setup
  local orig_attached
  local orig_emit
  local orig_terminal_init
  local orig_terminal_start
  local orig_terminal_terminals
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
              agent = "pi",
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
            agent = "pi",
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
                name = "node",
                argv0 = "pi",
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
              name = "python",
              argv0 = "aider",
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
    local Session = require("sidekick.cli.session")
    local Terminal = require("sidekick.cli.terminal")
    orig_executable = vim.fn.executable
    orig_has = vim.fn.has
    orig_backends = Session.backends
    orig_did_setup = Session.did_setup
    orig_attached = Session._attached
    orig_emit = Util.emit
    orig_terminal_init = Terminal.init
    orig_terminal_start = Terminal.start
    orig_terminal_terminals = Terminal.terminals
  end)

  after_each(function()
    Util.exec = orig_exec
    Config.tools = orig_tools
    vim.fn.executable = orig_executable
    vim.fn.has = orig_has
    local Session = require("sidekick.cli.session")
    Session.backends = orig_backends
    Session.did_setup = orig_did_setup
    Session._attached = orig_attached
    Util.emit = orig_emit
    local Terminal = require("sidekick.cli.terminal")
    Terminal.init = orig_terminal_init
    Terminal.start = orig_terminal_start
    Terminal.terminals = orig_terminal_terminals
  end)

  it("discovers running tools from Herdr panes", function()
    local calls, exec = fixture()
    Util.exec = exec
    Config.tools = function()
      return { tool("pi", "pi"), tool("aider", "aider") }
    end

    local states = require("sidekick.cli.session.herdr").sessions()

    assert.are.equal(2, #states)
    assert.are.equal("herdr: term_abc123", states[1].id)
    assert.are.equal("term_abc123", states[1].mux_session)
    assert.are.equal("w1:p2", states[1].herdr_pane_id)
    assert.are.equal("/repo", states[1].cwd)
    assert.are.equal("pi", states[1].tool.name)
    assert.are.same({ 1234 }, states[1].pids)
    assert.are.equal("aider", states[2].tool.name)
    assert.are.same({ 2345 }, states[2].pids)
  end)

  it("uses Herdr agent identity when checking a session", function()
    local calls = {}
    Util.exec = function(cmd)
      calls[#calls + 1] = vim.deepcopy(cmd)
      return unpack(json({
        result = {
          pane = {
            pane_id = "w1:p2",
            terminal_id = "term_abc123",
            agent = "pi",
          },
        },
      }))
    end

    local Herdr = require("sidekick.cli.session.herdr")
    local session = setmetatable({
      tool = tool("pi", "pi"),
      herdr_pane_id = "w1:p2",
      herdr_terminal_id = "term_abc123",
    }, Herdr)

    assert.is_true(session:is_running())
    assert.are.same({ { "herdr", "pane", "get", "w1:p2" } }, calls)
  end)

  it("returns new tool commands without creating Herdr resources", function()
    local calls = {}
    Util.exec = function(cmd)
      calls[#calls + 1] = vim.deepcopy(cmd)
      local value = cmd[2] == "status" and { running = true } or { result = {} }
      local stdout = vim.json.encode(value)
      return vim.split(stdout, "\n", { plain = true, trimempty = true }), stdout
    end

    local agent = tool("claude", "claude")
    agent.cmd = { "claude", "--continue" }
    agent.env = { CLAUDE_CONFIG_DIR = "/tmp/claude", REMOVE_ME = false }
    local Herdr = require("sidekick.cli.session.herdr")
    local session = setmetatable({ cwd = "/repo", tool = agent }, Herdr)

    local command = session:start()

    assert.are.same({
      cmd = { "claude", "--continue" },
      env = { CLAUDE_CONFIG_DIR = "/tmp/claude", REMOVE_ME = false },
    }, command)
    assert.are.same({}, calls)

    command.cmd[1] = "changed"
    command.env.CLAUDE_CONFIG_DIR = "changed"
    assert.are.same({ "claude", "--continue" }, agent.cmd)
    assert.are.same({ CLAUDE_CONFIG_DIR = "/tmp/claude", REMOVE_ME = false }, agent.env)
  end)

  it("wraps new Herdr-backed tools in a Neovim terminal", function()
    local calls = {}
    Util.exec = function(cmd)
      calls[#calls + 1] = vim.deepcopy(cmd)
      local value = cmd[2] == "status" and { running = true } or { result = {} }
      local stdout = vim.json.encode(value)
      return vim.split(stdout, "\n", { plain = true, trimempty = true }), stdout
    end
    Util.emit = function() end

    local Session = require("sidekick.cli.session")
    local Herdr = require("sidekick.cli.session.herdr")
    local Terminal = require("sidekick.cli.terminal")
    Session.backends = {}
    Session._attached = {}
    Terminal.terminals = {}
    Terminal.init = function(self)
      Terminal.terminals[self.id] = self
      return self
    end
    Terminal.start = function(self)
      self.started = true
    end
    Session.register("herdr", Herdr)
    Session.register("terminal", Terminal)

    local agent = require("sidekick.cli.tool").get("claude")
    agent.cmd = { "claude", "--continue" }
    agent.env = { CLAUDE_CONFIG_DIR = "/tmp/claude" }
    local session = Session.new({ backend = "herdr", cwd = "/repo", tool = agent })

    local attached = Session.attach(session)

    assert.are.equal("terminal", attached.backend)
    assert.are.same({ "claude", "--continue" }, attached.tool.cmd)
    assert.are.same({ CLAUDE_CONFIG_DIR = "/tmp/claude" }, attached.tool.env)
    assert.are.equal("herdr", attached.mux_backend)
    assert.are.same({}, calls)
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
