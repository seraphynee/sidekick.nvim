local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_pane_id? string
---@field herdr_terminal_id? string
---@field herdr_workspace_id? string
---@field herdr_tab_id? string
local M = {}
M.__index = M
M.priority = 50
M.external = false

local function json(cmd, opts)
  local _, stdout = Util.exec(cmd, { notify = opts and opts.notify == true or false })
  if not stdout then
    return
  end
  local ok, value = pcall(vim.json.decode, stdout)
  if not ok or type(value) ~= "table" then
    Util.debug("Invalid Herdr JSON response", { cmd = cmd, stdout = stdout })
    return
  end
  return value
end

local function text(cmd, opts)
  local _, stdout = Util.exec(cmd, { notify = opts and opts.notify == true or false })
  return stdout
end

---@param response table?
---@param key string
---@return table?
local function record(response, key)
  if type(response) ~= "table" or type(response.result) ~= "table" then
    return
  end
  local value = response.result[key]
  return type(value) == "table" and value or nil
end

---@param response table?
---@param key string
---@return table
local function records(response, key)
  if type(response) ~= "table" or type(response.result) ~= "table" then
    return {}
  end
  local value = response.result[key]
  if type(value) ~= "table" then
    return {}
  end
  return value
end

---@param pane table
---@return table
local function pane_record(pane)
  return {
    pane_id = pane.pane_id or pane.id,
    terminal_id = pane.terminal_id,
    workspace_id = pane.workspace_id,
    tab_id = pane.tab_id,
    cwd = pane.cwd or pane.foreground_cwd,
    foreground_cwd = pane.foreground_cwd,
  }
end

---@param pane table
---@param process table
---@return sidekick.cli.Proc?
local function normalize_process(pane, process)
  if type(process) ~= "table" or type(process.pid) ~= "number" then
    return
  end
  local cmd = process.cmdline
  if type(cmd) ~= "string" or cmd == "" then
    local argv = process.argv or {}
    cmd = table.concat(argv, " ")
    if cmd == "" then
      cmd = process.name or ""
    end
  end
  if cmd == "" then
    return
  end
  return {
    pid = process.pid,
    ppid = process.ppid or 0,
    cmd = cmd,
    cwd = process.cwd or pane.foreground_cwd or pane.cwd,
  }
end

