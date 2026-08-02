# Herdr Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Herdr session backend that keeps Sidekick's terminal inside Neovim while Herdr persists the CLI process.

**Architecture:** Implement a generic backend in `lua/sidekick/cli/session/herdr.lua` using Herdr's CLI commands. The backend will create or discover Herdr workspaces and tabs, run tools in Herdr panes, and return `herdr terminal attach <terminal_id> --takeover` for Sidekick's existing terminal wrapper. Discovery uses `pane list`, `pane get`, and `pane process-info`; no raw socket client is added.

**Tech Stack:** Lua, Neovim 0.11.2+, `vim.system` through `sidekick.util.exec`, Herdr CLI 0.7.x-compatible commands, `mini.test`, generated Sidekick docs.

## Global Constraints

- Preserve the existing default mux backend; Herdr is opt-in through `opts.cli.mux.backend = "herdr"`.
- Keep the existing `Config.cli.mux.enabled` gate and `Config.cli.mux.dump` scrollback limit.
- Direct terminal attach is Unix-only in the first version; Windows reports unsupported health status.
- Unit tests must stub Herdr commands and must not require a Herdr server, network, or third-party fetches.
- Use `mini.test` assertions and table-driven cases where behavior varies.
- Use `apply_patch` for Lua and test edits; generated documentation is updated by `./scripts/docs`.
- Keep Herdr server and panes running when Sidekick detaches; do not stop the server as cleanup.
- Run formatting and tests before claiming completion: `stylua lua tests`, `LAZY_OFFLINE=1 ./scripts/test`, and `./scripts/docs`.

---

## File map

- Create: `lua/sidekick/cli/session/herdr.lua` - Herdr command adapter, pane discovery, lifecycle, input, and scrollback backend.
- Modify: `lua/sidekick/cli/session/init.lua` - register Herdr when its executable is available on supported platforms.
- Modify: `lua/sidekick/config.lua` - add the `herdr` backend type, validation, and generated documentation comments.
- Modify: `lua/sidekick/health.lua` - report Herdr installation and platform support.
- Create: `tests/session_spec.lua` - backend command, parser, discovery, lifecycle, input, and error tests.
- Create: `tests/health_spec.lua` - Herdr health reporting behavior, including unsupported Windows.
- Generate: `README.md` and any generated help output touched by `./scripts/docs`.

The existing `lua/sidekick/cli/terminal.lua` remains unchanged. Its `Session.attach()` integration already accepts a backend command and creates the visible Neovim terminal child.

## Backend interfaces

The new module must preserve the session contract already used by tmux and Zellij:

```lua
M:init()
M:start() -> sidekick.cli.terminal.Cmd?
M:attach() -> sidekick.cli.terminal.Cmd?
M:detach()
M:is_running() -> boolean
M.sessions() -> sidekick.cli.session.State[]
M:send(text)
M:submit()
M:dump() -> string?
```

Backend state fields:

```lua
herdr_pane_id       -- public pane id, for example "w1:p2"
herdr_terminal_id   -- direct attach target, for example "term_abc123"
herdr_workspace_id
herdr_tab_id
mux_session         -- aliases herdr_terminal_id for Sidekick association
```

The module uses `M.priority = 50` and `M.external = false`, matching the embedded attach semantics of the Zellij backend. A discovered session's `id` is `"herdr: " .. herdr_terminal_id`; a newly-created session receives the same identity after pane information is read.

## Task 1: Add failing discovery and response-shape tests

**Files:**
- Create: `tests/session_spec.lua`
- Read: `lua/sidekick/cli/session/zellij.lua`, `lua/sidekick/cli/procs.lua`

**Interfaces:**
- Consumes: the planned public backend method `Herdr.sessions()`.
- Produces: a repeatable fake-command fixture that later tasks use for all Herdr tests.

- [ ] **Step 1: Create a command-dispatch fixture.**

Use a `before_each`/`after_each` pair to save and restore `Util.exec` and `Config.tools`. Dispatch fake responses by `table.concat(cmd, "\0")`, and return the same pair as `Util.exec`: `{ lines... }, stdout`. Include helpers with concrete shapes:

```lua
local function json(value)
  local stdout = vim.json.encode(value)
  return vim.split(stdout, "\n", { plain = true, trimempty = true }), stdout
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
```

