# Herdr terminal multiplexer backend

Date: 2026-08-02

Status: Approved design

## Context

Sidekick already exposes a session backend abstraction for terminal, tmux, and
Zellij. A backend owns session discovery, creation, attachment, input, and
scrollback while `sidekick.cli.terminal` owns the Neovim terminal window.

Herdr is a persistent terminal workspace manager with addressable workspaces,
tabs, panes, and direct terminal attach. Its CLI and server model differs from
tmux and Zellij: a pane has a public `pane_id` such as `w1:p2`, while the
terminal stream used by direct attach has a separate `terminal_id` such as
`term_abc123`.

The desired UX is to keep the CLI terminal visible inside Neovim while Herdr
owns the persistent process. Closing or hiding the Sidekick terminal must not
stop the CLI process.

## Goals

- Add an opt-in `herdr` session backend.
- Keep the existing Sidekick terminal UI and session attachment flow.
- Persist CLI processes in Herdr after the Neovim terminal is detached.
- Support all Sidekick CLI tools, including tools that Herdr does not detect as
  a built-in agent.
- Discover existing Herdr panes after Neovim or the Herdr client restarts.
- Keep unit tests independent of a running Herdr server and network access.
- Document the backend through the existing generated configuration docs.

## Non-goals

- Implementing a raw Herdr socket client in Lua.
- Replacing the full Herdr UI inside Neovim.
- Depending exclusively on Herdr's `agent` API; generic terminal panes must
  remain supported.
- Changing the default multiplexer from tmux or Zellij to Herdr.
- Implementing Herdr direct attach support for Windows in the first version.

## Design

### Backend boundary

Add `lua/sidekick/cli/session/herdr.lua` as a normal
`sidekick.cli.Session` backend. It will use `sidekick.util.exec` and
`vim.json.decode` to run Herdr CLI commands and parse their responses. The
existing session manager remains responsible for wrapping an attach command
in a Neovim terminal session.

The backend will implement:

- `init`
- `start`
- `attach`
- `detach`
- `is_running`
- `sessions`
- `send`
- `submit`
- `dump`

`lua/sidekick/cli/session/init.lua` will register the module only when
`vim.fn.executable("herdr") == 1`. The backend is selected only when the user
sets `opts.cli.mux.backend = "herdr"`; the existing default remains unchanged.

### Herdr state

The backend session state will keep these backend-specific fields:

```lua
herdr_pane_id
herdr_terminal_id
herdr_workspace_id
herdr_tab_id
```

`mux_session` will contain `herdr_terminal_id`, because it is the target for
direct attach and the identifier used to associate a Neovim terminal with its
parent Herdr session. The pane ID remains available for pane commands and
discovery.

The IDs are runtime state, not durable Sidekick state. After a Herdr server
restart, discovery must reconstruct them from the current pane records rather
than assuming that a previous terminal ID is still valid.

### Server and workspace lifecycle

Before a pane command, the backend will:

1. Probe whether the configured Herdr server is available.
2. If it is unavailable, start `herdr server` as a detached job.
3. Poll the server status until it is ready or a bounded timeout expires.
4. Leave the server running when Neovim exits; stopping it is a user action.

For a new Sidekick session, the backend will reuse a Herdr workspace whose
working directory matches the normalized Sidekick cwd. If no workspace exists,
it will create one with that cwd. It will then create a new tab with
`--no-focus` and the tool name as its label. The tab's root pane is the tool's
dedicated pane. This avoids changing the focus or layout of an existing Herdr
workspace.

The tool command is started in the root pane with `herdr pane run`. Environment
values from the tool configuration are passed through Herdr's process-launch
environment options. Herdr-specific environment variables are cleared from
the direct attach command so that a Neovim instance running inside Herdr does
not make the attach client look like another managed pane process.

The `cli.mux.create` values `window` and `split` are not meaningful for this
embedded direct-attach model. Herdr will warn and use the `terminal` behavior
for those values.

### Attach flow

The new-session flow is:

```text
ensure Herdr server
  -> find or create workspace by cwd
  -> create a no-focus tab
  -> run the CLI command in its root pane
  -> query pane information
  -> return `herdr terminal attach <terminal_id> --takeover`
  -> Sidekick wraps that command in its Neovim terminal
```

For an existing session, `attach` returns the same direct attach command using
the discovered terminal ID. `--takeover` makes reattachment deterministic if
another direct attach client still owns input or resize authority.

The command returned from the backend is consumed by the existing
`Session.attach` implementation. No changes to `lua/sidekick/cli/terminal.lua`
are needed for the initial backend.

### Discovery flow

`sessions()` will query Herdr panes and inspect each candidate:

