#!/usr/bin/env python3
"""agentbar: live status for Claude Code sessions on macOS.

Subcommands:
  hook              Called by Claude Code hooks (reads event JSON on stdin).
  menu              Prints SwiftBar menu-bar output.
  focus             Jumps to the session that needs you most
                    (oldest waiting-for-approval, then errors, then latest finished).
  focus-sid <id>    Jumps to a specific session.
  seen              Marks all finished sessions as seen.

State lives in ~/.claude/agentbar/sessions/<session_id>.json
Optional overrides in ~/.claude/agentbar/config.json
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

BASE = os.path.expanduser("~/.claude/agentbar")
STATE_DIR = os.path.join(BASE, "sessions")
CONFIG_PATH = os.path.join(BASE, "config.json")
SELF = os.path.abspath(__file__)
STALE_SECONDS = 12 * 3600

DEFAULT_CONFIG = {
    "sound_needs_input": "/System/Library/Sounds/Glass.aiff",
    "sound_done": "/System/Library/Sounds/Hero.aiff",
    "sound_error": "/System/Library/Sounds/Basso.aiff",
    "notify": True,
    # Bring the session's terminal to the front when it needs approval.
    # Off by default: stealing focus mid-typing is annoying. Use Caps+Num5 instead.
    "focus_on_needs_input": False,
}

NEEDS_INPUT_TYPES = {
    "permission_prompt",
    "elicitation_dialog",
    "elicitation_url_dialog",
    "agent_needs_input",
}

ICON = {
    "needs_input": "🔴",
    "error": "⚠️",
    "working": "⏳",
    "done": "✅",
    "idle": "◦",
}
LABEL = {
    "needs_input": "needs you",
    "error": "failed",
    "working": "working",
    "done": "finished",
    "idle": "idle",
}

DESKTOP_BUNDLE = "com.anthropic.claudefordesktop"
# Sessions run by the Claude desktop app get their app-side ID (local_...) in this variable.
# The app opens that exact session from claude://code/continue?session=<id>.
HOST_SESSION_ENV = "CLAUDE_CODE_HOST_SESSION_ID"
HOST_SESSION_RE = re.compile(r"^local_[A-Za-z0-9-]{1,64}$")

BUNDLE_BY_TERM = {
    "iTerm.app": "com.googlecode.iterm2",
    "Apple_Terminal": "com.apple.Terminal",
    "ghostty": "com.mitchellh.ghostty",
    "WarpTerminal": "dev.warp.Warp-Stable",
    "vscode": "com.microsoft.VSCode",
}


# ---------- helpers ----------

def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH) as f:
            cfg.update(json.load(f))
    except (OSError, ValueError):
        pass
    return cfg


def state_path(sid):
    safe = "".join(c for c in sid if c.isalnum() or c in "-_") or "unknown"
    return os.path.join(STATE_DIR, safe + ".json")


def read_state(sid):
    try:
        with open(state_path(sid)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_state(st):
    os.makedirs(STATE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(st, f)
    os.replace(tmp, state_path(st["session_id"]))


def delete_state(sid):
    try:
        os.remove(state_path(sid))
    except OSError:
        pass


def ps_field(pid, field):
    try:
        out = subprocess.run(
            ["ps", "-o", field + "=", "-p", str(pid)],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
        return out
    except Exception:
        return ""


def claude_pid():
    """The hook's parent is often a transient shell; walk up to the claude process."""
    pid = os.getppid()
    for _ in range(3):
        comm = os.path.basename(ps_field(pid, "comm"))
        if comm in ("sh", "bash", "zsh", "dash", "fish"):
            parent = ps_field(pid, "ppid")
            if parent.isdigit():
                pid = int(parent)
                continue
        break
    return pid


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def all_sessions():
    sessions = []
    if not os.path.isdir(STATE_DIR):
        return sessions
    now = time.time()
    for name in os.listdir(STATE_DIR):
        if not name.endswith(".json"):
            continue
        path = os.path.join(STATE_DIR, name)
        try:
            with open(path) as f:
                st = json.load(f)
        except (OSError, ValueError):
            continue
        dead = st.get("pid") and not pid_alive(st["pid"])
        stale = now - st.get("updated", 0) > STALE_SECONDS
        if dead or stale:
            try:
                os.remove(path)
            except OSError:
                pass
            continue
        sessions.append(st)
    return sessions


def osa_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def osascript(script):
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except Exception:
        return ""