Make the fixture return a pane list containing one Herdr pane, a pane record containing `pane_id`, `terminal_id`, `workspace_id`, `tab_id`, and `cwd`, and process information containing one foreground process with `pid`, `name`, `argv`, and `cwd`.

- [ ] **Step 2: Write the failing discovery test.**

Stub `Config.tools()` to return a `claude` tool and call `require("sidekick.cli.session.herdr").sessions()`. Assert that the result contains one state with:

```lua
assert.are.same("herdr: term_abc123", state.id)
assert.are.same("term_abc123", state.mux_session)
assert.are.same("w1:p2", state.herdr_pane_id)
assert.are.same("/repo", state.cwd)
assert.are.same("claude", state.tool.name)
```

Also assert that an unrelated pane is ignored and a pane without `terminal_id` is ignored.

- [ ] **Step 3: Run the focused test and verify it fails.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua`

Expected: FAIL because `sidekick.cli.session.herdr` does not exist yet.

- [ ] **Step 4: Commit the test fixture.**

```bash
git add tests/session_spec.lua
git commit -m "test: add Herdr backend fixtures"
```

## Task 2: Implement Herdr command helpers and discovery

**Files:**
- Create: `lua/sidekick/cli/session/herdr.lua`
- Test: `tests/session_spec.lua`

**Interfaces:**
- Consumes: the fake-command fixture and `sidekick.cli.Tool:is_proc`.
- Produces: `Herdr.sessions()`, `Herdr:is_running()`, and pane/process normalization used by lifecycle tasks.

- [ ] **Step 1: Add the module skeleton and command helpers.**

Define `M.__index = M`, `M.priority = 50`, and `M.external = false`. Add two local helpers:

```lua
local function json(cmd, opts)
  local _, stdout = Util.exec(cmd, { notify = opts and opts.notify ~= false or false })
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
  local _, stdout = Util.exec(cmd, { notify = opts and opts.notify ~= false or false })
  return stdout
end
```

Keep `notify = false` for discovery/status probes and use `notify = true` for user-triggered mutations. Add a response-record helper that accepts the documented `result` wrapper and returns the requested child record without silently inventing IDs.

- [ ] **Step 2: Normalize Herdr process records.**

Convert each process returned by `pane process-info` into the shape expected by `Tool:is_proc`:

```lua
{
  pid = process.pid,
  ppid = process.ppid or 0,
  cmd = process.cmdline or table.concat(process.argv or { process.name or "" }, " "),
  cwd = process.cwd or pane.foreground_cwd or pane.cwd,
}
```

Skip records without a numeric PID or a non-empty command. Preserve all numeric process IDs in the session `pids` list for existing Sidekick deduplication.

- [ ] **Step 3: Implement `M.sessions()`.**

Run `herdr pane list`, iterate the returned panes, then run `herdr pane get <pane_id>` and `herdr pane process-info <pane_id>` for each candidate. Match normalized processes against `Config.tools()` using `tool:is_proc(proc)`.

For a match, return:

```lua
{
  id = "herdr: " .. pane.terminal_id,
  cwd = proc.cwd or pane.foreground_cwd or pane.cwd,
  tool = tool,
  herdr_pane_id = pane.pane_id,
  herdr_terminal_id = pane.terminal_id,
  herdr_workspace_id = pane.workspace_id,
  herdr_tab_id = pane.tab_id,
  mux_session = pane.terminal_id,
  pids = process_pids,
}
```

Use `require("sidekick.cli.terminal").terminals` to append attached terminal job PIDs when `t.mux_backend == "herdr"` and `t.mux_session == pane.terminal_id`, matching the Zellij deduplication pattern.

- [ ] **Step 4: Implement `M:init()` and `M:is_running()`.**

`M:init()` sets `self.priority = 50` and `self.external = false`. `M:is_running()` calls `pane get` for `self.herdr_pane_id`, verifies that the pane still has the expected `terminal_id`, and returns whether one normalized process still satisfies `self.tool:is_proc(proc)`.

- [ ] **Step 5: Run the discovery tests and commit.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua`

Expected: the discovery and normalization tests PASS; lifecycle tests have not been added yet.

