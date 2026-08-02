---@module 'luassert'

local Config = require("sidekick.config")
local Health = require("sidekick.health")

describe("health check", function()
  local orig_clients
  local orig_executable
  local orig_has
  local orig_backend
  local orig_enabled
  local reporter_values

  local function install_reporters(reports)
    reporter_values = {}
    local reporter_names = { start = true, ok = true, warn = true, error = true }
    for index = 1, 20 do
      local name, value = debug.getupvalue(Health.check, index)
      if not name then
        break
      end
      if reporter_names[name] then
        reporter_values[#reporter_values + 1] = { index = index, name = name, value = value }
        debug.setupvalue(Health.check, index, function(message)
          reports[#reports + 1] = { name = name, message = message }
        end)
      end
    end
  end

  local function has_report(reports, name, message)
    for _, report in ipairs(reports) do
      if report.name == name and report.message == message then
        return true
      end
    end
    return false
  end

  before_each(function()
    orig_clients = Config.get_clients
    orig_executable = vim.fn.executable
    orig_has = vim.fn.has
    orig_backend = Config.cli.mux.backend
    orig_enabled = Config.cli.mux.enabled
    Config.get_clients = function()
      return {}
    end
    Config.cli.mux.enabled = true
  end)

  after_each(function()
    Config.get_clients = orig_clients
    vim.fn.executable = orig_executable
    vim.fn.has = orig_has
    Config.cli.mux.backend = orig_backend
    Config.cli.mux.enabled = orig_enabled
    for _, reporter in ipairs(reporter_values or {}) do
      debug.setupvalue(Health.check, reporter.index, reporter.value)
    end
  end)

  local function run(opts)
    local reports = {}
    local installed = opts.installed
    local windows = opts.windows
    Config.cli.mux.backend = "herdr"
    vim.fn.executable = function(name)
      return installed and name == "herdr" and 1 or 0
    end
    vim.fn.has = function(name)
      if name == "nvim-0.11.2" then
        return 1
      elseif name == "win32" then
        return windows and 1 or 0
      end
      return orig_has(name)
    end
    install_reporters(reports)
    Health.check()
    return reports
  end

  it("reports an installed Herdr backend", function()
    local reports = run({ installed = true, windows = false })
    assert.is_true(has_report(reports, "ok", "`herdr` is installed"))
  end)

  it("reports a missing configured Herdr backend", function()
    local reports = run({ installed = false, windows = false })
    assert.is_true(has_report(reports, "error", "Multiplexer backend `herdr` is not installed"))
  end)

  it("reports Herdr as unsupported on Windows", function()
    local reports = run({ installed = true, windows = true })
    assert.is_true(has_report(reports, "error", "Multiplexer backend `herdr` is not supported on Windows"))
  end)
end)