1. Run `herdr pane list`.
2. For each pane, query `pane get` to obtain IDs and cwd metadata.
3. Query `pane process-info` to obtain the foreground process information.
4. Convert Herdr process records into the `sidekick.cli.Proc` shape used by
   `Tool:is_proc`.
5. Match the process against all configured Sidekick tools.
6. Return only panes with a matching tool.

Discovery failures, a missing server, panes without a terminal ID, and
malformed records are ignored or reported through debug logging rather than
crashing session selection. The parent session's PID list will include enough
process information for Sidekick's existing deduplication logic. When a
Neovim terminal is already attached, the backend will associate it through
`mux_backend = "herdr"` and `mux_session = herdr_terminal_id`, following the
pattern used by the Zellij backend.

### Input, status, and scrollback

- `send(text)` uses `herdr pane send-text <pane_id> <text>` so multiline text is
  passed as one argument.
- `submit()` uses `herdr pane send-keys <pane_id> enter`.
- `is_running()` verifies that the pane still exists and still exposes the
  expected tool process.
- `dump()` uses `herdr pane read <pane_id> --source recent-unwrapped --lines N`,
  where `N` is `opts.cli.mux.dump`.
- `detach()` does not close the pane or stop its process.

The existing scrollback module can consume the text returned by `dump()` and
does not need a Herdr-specific implementation.

### Configuration and health

Update `lua/sidekick/config.lua` to:

- include `herdr` in the `cli.mux.backend` type annotation;
- accept `herdr` in backend validation;
- document that Herdr uses the `terminal` creation behavior;
- keep Herdr opt-in and preserve the current backend default.

Update `lua/sidekick/health.lua` to report Herdr installation status alongside
tmux and Zellij. When Herdr is the configured backend, a missing executable or
an unsupported platform is an error. When it is not configured, a missing
Herdr executable is informational.

The initial implementation will report direct attach as unsupported on
Windows, because Herdr documents that direct terminal attach is Unix-only.

## Error handling

- Missing `herdr`: do not register the backend; health reports the configured
  backend as unavailable.
- Server startup failure or timeout: show an actionable Sidekick error and do
  not open an attach terminal.
- Pane creation failure: return no command and preserve the original error
  context.
- Tool launch failure after creating a pane: close only the pane created by
  Sidekick, preventing an orphaned shell.
- Attach conflict: use `--takeover`; surface Herdr's stderr if attach still
  fails.
- Malformed JSON: fail the individual operation and log the command/response in
  debug mode without taking down the plugin.
- Existing pane disappears: the next status/discovery pass removes it from the
  available session list and detaches stale Sidekick state.
- Unsupported `create` mode: warn once per operation and fall back to
  `terminal`.

The backend must not stop the Herdr server as cleanup because server
persistence is the feature being added.

## Testing

Add `tests/session_spec.lua` using the existing `mini.test` style. Stub the
command runner, executable checks, job startup, and process APIs. Do not start
Herdr in unit tests.

Table-driven coverage will include:

- pane response parsing and pane/terminal ID mapping;
- conversion of Herdr process records for `Tool:is_proc`;
- discovery filtering of unrelated panes;
- attach command construction, including environment cleanup and takeover;
- new session command sequence;
- existing session attach;
- `send`, `submit`, and `dump` command construction;
- server startup and readiness timeout;
- malformed JSON and failed CLI commands;
- pane cleanup after a failed tool launch;
- deduplication between Herdr parent sessions and attached Neovim terminals;
- fallback for unsupported `create` values.

Manual verification with an installed Herdr binary will cover:

- creating a new session from Neovim;
- hiding and closing the Sidekick terminal while the CLI keeps running;
- reattaching to the same pane;
- multiple tools and working directories;
- multiline prompts and scrollback;
- an existing Herdr pane discovered after Neovim starts;
- attach controller conflicts;
- health output for installed and missing Herdr;
- Unix platform behavior.

## Documentation and verification commands

Configuration annotations remain the source of truth. After implementation,
run:

```text
./scripts/docs
./scripts/test
stylua lua tests
```

Generated README/help changes must come from the docs workflow rather than
being edited manually.

## Expected file changes

- `lua/sidekick/cli/session/herdr.lua`
- `lua/sidekick/cli/session/init.lua`
- `lua/sidekick/config.lua`
- `lua/sidekick/health.lua`
- `tests/session_spec.lua`
- generated documentation in `README.md` and `doc/sidekick.nvim.txt`

## References

- Herdr CLI reference: https://herdr.dev/docs/cli-reference/
- Herdr socket API: https://herdr.dev/docs/socket-api/
- Herdr persistence and direct attach: https://herdr.dev/docs/persistence-remote/