```bash
git add lua/sidekick/cli/session/herdr.lua tests/session_spec.lua
git commit -m "feat: add Herdr session discovery"
```

## Task 3: Add server readiness and new-session lifecycle

**Files:**
- Modify: `lua/sidekick/cli/session/herdr.lua`
- Test: `tests/session_spec.lua`

**Interfaces:**
- Consumes: `Herdr.sessions()` and command helpers from Task 2.
- Produces: `Herdr:start()`, `Herdr:attach()`, and a direct attach command for `Session.attach()`.

- [ ] **Step 1: Write failing lifecycle tests.**

Add fake responses and assertions for this exact command sequence when starting a new session:

```text
herdr status --json server
herdr workspace list
herdr tab create --workspace w1 --cwd /repo --label claude --no-focus
herdr pane run w1:p2 claude
herdr pane get w1:p2
```

The fake `pane get` response must return `terminal_id = "term_abc123"`. Assert that `session:start()` returns:

```lua
{
  cmd = { "herdr", "terminal", "attach", "term_abc123", "--takeover" },
  env = {
    HERDR_ENV = false,
    HERDR_PANE_ID = false,
    HERDR_TAB_ID = false,
    HERDR_WORKSPACE_ID = false,
  },
}
```

Add a test for an existing state where `session:attach()` returns the same command without creating a new tab. Add a test that `create = "split"` warns and still returns the terminal attach command.

- [ ] **Step 2: Run the lifecycle tests and verify they fail.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua`

Expected: FAIL because `start()` and `attach()` are not implemented.

- [ ] **Step 3: Implement server probing and startup.**

Add a local readiness helper that treats successful `herdr status --json server` execution as ready. If it is not ready, start:

```lua
local job = vim.fn.jobstart({ "herdr", "server" }, { detach = true })
```

Return an error if `job <= 0`. Otherwise poll with `vim.wait(5000, ready, 50)`. On timeout call `Util.error` with the commands `herdr status server` and `herdr server` in the message, then return `false`. Do not stop a server started by Sidekick.

- [ ] **Step 4: Implement workspace and tab creation.**

After readiness, run `herdr workspace list` and select the workspace whose normalized `cwd` equals `self.cwd`. If none matches, run:

```text
herdr workspace create --cwd <cwd> --label <tool.name> --no-focus
```

Use the returned root pane directly for a newly-created workspace. For an existing workspace, run:

```text
herdr tab create --workspace <workspace_id> --cwd <cwd> --label <tool.name> --no-focus
```

Extract `.result.workspace.workspace_id`, `.result.tab.tab_id`, and `.result.root_pane.pane_id` from workspace creation, or `.result.tab.tab_id` and `.result.root_pane.pane_id` from tab creation. If any required ID is missing, return an error before launching the tool.

- [ ] **Step 5: Implement environment and tool launch.**

Build repeated `--env KEY=VALUE` arguments for string/number values in `self.tool.config.env` and `self.tool.env`. Do not pass entries whose value is `false`; direct attach environment cleanup is handled separately. Add those options to workspace/tab creation, then run:

```lua
local cmd = { "herdr", "pane", "run", pane_id }
vim.list_extend(cmd, self.tool.cmd)
```

Read the pane again after `pane run`, set all Herdr state fields, set `self.mux_session = self.herdr_terminal_id`, set `self.started = true`, and return the attach command. If `pane run` or the final `pane get` fails, close only the newly-created pane with `herdr pane close <pane_id>` and return `nil`.

- [ ] **Step 6: Implement `M:attach()` and creation-mode warning.**

Return this command shape whenever `self.herdr_terminal_id` exists:

```lua
{
  cmd = { "herdr", "terminal", "attach", self.herdr_terminal_id, "--takeover" },
  env = {
    HERDR_ENV = false,
    HERDR_PANE_ID = false,
    HERDR_TAB_ID = false,
    HERDR_WORKSPACE_ID = false,
  },
}
```

In `start()`, warn when `Config.cli.mux.create ~= "terminal"` and continue with the same tab/pane workflow. `detach()` remains a no-op.

- [ ] **Step 7: Run lifecycle tests and commit.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua`

Expected: server, workspace, tab, pane, attach, cleanup, and fallback tests PASS.