---@param pane table
---@return sidekick.cli.Proc[]
local function pane_processes(pane)
  local response = json({ "herdr", "pane", "process-info", pane.pane_id })
  local result = response and response.result
  if type(result) ~= "table" then
    return {}
  end
  local raw = result.processes
  if type(raw) ~= "table" and type(result.foreground_process) == "table" then
    raw = { result.foreground_process }
  end
  local ret = {}
  for _, process in ipairs(raw or {}) do
    local normalized = normalize_process(pane, process)
    if normalized then
      ret[#ret + 1] = normalized
    end
  end
  return ret
end

---@param terminal_id string
---@return integer[]
local function attached_pids(terminal_id)
  local ret = {} ---@type integer[]
  local Terminal = require("sidekick.cli.terminal")
  for _, terminal in pairs(Terminal.terminals) do
    if terminal.mux_backend == "herdr" and terminal.mux_session == terminal_id then
      vim.list_extend(ret, terminal.pids or {})
    end
  end
  return ret
end

local function server_ready()
  return json({ "herdr", "status", "--json", "server" }) ~= nil
end

local function ensure_server()
  if server_ready() then
    return true
  end

  local job = vim.fn.jobstart({ "herdr", "server" }, { detach = true })
  if job <= 0 then
    Util.error("Failed to start Herdr server with `herdr server`.")
    return false
  end

  local ready = vim.wait(5000, server_ready, 50)
  if ready ~= 1 then
    Util.error({
      "Herdr server did not become ready.",
      "Tried `herdr status server` and `herdr server`.",
    })
    return false
  end
  return true
end

---@param cmd string[]
local function add_env(cmd, tool)
  local env = vim.tbl_extend("force", {}, tool.config and tool.config.env or {}, tool.env or {})
  for key, value in pairs(env) do
    if value ~= false then
      vim.list_extend(cmd, { "--env", ("%s=%s"):format(key, tostring(value)) })
    end
  end
end

---@param pane_id string
local function close_pane(pane_id)
  Util.exec({ "herdr", "pane", "close", pane_id }, { notify = false })
end

local function attach_cmd(terminal_id)
  return {
    cmd = { "herdr", "terminal", "attach", terminal_id, "--takeover" },
    env = {
      HERDR_ENV = false,
      HERDR_PANE_ID = false,
      HERDR_TAB_ID = false,
      HERDR_WORKSPACE_ID = false,
    },
  }
end

---@return sidekick.cli.session.State[]
function M.sessions()
  local panes = records(json({ "herdr", "pane", "list" }), "panes")
  local tools = Config.tools()
  local ret = {} ---@type sidekick.cli.session.State[]

  for _, listed in ipairs(panes) do
    local listed_pane = pane_record(listed)
    if listed_pane.pane_id and listed_pane.terminal_id then
      local response = json({ "herdr", "pane", "get", listed_pane.pane_id })
      local pane = pane_record(record(response, "pane") or listed)
      if pane.pane_id and pane.terminal_id then
        local processes = pane_processes(pane)
        local pids = {}
        for _, process in ipairs(processes) do
          pids[#pids + 1] = process.pid
        end
        vim.list_extend(pids, attached_pids(pane.terminal_id))

        for _, process in ipairs(processes) do
          for _, tool in pairs(tools) do
            if tool:is_proc(process) then
              ret[#ret + 1] = {
                id = "herdr: " .. pane.terminal_id,
                cwd = process.cwd or pane.foreground_cwd or pane.cwd,
                tool = tool,
                herdr_pane_id = pane.pane_id,
                herdr_terminal_id = pane.terminal_id,
                herdr_workspace_id = pane.workspace_id,
                herdr_tab_id = pane.tab_id,
                mux_session = pane.terminal_id,
                pids = pids,
              }
              break
            end
          end
        end
      end
    end
  end

  return ret
end

function M:init()
  self.priority = 50
  self.external = false
end

function M:is_running()
  if not self.herdr_pane_id or not self.herdr_terminal_id then
    return false
  end
  local response = json({ "herdr", "pane", "get", self.herdr_pane_id })
  local pane = pane_record(record(response, "pane") or {})
  if pane.terminal_id ~= self.herdr_terminal_id then
    return false
  end
  for _, process in ipairs(pane_processes(pane)) do
    if self.tool:is_proc(process) then
      return true
    end
  end
  return false
end

function M:attach()
  return self.herdr_terminal_id and attach_cmd(self.herdr_terminal_id) or nil
end

function M:start()
  if self.herdr_terminal_id then
    return self:attach()
  end

  if Config.cli.mux.create ~= "terminal" then
    Util.warn({
      ("Herdr does not support `opts.cli.mux.create = %q`."):format(Config.cli.mux.create),
      "Falling back to `terminal`.",
      "Please update your config.",
    })
  end

  if not ensure_server() then
    return
  end

  local workspace_id
  local tab_id
  local pane_id
  local workspaces = records(json({ "herdr", "workspace", "list" }, { notify = true }), "workspaces")
  for _, workspace in ipairs(workspaces) do
    local cwd = workspace.cwd or workspace.path
    if cwd and vim.fs.normalize(cwd) == vim.fs.normalize(self.cwd) then
      workspace_id = workspace.workspace_id or workspace.id
      break
    end
  end

  if workspace_id then
    local cmd = {
      "herdr",
      "tab",
      "create",
      "--workspace",
      workspace_id,
      "--cwd",
      self.cwd,
      "--label",
      self.tool.name,
      "--no-focus",
    }
    add_env(cmd, self.tool)
    local response = json(cmd, { notify = true })
    local tab = record(response, "tab")
    local root_pane = record(response, "root_pane")
    tab_id = tab and (tab.tab_id or tab.id)
    pane_id = root_pane and (root_pane.pane_id or root_pane.id)
  else
    local cmd = {
      "herdr",
      "workspace",
      "create",
      "--cwd",
      self.cwd,
      "--label",
      self.tool.name,
      "--no-focus",
    }
    add_env(cmd, self.tool)
    local response = json(cmd, { notify = true })
    local workspace = record(response, "workspace")
    local tab = record(response, "tab")
    local root_pane = record(response, "root_pane")
    workspace_id = workspace and (workspace.workspace_id or workspace.id)
    tab_id = tab and (tab.tab_id or tab.id)
    pane_id = root_pane and (root_pane.pane_id or root_pane.id)
  end

  if not workspace_id or not pane_id then
    Util.error("Herdr did not return the workspace or root pane ID.")
    return
  end

  local run = { "herdr", "pane", "run", pane_id }
  vim.list_extend(run, self.tool.cmd)
  if not Util.exec(run, { notify = true }) then
    close_pane(pane_id)
    return
  end

  local response = json({ "herdr", "pane", "get", pane_id }, { notify = true })
  local pane = pane_record(record(response, "pane") or {})
  if not pane.terminal_id then
    close_pane(pane_id)
    Util.error("Herdr did not return a terminal ID for the new pane.")
    return
  end

  self.herdr_pane_id = pane.pane_id or pane_id
  self.herdr_terminal_id = pane.terminal_id
  self.herdr_workspace_id = pane.workspace_id or workspace_id
  self.herdr_tab_id = pane.tab_id or tab_id
  self.mux_session = self.herdr_terminal_id
  self.started = true
  return self:attach()
end

function M:send(text_value)
  if self.herdr_pane_id then
    Util.exec({ "herdr", "pane", "send-text", self.herdr_pane_id, text_value }, { notify = true })
  end
end

function M:submit()
  if self.herdr_pane_id then
    Util.exec({ "herdr", "pane", "send-keys", self.herdr_pane_id, "enter" }, { notify = true })
  end
end

function M:dump()
  if not self.herdr_pane_id then
    return
  end
  return text({
    "herdr",
    "pane",
    "read",
    self.herdr_pane_id,
    "--source",
    "recent-unwrapped",
    "--lines",
    tostring(Config.cli.mux.dump),
  }, { notify = false })
end

function M:detach() end

return M
