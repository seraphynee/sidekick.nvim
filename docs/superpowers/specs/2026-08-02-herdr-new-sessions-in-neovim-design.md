# Herdr new sessions in Neovim

## Goal

When Herdr is the configured multiplexer backend and no existing agent session
is selected, Sidekick must start the agent directly in its Neovim terminal. It
must not create a Herdr workspace, tab, or pane for that new agent.

Existing agents discovered in Herdr remain external sessions. Selecting one
continues attaching Sidekick logically and sending input to its Herdr pane in
the background.

## Behavior

The Herdr backend has two distinct paths:

- A new, unstarted tool returns the tool command and environment to Sidekick's
  generic session layer. The generic layer wraps that command in the existing
  Neovim terminal backend and starts it there.
- A discovered Herdr agent remains external. Attaching it does not create a
  Neovim terminal and continues using the existing Herdr pane operations.

A directly started agent is not managed or persisted by Herdr. It exits when
its Neovim terminal process exits, including when Neovim closes. It is
subsequently represented by Sidekick's terminal backend rather than discovered
as a Herdr session.

## Implementation boundary

Change `sidekick.cli.session.herdr:start()` so a new session returns the tool's
command and environment immediately. It must not:

- start or query the Herdr server;
- list, create, or inspect Herdr workspaces, tabs, or panes;
- run the tool through `herdr pane run`; or
- attach to a Herdr terminal.

The generic session orchestrator already converts a backend command into a
`sidekick.cli.Terminal`, so it needs no Herdr-specific logic. Existing Herdr
discovery, external attachment, input, status, and scrollback behavior remains
unchanged.

The obsolete new-pane lifecycle helpers and state assignments may be removed
when they no longer have callers. Backend fields required for discovered Herdr
sessions remain intact.

## Command and environment flow

For a new tool:

1. Sidekick creates an unstarted session using the configured `herdr` backend.
2. `Herdr:start()` returns a terminal command containing deep copies of
   `tool.cmd` and `tool.env`. The tool's base `config.env` remains available on
   the cloned tool and is merged later by the existing terminal wrapper.
3. `Session.attach()` creates the child terminal session and starts it inside
   Neovim.
4. All later input and submit operations use the terminal backend.

The returned command must preserve the configured tool command and environment
without mutating either table. Terminal startup remains responsible for
combining the tool environment with Sidekick's standard terminal environment
and reporting executable or startup failures.

## Error handling

Starting a new agent performs no Herdr API calls, so Herdr server availability
does not affect this path. Failures to execute the agent are reported through
the existing Neovim terminal startup errors.

Discovered Herdr sessions retain their current error behavior for pane lookup,
input, and scrollback operations.

## Testing

Session tests will verify that:

- starting a new Herdr-backed session returns the agent command and
  environment directly;
- the start path makes no Herdr CLI calls;
- `Session.attach()` runs that command through the terminal backend;
- command and environment inputs are not mutated;
- discovered Herdr agents remain external and continue using background pane
  input; and
- existing discovery, health, status, and scrollback coverage remains green.

## Non-goals

- Adding a configuration switch between direct and persistent new sessions.
- Creating a hidden or headless Herdr terminal, which Herdr 0.7.5 does not
  expose through its CLI or socket API.
- Falling back to a new Herdr tab when direct terminal startup fails.
- Changing how existing Herdr agents are discovered, selected, or attached.
