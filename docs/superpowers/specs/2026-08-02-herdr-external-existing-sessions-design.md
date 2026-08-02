# Herdr external existing sessions

## Goal

When Sidekick discovers an AI agent already running in a separate Herdr pane,
selecting that session must attach Sidekick logically without opening the pane
inside a Neovim terminal. Text and submit events are sent to the Herdr pane in
the background. A tool without an existing selected session keeps the current
behavior: Sidekick creates the Herdr pane and opens its direct terminal attach
inside Neovim.

## Scope

- Reuse Sidekick's existing `external` session semantics for discovered Herdr
  sessions.
- Keep newly-created Herdr sessions embedded in a Neovim terminal.
- Keep background input implemented through `herdr pane send-text` and
  `herdr pane send-keys`.
- Do not focus or switch the target Herdr pane.
- Do not add a new configuration option or special-case the generic session
  orchestrator.

## Session classification

`sidekick.cli.session.herdr:init()` classifies each instance from its lifecycle
state:

- A discovered session has `started = true` and Herdr pane metadata. It is
  external and receives the lower external-session priority.
- A new session has not started yet. It remains embedded and keeps the current
  embedded-session priority.

This follows the existing tmux backend pattern. It also preserves both picker
choices: an external running session does not suppress the unstarted tool entry,
so users can either target the existing pane or create a new session.

## Attach and input flow

For a discovered external session:

1. The picker returns the exact Herdr session selected by the user.
2. `Session.attach()` calls the Herdr backend's `attach()` method.
3. `Herdr:attach()` returns no terminal command for an external session.
4. The generic session layer records the backend session as attached without
   creating a terminal child.
5. Sidekick sends rendered text directly to `Herdr:send()` and optionally calls
   `Herdr:submit()`.
6. The Herdr pane remains in the background and retains its current focus state.

For a new session, `Herdr:start()` continues creating a workspace/tab/pane and
returns `herdr terminal attach <terminal_id> --takeover`. The generic session
layer therefore creates the visible Neovim terminal as it does today.

## Detach and status

Detaching an external Herdr session only removes Sidekick's logical attachment.
It does not close the pane or stop the Herdr server. Picker formatting uses the
existing external session icon and backend/session label. Running-state checks
continue using pane metadata and foreground process information.

## Testing

Tests will cover these observable behaviors:

- A discovered Herdr session initializes as external with external priority.
- Attaching a discovered session returns no terminal command.
- Sending and submitting to that attached session emits only Herdr pane input
  commands and does not start a Neovim terminal.
- A new Herdr session remains embedded and still returns the direct terminal
  attach command after creation.
- Existing lifecycle, discovery, health, and scrollback tests remain green.

The change is confined to the Herdr backend and its session tests. The generic
session orchestrator and terminal implementation remain unchanged.