def play(sound):
    if sound and os.path.exists(sound):
        try:
            subprocess.Popen(["afplay", sound], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def notify(title, message):
    message = " ".join(str(message).split())[:180]
    osascript(f"display notification {osa_str(message)} with title {osa_str(title)}")


def menu_text(s):
    """Make arbitrary text safe for a SwiftBar line: '|' starts the params section, and
    leading '-' would turn the line into a separator or a deeper submenu level."""
    s = " ".join(str(s).split()).replace("|", "│")
    return s.lstrip("-").lstrip() or "…"


def age(seconds):
    seconds = int(max(0, seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}m"


# ---------- focusing ----------

FOCUS_MISSING = 0  # could not focus anything
FOCUS_EXACT = 1    # the session's own tab is now in front
FOCUS_APP = 2      # only the app was activated; some other tab/window may be in front


def focus_session(st):
    """Bring the session to the front. Returns one of FOCUS_MISSING / FOCUS_EXACT / FOCUS_APP."""
    term = st.get("term_program", "")
    if term == "iTerm.app" and st.get("iterm_id"):
        found = osascript(f'''
tell application "iTerm2"
  activate
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if unique id of s is {osa_str(st["iterm_id"])} then
          select w
          select t
          select s
          return "found"
        end if
      end repeat
    end repeat
  end repeat
end tell
return "missing"''') == "found"
        return FOCUS_EXACT if found else FOCUS_MISSING
    if term == "Apple_Terminal" and st.get("tty"):
        found = osascript(f'''
tell application "Terminal"
  activate
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is {osa_str(st["tty"])} then
        set selected of t to true
        set index of w to 1
        return "found"
      end if
    end repeat
  end repeat
end tell
return "missing"''') == "found"
        return FOCUS_EXACT if found else FOCUS_MISSING
    bundle = st.get("bundle_id") or BUNDLE_BY_TERM.get(term)
    host_id = st.get("host_session_id", "")
    if bundle == DESKTOP_BUNDLE and HOST_SESSION_RE.match(host_id):
        try:
            subprocess.run(["open", "-b", DESKTOP_BUNDLE,
                            f"claude://code/continue?session={host_id}"],
                           capture_output=True, timeout=10)
        except Exception:
            pass
        # Opens the right conversation, but we can't confirm it from here, so A/D stay off.
        return FOCUS_APP
    if bundle:
        osascript(f"tell application id {osa_str(bundle)} to activate")
        return FOCUS_APP  # app-level focus only (desktop app, VS Code, Ghostty, Warp)
    return FOCUS_MISSING


def mark_seen(st):
    if st.get("state") == "done":
        st["state"] = "idle"
        st["since"] = time.time()
        write_state(st)


# ---------- subcommands ----------

def cmd_hook():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    event = data.get("hook_event_name", "")
    sid = data.get("session_id") or "unknown"

    if event == "SessionEnd":
        delete_state(sid)
        return

    now = time.time()
    st = read_state(sid)
    if not st:
        pid = claude_pid()
        tty = ps_field(pid, "tty")
        st = {
            "session_id": sid,
            "pid": pid,
            "tty": ("/dev/" + tty) if tty and tty != "??" else "",
            "term_program": os.environ.get("TERM_PROGRAM", ""),
            "bundle_id": os.environ.get("__CFBundleIdentifier", ""),
            "iterm_id": os.environ.get("ITERM_SESSION_ID", "").split(":")[-1],
            "state": "idle",
            "since": now,
        }
    host_id = os.environ.get(HOST_SESSION_ENV, "")
    if HOST_SESSION_RE.match(host_id):
        st["host_session_id"] = host_id  # also fills it in for sessions tracked before this existed
    cwd = data.get("cwd") or st.get("cwd") or ""
    st["cwd"] = cwd
    st["project"] = os.path.basename(cwd.rstrip("/")) or "~"
    st["updated"] = now

    old = st.get("state")
    new = old
    detail = ""
    prompt = ""  # for needs_input: "permission" (Return approves / Esc denies) or "other"

    if event == "SessionStart":
        new = "idle"
    elif event in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolBatch"):
        new = "working"
    elif event == "PermissionRequest":
        new = "needs_input"
        prompt = "permission"
        tool = data.get("tool_name", "")
        detail = f"Approve {tool}" if tool else "Waiting for approval"
    elif event == "Notification":
        ntype = data.get("notification_type", "")
        msg = data.get("message", "")
        legacy_permission = not ntype and "permission" in msg.lower()
        if ntype in NEEDS_INPUT_TYPES or legacy_permission:
            new = "needs_input"
            prompt = "permission" if ntype == "permission_prompt" or legacy_permission else "other"
            detail = msg or "Waiting for you"
        elif ntype == "idle_prompt" and old not in ("done", "needs_input"):
            new = "idle"
    elif event == "Stop":
        new = "done"
        detail = data.get("last_assistant_message", "") or "Finished"
    elif event == "StopFailure":
        new = "error"
        detail = data.get("error", "") or "Turn failed"

    if new != old:
        st["state"] = new
        st["since"] = now
        if detail:
            st["detail"] = " ".join(str(detail).split())[:200]
        elif new == "working":
            st.pop("detail", None)
        if new == "needs_input":
            st["prompt"] = prompt
        else:
            st.pop("prompt", None)
    elif new == "needs_input" and prompt == "permission" and st.get("prompt") != "permission":
        # Already waiting (e.g. on a question), and now a permission prompt is showing.
        st["prompt"] = prompt
        if detail:
            st["detail"] = " ".join(str(detail).split())[:200]
    write_state(st)

    if new != old and new in ("needs_input", "done", "error"):
        cfg = load_config()
        title = f"Claude · {st['project']}"
        if new == "needs_input":
            play(cfg["sound_needs_input"])
            if cfg["notify"]:
                notify(title, st.get("detail", "Waiting for you"))
            if cfg["focus_on_needs_input"]:
                focus_session(st)
        elif new == "done":
            play(cfg["sound_done"])
            if cfg["notify"]:
                notify(title, st.get("detail", "Finished"))
        else:
            play(cfg["sound_error"])
            if cfg["notify"]:
                notify(title, st.get("detail", "Failed"))


def priority_order(sessions):
    rank = {"needs_input": 0, "error": 1, "done": 2}
    picks = [s for s in sessions if s.get("state") in rank]
    # Waiting/errored: oldest first (been waiting longest). Done: newest first.
    picks.sort(key=lambda s: (rank[s["state"]],
                              s.get("since", 0) if s["state"] != "done" else -s.get("since", 0)))
    return picks


def cmd_focus():
    picks = priority_order(all_sessions())
    if not picks:
        play("/System/Library/Sounds/Tink.aiff")
        return
    focus_session(picks[0])
    mark_seen(picks[0])


def cmd_focus_sid(sid):
    st = read_state(sid)
    if not st:
        return 1
    result = focus_session(st)
    mark_seen(st)
    # Exit codes are read by AgentHUD: 0 = exact tab focused, 2 = only the app, 1 = failed.
    # AgentHUD only presses approve/deny keys after an exact focus.
    return {FOCUS_EXACT: 0, FOCUS_APP: 2}.get(result, 1)


def cmd_seen():
    for st in all_sessions():
        mark_seen(st)


def cmd_menu():
    sessions = all_sessions()
    counts = {}
    for s in sessions:
        counts[s.get("state", "idle")] = counts.get(s.get("state", "idle"), 0) + 1

    parts = []
    for key in ("needs_input", "error", "working", "done"):
        if counts.get(key):
            parts.append(f"{ICON[key]}{counts[key]}")
    print(" ".join(parts) if parts else "CC ◦")
    print("---")

    if not sessions:
        print("No active Claude Code sessions | color=gray")
    order = {"needs_input": 0, "error": 1, "working": 2, "done": 3, "idle": 4}
    now = time.time()
    py = sys.executable or "/usr/bin/python3"
    for s in sorted(sessions, key=lambda s: (order.get(s.get("state"), 9), -s.get("since", 0))):
        state = s.get("state", "idle")
        line = f"{ICON.get(state, '◦')} {menu_text(s.get('project', '?'))} — {LABEL.get(state, state)} {age(now - s.get('since', now))}"
        print(f"{line} | bash={py} param1={SELF} param2=focus-sid param3={s['session_id']} terminal=false refresh=true")
        if s.get("detail") and state in ("needs_input", "error", "done"):
            print(f"--{menu_text(s['detail'])[:90]} | color=gray")
    print("---")
    print(f"Jump to next that needs me | bash={py} param1={SELF} param2=focus terminal=false refresh=true")
    print(f"Mark finished as seen | bash={py} param1={SELF} param2=seen terminal=false refresh=true")


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "menu"
    code = 0
    try:
        if cmd == "hook":
            cmd_hook()
        elif cmd == "menu":
            cmd_menu()
        elif cmd == "focus":
            cmd_focus()
        elif cmd == "focus-sid" and len(args) > 1:
            code = cmd_focus_sid(args[1])
        elif cmd == "seen":
            cmd_seen()
    except Exception as e:  # never break Claude Code because of a status hook
        try:
            os.makedirs(BASE, exist_ok=True)
            with open(os.path.join(BASE, "error.log"), "a") as f:
                f.write(f"{time.ctime()} {cmd}: {e!r}\n")
        except OSError:
            pass
        code = 0 if cmd == "hook" else 1
    sys.exit(code)


if __name__ == "__main__":
    main()