```bash
git add lua/sidekick/cli/session/herdr.lua tests/session_spec.lua
git commit -m "feat: add Herdr session lifecycle"
```

## Task 4: Add input, submit, scrollback, and detach tests

**Files:**
- Modify: `tests/session_spec.lua`
- Modify: `lua/sidekick/cli/session/herdr.lua`

**Interfaces:**
- Consumes: `session.herdr_pane_id`, `Config.cli.mux.dump`, and `Util.exec`.
- Produces: stable input and scrollback methods used by picker/context actions and `sidekick.cli.scrollback`.

- [ ] **Step 1: Write failing operation tests.**

For a state with `herdr_pane_id = "w1:p2"`, assert these exact calls:

```text
herdr pane send-text w1:p2 <multiline text>
herdr pane send-keys w1:p2 enter
herdr pane read w1:p2 --source recent-unwrapped --lines 2000
```

Assert that `dump()` returns the raw stdout from `pane read`, and that `detach()` does not issue `herdr pane close` or `herdr server stop`.

- [ ] **Step 2: Run the operation tests and verify they fail.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua`

Expected: FAIL because the operation methods are not implemented.

- [ ] **Step 3: Implement `send`, `submit`, `dump`, and `detach`.**

Use `Util.exec` with notifications enabled for user-triggered input. Use Herdr key syntax `enter`, not tmux's `Enter`. For `dump`, pass `tostring(Config.cli.mux.dump)` and return the text stdout unchanged so Neovim's existing scrollback terminal can render it.

- [ ] **Step 4: Run tests and commit.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua`

Expected: all session backend tests PASS.

```bash
git add lua/sidekick/cli/session/herdr.lua tests/session_spec.lua
git commit -m "feat: support Herdr pane input and scrollback"
```

## Task 5: Register the backend and update configuration

**Files:**
- Modify: `lua/sidekick/cli/session/init.lua:118-131`
- Modify: `lua/sidekick/config.lua:84-100,224-227`
- Modify: `tests/session_spec.lua`

**Interfaces:**
- Consumes: the completed Herdr module and existing executable-based backend registration.
- Produces: selectable `backend = "herdr"` configuration without changing the default backend.

- [ ] **Step 1: Write failing registration/config tests.**

Stub `vim.fn.executable` and `vim.fn.has`, reset `Session.did_setup` and `Session.backends`, then assert that supported Unix setup registers `herdr` when the executable is present and does not register it when absent. Assert that config validation accepts `"herdr"` and that the default backend expression remains tmux/Zellij-based.

- [ ] **Step 2: Run the tests and verify they fail.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua`

Expected: FAIL because the backend map and validation list do not contain Herdr.

- [ ] **Step 3: Register Herdr conditionally.**

Extend the session backend map:

```lua
local session_backends = {
  tmux = "sidekick.cli.session.tmux",
  zellij = "sidekick.cli.session.zellij",
  herdr = "sidekick.cli.session.herdr",
}
```

Register Herdr only when `vim.fn.executable("herdr") == 1` and `vim.fn.has("win32") == 0`. Keep the unconditional terminal registration.

- [ ] **Step 4: Update configuration annotations and validation.**

Change the mux backend annotation to include `"herdr"`, update the comments to say Herdr supports the embedded `terminal` behavior, and change validation to:

```lua
M.validate("cli.mux.backend", { "tmux", "zellij", "herdr" })
```

Do not change `backend = vim.env.ZELLIJ and "zellij" or "tmux"`.

- [ ] **Step 5: Run registration tests and commit.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua`

Expected: registration and validation tests PASS.

```bash
git add lua/sidekick/cli/session/init.lua lua/sidekick/config.lua tests/session_spec.lua
git commit -m "feat: register Herdr mux backend"
```

## Task 6: Update health reporting and test platform/error behavior

**Files:**
- Modify: `lua/sidekick/health.lua:69-77`
- Create: `tests/health_spec.lua`

**Interfaces:**
- Consumes: `Config.cli.mux.backend`, `vim.fn.executable`, and `vim.fn.has`.
- Produces: clear health output for Herdr installed, missing, configured, and unsupported states.

- [ ] **Step 1: Write health tests with stubbed reporters.**

