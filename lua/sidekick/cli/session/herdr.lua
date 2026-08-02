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
  local response = json({ "herdr", "pane", "process-info", "--pane", pane.pane_id })
  local result = response and response.result
  if type(result) ~= "table" then
    return {}
  end
  local info = type(result.process_info) == "table" and result.process_info or result
  local raw = info.foreground_processes or info.processes
  if type(raw) ~= "table" and type(info.foreground_process) == "table" then
    raw = { info.foreground_process }
  elseif type(raw) == "table" and raw.pid then
    raw = { raw }
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

        local matched = false
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
              matched = true
              break
            end
          end
          if matched then
            break
          end
        end
      end
    end
  end

  return ret
end

function M:init()
  self.external = self.started and self.herdr_pane_id ~= nil or false
  self.priority = self.external and 10 or 50
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

function M:attach() end

---@return sidekick.cli.terminal.Cmd
function M:start()
  return {
    cmd = vim.deepcopy(self.tool.cmd),
    env = vim.deepcopy(self.tool.env),
  }
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
