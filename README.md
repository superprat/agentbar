# agentbar

Live status for all your Claude Code sessions on macOS, so you can run several agents at once
and only look at the one that needs you.

- **Menu bar indicator** (via SwiftBar): counts of sessions that need you 🔴, failed ⚠️,
  are working ⏳ or finished ✅. Click a session to jump to its terminal tab.
- **Sounds and notifications** when a session asks for permission, finishes, or fails.
- **AgentHUD picker** (Caps Lock + Num 5): a keyboard-driven floating list of sessions.
  ↑↓ select, ↩ open the chat, **A** approve, **D** deny, esc close.

## How it works

```
Claude Code hooks ──► agentbar.py hook ──► ~/.claude/agentbar/sessions/<id>.json
                                                 │
                 SwiftBar (every 3s) ◄── agentbar.py menu
                 AgentHUD (every 1s) ◄── reads the same JSON files
```

`install.sh` registers `agentbar.py hook` for the `SessionStart`, `SessionEnd`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`,
`Stop` and `StopFailure` hooks. Each event updates one small JSON state file per session.
Sessions whose process has exited, or that haven't been touched in 12 hours, are cleaned up
automatically.

## Requirements

- macOS 13+
- Python 3 at `/usr/bin/python3` (comes with the Xcode Command Line Tools: `xcode-select --install`)
- Swift compiler (same Command Line Tools) to build AgentHUD
- [SwiftBar](https://github.com/swiftbar/SwiftBar): `brew install --cask swiftbar`
- [Karabiner-Elements](https://karabiner-elements.pqrs.org) for the Caps Lock layer (optional)

## Install

```bash
bash install.sh
```

The installer is safe to re-run. It:

1. Copies `agentbar.py` to `~/.claude/agentbar/`.
2. Builds `~/Applications/AgentHUD.app` from `hud/main.swift` (skipped if unchanged, so you
   keep its Accessibility permission).
3. Backs up `~/.claude/settings.json`, then adds the hooks (existing hooks are left alone).
4. Installs the SwiftBar plugin into your SwiftBar plugin folder.
5. Copies the Karabiner rule; enable it in Karabiner › Complex Modifications › Add rule.
6. Plays a test notification.

Restart running Claude Code sessions so they pick up the new hooks.

## Keys

Hold **Caps Lock** for the agent layer (tapping it still toggles Caps Lock):

| Key | Action |
| --- | --- |
| Caps + Num 5 | Open / close AgentHUD |
| ↑ ↓ / j k / Num 8 2 | Select a session |
| ↩ / Num Enter / O | Open that session's chat |
| A / 1 | Approve the permission prompt (presses Return in that tab) |
| D / 0 | Deny the permission prompt (presses Esc in that tab) |
| Esc | Close |

The first time you press A or D, macOS asks for Accessibility access: allow AgentHUD, then
press again.

### When A / D are available

Approve and deny send a real keystroke, so AgentHUD only offers them when it is sure where
the key will land:

- The session is on a **permission prompt** (not a question or other input).
- The session runs in **iTerm2** or **Terminal.app**, where agentbar can bring that exact
  tab to the front. In Ghostty, Warp, VS Code or the Claude desktop app it can only bring the
  app forward, so A/D are disabled there; use ↩ to open the chat instead.
- Right before pressing the key, AgentHUD re-reads the session state and cancels (with a beep)
  if the prompt was already answered.

## Commands

```bash
python3 ~/.claude/agentbar/agentbar.py menu            # SwiftBar output
python3 ~/.claude/agentbar/agentbar.py focus           # jump to the session that needs you most
python3 ~/.claude/agentbar/agentbar.py focus-sid <id>  # jump to one session
python3 ~/.claude/agentbar/agentbar.py seen            # mark finished sessions as seen
```

`focus` picks the oldest session waiting for approval, then the oldest failure, then the most
recently finished one.

## Configuration

Optional `~/.claude/agentbar/config.json`:

```json
{
  "notify": true,
  "focus_on_needs_input": false,
  "sound_needs_input": "/System/Library/Sounds/Glass.aiff",
  "sound_done": "/System/Library/Sounds/Hero.aiff",
  "sound_error": "/System/Library/Sounds/Basso.aiff"
}
```

Set a sound to `""` to silence it. `focus_on_needs_input` brings the session's terminal to the
front whenever it asks for permission (off by default, since it steals focus mid-typing).

## Troubleshooting

- Errors are logged to `~/.claude/agentbar/error.log`. The hook never blocks or fails
  Claude Code.
- A session missing from the menu: make sure it was started after installing (hooks are read
  at startup).
- A/D beep instead of acting: the session isn't on a permission prompt, isn't in iTerm2 or
  Terminal.app, or AgentHUD lacks Accessibility access (System Settings › Privacy & Security ›
  Accessibility).

## Uninstall

1. Remove the `agentbar.py hook` entries from `"hooks"` in `~/.claude/settings.json`.
2. Delete `~/.claude/agentbar` and `~/Applications/AgentHUD.app`.
3. Delete `claude-agents.3s.sh` from your SwiftBar plugin folder.
4. Remove the rule in Karabiner and delete
   `~/.config/karabiner/assets/complex_modifications/claude-code-numpad.json`.

## Layout

```
agentbar.py              hook handler, menu output, focus commands
hud/main.swift           AgentHUD picker (SwiftUI, built by install.sh)
claude-code-numpad.json  Karabiner rules for the Caps Lock layer
install.sh               installer
```