Load `sidekick.health`, replace its local `start`, `ok`, `warn`, and `error` upvalues with `debug.setupvalue`, and stub `vim.fn.executable`/`vim.fn.has`. Cover these cases:

1. Herdr installed and configured on Unix reports OK.
2. Herdr missing and configured on Unix reports an error mentioning `herdr`.
3. Herdr installed but not configured reports an informational installed/not-configured result.
4. Herdr configured on Windows reports an unsupported-platform error.

- [ ] **Step 2: Run the health tests and verify they fail.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/health_spec.lua`

Expected: FAIL because the health loop only knows tmux and Zellij.

- [ ] **Step 3: Update `health.lua`.**

Iterate over `{ "tmux", "zellij", "herdr" }`. For Herdr, check platform support before reporting installation. Use an error when Herdr is configured but unavailable or unsupported; otherwise use the existing informational wording for optional muxes.

- [ ] **Step 4: Run health and full tests, then commit.**

Run: `LAZY_OFFLINE=1 ./scripts/test tests/health_spec.lua`

Expected: all health cases PASS.

```bash
git add lua/sidekick/health.lua tests/health_spec.lua
git commit -m "feat: report Herdr health status"
```

## Task 7: Generate documentation and run verification

**Files:**
- Modify through generator: `README.md` and generated help output, if produced by the repository docs workflow.
- Read: `lua/sidekick/config.lua`, `tests/fixtures/readme.lua`, `scripts/docs`, `AGENTS.md`.

**Interfaces:**
- Consumes: the final config annotations and all backend code/tests.
- Produces: generated user-facing configuration documentation and verified working tree.

- [ ] **Step 1: Generate docs from annotations.**

Run:

```bash
./scripts/docs
```

Review the diff to confirm `herdr` appears in the mux backend type and that the comments explain the terminal-only behavior. Do not manually edit generated sections.

- [ ] **Step 2: Format Lua.**

Run:

```bash
stylua lua tests
git diff --check
```

Expected: no formatting or whitespace errors.

- [ ] **Step 3: Run the offline test suite.**

Run:

```bash
LAZY_OFFLINE=1 ./scripts/test
```

Expected: all existing and new tests PASS without a Herdr server.

- [ ] **Step 4: Run optional linting.**

If `selene` is installed, run:

```bash
selene
```

Expected: no new diagnostics in the Herdr backend or tests.

- [ ] **Step 5: Perform manual Herdr verification.**

With Herdr installed on Unix:

1. Configure `enabled = true` and `backend = "herdr"`.
2. Start a Sidekick CLI session from Neovim.
3. Confirm a Herdr workspace/tab/pane appears without stealing Herdr focus.
4. Hide and close the Sidekick terminal, then verify the CLI process remains in Herdr.
5. Reopen Sidekick and attach to the existing pane.
6. Send a multiline context prompt and open scrollback.
7. Repeat with two tools and two working directories.
8. Run `:checkhealth sidekick` with Herdr installed and missing.

- [ ] **Step 6: Review the complete diff and commit generated docs.**

Run:

```bash
git status --short
git diff --stat
git diff --check
```

Then commit the implementation and generated docs:

```bash
git add lua/sidekick/cli/session/herdr.lua lua/sidekick/cli/session/init.lua lua/sidekick/config.lua lua/sidekick/health.lua tests/session_spec.lua tests/health_spec.lua README.md doc/sidekick.nvim.txt
git commit -m "feat: add Herdr terminal multiplexer backend"
```

## Self-review checklist

- Spec coverage: backend registration/configuration is Task 5; server/workspace/tab/pane lifecycle is Task 3; discovery and deduplication are Task 2; input and scrollback are Task 4; health/platform handling is Task 6; docs and verification are Task 7.
- Placeholder scan: the plan contains no unfinished markers or unspecified implementation step.
- Type consistency: all tasks use `herdr_pane_id`, `herdr_terminal_id`, `mux_session`, `Herdr:start()`, `Herdr:attach()`, `Herdr.sessions()`, and the existing `sidekick.cli.terminal.Cmd` shape consistently.
- Scope: no raw socket client, terminal UI rewrite, default backend change, or Windows direct-attach implementation is included.
