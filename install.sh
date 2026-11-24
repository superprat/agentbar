#!/bin/bash
# agentbar installer: Claude Code hooks + SwiftBar menu-bar status + Karabiner jump key.
# Safe to re-run. Backs up ~/.claude/settings.json before touching it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/agentbar"
SETTINGS="$HOME/.claude/settings.json"
PY=/usr/bin/python3

if ! "$PY" -c 'import sys' 2>/dev/null; then
  echo "Python 3 not found at $PY. Run: xcode-select --install   then re-run this script."
  exit 1
fi

echo "1/4  Installing agentbar to $DEST"
mkdir -p "$DEST/sessions"
cp "$HERE/agentbar.py" "$DEST/agentbar.py"
chmod +x "$DEST/agentbar.py"

echo "1b   Building AgentHUD picker app"
APP="$HOME/Applications/AgentHUD.app"
SRC_HASH="$(shasum "$HERE/hud/main.swift" | cut -d' ' -f1)"
if [ -f "$APP/Contents/.srchash" ] && [ "$(cat "$APP/Contents/.srchash")" = "$SRC_HASH" ]; then
  echo "     unchanged, skipping rebuild (keeps your Accessibility permission)"
elif xcrun --find swiftc >/dev/null 2>&1; then
  REBUILT=1
  mkdir -p "$APP/Contents/MacOS"
  xcrun swiftc -O "$HERE/hud/main.swift" -o "$APP/Contents/MacOS/AgentHUD"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.agentbar.hud</string>
  <key>CFBundleName</key><string>AgentHUD</string>
  <key>CFBundleExecutable</key><string>AgentHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>AgentHUD focuses the terminal tab of the Claude Code session you pick.</string>
</dict>
</plist>
PLIST
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  pkill -x AgentHUD 2>/dev/null || true
  echo "$SRC_HASH" > "$APP/Contents/.srchash"
  tccutil reset Accessibility dev.agentbar.hud >/dev/null 2>&1 || true
  echo "     built $APP"
  echo "     First time you press A/D, macOS asks for Accessibility access: allow AgentHUD, then press again."
else
  echo "     Swift compiler not found. Run: xcode-select --install   then re-run this script."
fi

echo "2/4  Adding Claude Code hooks to $SETTINGS"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
"$PY" - "$SETTINGS" <<'EOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)
cmd = '/usr/bin/python3 "$HOME/.claude/agentbar/agentbar.py" hook'
events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "PermissionRequest", "Notification", "Stop", "StopFailure"]
hooks = settings.setdefault("hooks", {})
added = 0
for ev in events:
    groups = hooks.setdefault(ev, [])
    present = any(h.get("command") == cmd for g in groups for h in g.get("hooks", []))
    if not present:
        groups.append({"matcher": "", "hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
        added += 1
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print(f"     added {added} hook(s); existing hooks left untouched")
EOF

echo "3/4  Menu bar (SwiftBar)"
SWIFTBAR_APP=""
for a in "/Applications/SwiftBar.app" "$HOME/Applications/SwiftBar.app"; do
  [ -d "$a" ] && SWIFTBAR_APP="$a" && break
done
PLUGDIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
PLUGDIR="${PLUGDIR/#\~/$HOME}"
# An earlier version of this script picked SwiftBar's own data folder, which SwiftBar fills
# with per-plugin data folders. Move off it.
BAD_PLUGDIR="$HOME/Library/Application Support/SwiftBar/Plugins"
if [ "$PLUGDIR" = "$BAD_PLUGDIR" ]; then
  rm -f "$BAD_PLUGDIR/claude-agents.3s.sh"
  PLUGDIR=""
fi
if [ -n "$SWIFTBAR_APP" ] && { [ -z "$PLUGDIR" ] || [ ! -d "$PLUGDIR" ]; }; then
  # SwiftBar is installed but no plugin folder was chosen yet (it asks on first launch).
  # Pick one for it. Quit SwiftBar first, or it would overwrite the setting when it quits.
  PLUGDIR="$HOME/.config/swiftbar/plugins"
  osascript -e 'quit app id "com.ameba.SwiftBar"' >/dev/null 2>&1 || true
  sleep 1
  mkdir -p "$PLUGDIR"
  defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGDIR"
  echo "     set SwiftBar plugin folder to $PLUGDIR"
fi
if [ -n "$PLUGDIR" ] && [ -d "$PLUGDIR" ]; then
  cat > "$PLUGDIR/claude-agents.3s.sh" <<EOF
#!/bin/bash
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
exec /usr/bin/python3 "$DEST/agentbar.py" menu
EOF
  chmod +x "$PLUGDIR/claude-agents.3s.sh"
  echo "     plugin installed in $PLUGDIR"
  if [ -n "$SWIFTBAR_APP" ]; then
    open -a "$SWIFTBAR_APP" 2>/dev/null || true   # start it (or nudge it to rescan)
  fi
else
  echo "     SwiftBar not found. Install it:  brew install --cask swiftbar   then re-run this script."
fi

echo "4/4  Karabiner rule"
KDIR="$HOME/.config/karabiner/assets/complex_modifications"
if [ -d "$HOME/.config/karabiner" ] || [ -d "/Applications/Karabiner-Elements.app" ]; then
  mkdir -p "$KDIR"
  cp "$HERE/claude-code-numpad.json" "$KDIR/claude-code-numpad.json"
  echo "     copied. In Karabiner: Complex Modifications > Add rule > enable all three."
else
  echo "     Karabiner-Elements not found. Install it from karabiner-elements.pqrs.org, then re-run."
fi

echo
echo "Testing alert (you should hear a sound and see a notification)..."
echo '{"hook_event_name":"Stop","session_id":"agentbar-test","cwd":"'"$HOME"'/agentbar-test","last_assistant_message":"agentbar is installed"}' \
  | "$PY" "$DEST/agentbar.py" hook
sleep 1
rm -f "$DEST/sessions/agentbar-test.json"
echo "Done. Restart any running Claude Code sessions so they pick up the hooks."
