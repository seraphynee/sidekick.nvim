# Herdr External Existing Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make discovered Herdr agent sessions accept Sidekick text in the background without opening or focusing a Neovim terminal, while preserving direct terminal attach for newly created agents.

**Architecture:** Reuse Sidekick's existing `external` session contract inside the Herdr backend. `Herdr:init()` classifies discovered pane-backed sessions as external, and `Herdr:attach()` returns no command for those sessions so the generic session layer records a logical attachment; new sessions remain non-external and continue returning the direct Herdr terminal command from `Herdr:start()`.

**Tech Stack:** Lua, Neovim APIs, Herdr CLI, mini.test, Stylua

## Global Constraints

- Reuse Sidekick's existing `external` session semantics for discovered Herdr sessions.
- Keep newly-created Herdr sessions embedded in a Neovim terminal.
- Keep background input implemented through `herdr pane send-text` and `herdr pane send-keys`.
- Do not focus or switch the target Herdr pane.
- Do not add a new configuration option or special-case the generic session orchestrator.
- Detaching an external Herdr session must only remove Sidekick's logical attachment; it must not close the pane or stop Herdr.
- Keep `lua/sidekick/cli/session/init.lua`, `lua/sidekick/cli/state.lua`, and the terminal backend unchanged.

---

## File Map

- Modify `lua/sidekick/cli/session/herdr.lua`: classify existing pane-backed sessions and decide whether attach should produce a terminal command.
- Modify `tests/session_spec.lua`: cover external classification, logical attachment, background-only input, and the retained embedded behavior for new sessions.
- No generated docs change is needed because the public configuration and API remain unchanged.

### Task 1: Route Existing Herdr Sessions Through External Attach

**Files:**
- Modify: `lua/sidekick/cli/session/herdr.lua:236-260`
- Test: `tests/session_spec.lua:3-330`

**Interfaces:**
- Consumes: `Session.new(state)` calling the backend's `init()` hook; discovered Herdr states have `started = true`, `herdr_pane_id`, and `herdr_terminal_id`.
- Consumes: `Session.attach(session)` treating a `nil` return from `session:attach()` as a logical attachment with no terminal child.
- Produces: `Herdr:init()` sets `external: boolean` and `priority: integer` (`10` external, `50` embedded).
- Produces: `Herdr:attach()` returns `sidekick.cli.terminal.Cmd?`, with `nil` for external sessions and the existing direct attach command for non-external sessions with a terminal ID.
- Preserves: `Herdr:send(text)` and `Herdr:submit()` continue invoking `herdr pane send-text` and `herdr pane send-keys ... enter`.

- [ ] **Step 1: Extend test isolation for the generic attachment registry and emitted events**

Add these saved values beside the existing locals near the top of `tests/session_spec.lua`:

```lua
  local orig_attached
  local orig_emit
```

Save them in the existing `before_each` after loading `Session`:

```lua
    orig_attached = Session._attached
    orig_emit = Util.emit
```

Restore them in the existing `after_each`:

```lua
    Util.emit = orig_emit
    Session._attached = orig_attached
```

- [ ] **Step 2: Write the failing external-session regression test**

Replace the current `attaches to an existing Herdr terminal` test with this integration-level test:

```lua
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
```

This verifies all observable boundaries in one test: initialization marks the discovered session external, `attach()` supplies no terminal command, generic attachment retains the Herdr object rather than constructing a terminal child, and input goes only through pane commands.

- [ ] **Step 3: Strengthen the existing new-session lifecycle test**

Immediately after constructing `session` in `creates a Herdr tab and returns a direct attach command`, initialize it and assert the opposite classification:

```lua
    session:init()

    assert.is_false(session.external)
    assert.are.equal(50, session.priority)
```

Keep the existing `session:start()` command assertion and Herdr lifecycle command assertion unchanged. Together they prove that an unstarted tool still creates a pane and opens `herdr terminal attach <terminal_id> --takeover` in Neovim.

- [ ] **Step 4: Run the focused test and verify the new regression fails**

Run:

```bash
LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua
```

Expected: FAIL in `attaches discovered Herdr sessions externally and sends in background` because the current `Herdr:init()` sets `external = false` and `priority = 50` for every session. The new-session lifecycle test should remain green.

- [ ] **Step 5: Implement lifecycle-based Herdr classification**

Replace `Herdr:init()` in `lua/sidekick/cli/session/herdr.lua` with:

```lua
function M:init()
  self.external = self.started and self.herdr_pane_id ~= nil or false
  self.priority = self.external and 10 or 50
end
```

The explicit pane check confines external behavior to sessions discovered with usable Herdr pane metadata. An unstarted session receives `external = false`; when `start()` later sets `started = true`, its initialized `external` value remains false so the same call can still return the direct terminal attach command.

- [ ] **Step 6: Suppress direct terminal attach for external sessions**

Replace `Herdr:attach()` with:

```lua
function M:attach()
  if self.external or not self.herdr_terminal_id then
    return
  end
  return attach_cmd(self.herdr_terminal_id)
end
```

Do not change `Herdr:start()`, `Herdr:send()`, `Herdr:submit()`, or generic `Session.attach()`. A newly created non-external Herdr session still reaches `attach_cmd()` from `start()`, while a discovered external session returns `nil` before any Neovim terminal can be created.

- [ ] **Step 7: Format and run focused verification**

Run:

```bash
stylua lua tests
LAZY_OFFLINE=1 ./scripts/test tests/session_spec.lua tests/health_spec.lua
git diff --check
```

Expected: Stylua completes without error, all session and health specs pass, and `git diff --check` prints no output.

- [ ] **Step 8: Run the complete test suite**

Run:

```bash
LAZY_OFFLINE=1 ./scripts/test
```

Expected: PASS in an environment with the repository's tree-sitter test dependency installed. In the current environment, if the seven pre-existing `textobject_spec.lua` failures reproduce because the `tree-sitter` executable is unavailable, record that unchanged baseline and require every other spec plus the focused session/health run to pass.

- [ ] **Step 9: Review the final diff and commit**

Run:

```bash
git diff -- lua/sidekick/cli/session/herdr.lua tests/session_spec.lua
git status --short
git add lua/sidekick/cli/session/herdr.lua tests/session_spec.lua
git commit -m "fix(cli): keep existing Herdr panes external"
```

Expected: the diff contains only the Herdr classification/attach guard and its regression coverage; the commit completes successfully.
