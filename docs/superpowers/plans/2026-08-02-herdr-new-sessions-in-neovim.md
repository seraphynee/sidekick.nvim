# Herdr New Sessions in Neovim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start new Herdr-backed tools directly in a Sidekick Neovim terminal without creating any Herdr workspace, tab, or pane.

**Architecture:** Keep Herdr discovery and external-session operations unchanged. Make the unstarted Herdr session return the tool command to the generic session orchestrator, which already wraps backend commands in `sidekick.cli.Terminal`; remove the now-dead Herdr pane-creation lifecycle.

**Tech Stack:** Lua, Neovim job/terminal APIs, `mini.test`, Stylua

## Global Constraints

- Existing agents discovered in Herdr remain external sessions.
- A new direct terminal session is not persisted by Herdr and exits with its Neovim terminal process.
- Starting a new agent must not query or mutate Herdr server, workspace, tab, or pane state.
- Do not add a configuration option or change the generic session orchestrator.
- Keep the change scoped to `lua/sidekick/cli/session/herdr.lua` and `tests/session_spec.lua`.

---

### Task 1: Route new Herdr-backed tools into Neovim

**Files:**
- Modify: `tests/session_spec.lua:6-370`
- Modify: `lua/sidekick/cli/session/herdr.lua:133-377`

**Interfaces:**
- Consumes: `Session.attach(session)` and its existing `{ cmd: string[], env?: table<string, string|false> }` backend command contract.
- Produces: `Herdr:start(): sidekick.cli.terminal.Cmd` containing independent copies of `self.tool.cmd` and `self.tool.env`.

- [ ] **Step 1: Replace the old Herdr creation test with failing direct-start tests**

Remove `lifecycle_fixture()`, the test named `creates a Herdr tab and returns a direct attach command`, and the obsolete create-mode warning test. Add one backend-contract test and one orchestrator test.

The backend-contract test must use a Herdr exec fake that returns valid JSON but records every attempted command, so the old implementation fails through assertions without starting a real Herdr server:

```lua
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
```

For the orchestrator test, save and restore `Terminal.init`, `Terminal.start`, and `Terminal.terminals` in the describe block's existing hooks. Stub only terminal allocation and job startup so `Session.attach()` and both real backend classes still execute:

```lua
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
```

Before writing the tests, name the protected regression: restoring any Herdr server/workspace/tab/pane call to the new-session path must fail at least one test.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua
```

Expected: both new tests fail because the current implementation calls Herdr and does not return or wrap the raw agent command. There must be no real Herdr process or resource mutation because `Util.exec` is replaced by the controlled fake.

- [ ] **Step 3: Implement the minimal direct-start behavior**

Replace `Herdr:start()` with the backend command contract:

```lua
---@return sidekick.cli.terminal.Cmd
function M:start()
  return {
    cmd = vim.deepcopy(self.tool.cmd),
    env = vim.deepcopy(self.tool.env),
  }
end
```

Do not modify `Session.attach()`. The returned command must flow through its existing terminal-wrapper branch.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua
```

Expected: all tests in `tests/session_spec.lua` pass, including discovery and external attachment.

- [ ] **Step 5: Remove dead Herdr creation code while green**

Delete these helpers from `lua/sidekick/cli/session/herdr.lua`, since no remaining production path calls them:

```lua
server_ready
ensure_server
add_env
close_pane
attach_cmd
```

Simplify the now-commandless attach hook to:

```lua
function M:attach() end
```

Remove test hook state used only by the deleted create-mode warning test:

```lua
orig_create
orig_warn
Config.cli.mux.create save/restore
Util.warn save/restore
```

Retain `herdr_workspace_id` and `herdr_tab_id` fields because discovery still records external Herdr metadata.

- [ ] **Step 6: Format and run focused regression tests**

Run:

```bash
stylua lua/sidekick/cli/session/herdr.lua tests/session_spec.lua
LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua
```

Expected: formatting succeeds and every focused test passes.

- [ ] **Step 7: Run full verification**

Run:

```bash
LAZY_OFFLINE=1 ./scripts/test
stylua --check lua tests
selene lua tests
git diff --check
```

Expected: the full MiniTest suite passes; Stylua, Selene, and whitespace checks report no errors. If `selene` is unavailable, record that explicitly and rely on the other three checks.

- [ ] **Step 8: Commit the implementation**

```bash
git add lua/sidekick/cli/session/herdr.lua tests/session_spec.lua
git commit -m "fix(cli): start new Herdr tools in Neovim"
```
