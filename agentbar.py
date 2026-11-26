#!/usr/bin/env python3
"""agentbar: live status for Claude Code sessions on macOS.

Subcommands:
  hook              Called by Claude Code hooks (reads event JSON on stdin).
  menu              Prints SwiftBar menu-bar output.
  focus             Jumps to the session that needs you most
                    (oldest waiting-for-approval, then errors, then latest finished).
  focus-sid <id>    Jumps to a specific session.
  seen              Marks all finished sessions as seen.
  sync              Picks up approve/deny and question prompts shown by the Claude
                    desktop app (also done by menu and focus).

State lives in ~/.claude/agentbar/sessions/<session_id>.json
Optional overrides in ~/.claude/agentbar/config.json
"""
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse

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

# Tool that fills the Claude desktop app's next-step box (question + answer buttons).
WRAP_UP_TOOL_SUFFIX = "__wrap_up"

# Hook events that start or end a turn: any desktop-app prompt from before them is over.
TURN_EDGE_EVENTS = {"SessionStart", "UserPromptSubmit", "Stop", "StopFailure"}

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

DESKTOP_SESSIONS_DIR = os.path.expanduser(
    "~/Library/Application Support/Claude/claude-code-sessions")

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


HUD_APP = os.path.expanduser("~/Applications/AgentHUD.app")
HUD_BUNDLE = "dev.agentbar.hud"


def notify(title, message, sid=""):
    """Post through AgentHUD, so clicking the notification focuses the session. Notifications
    sent with osascript belong to Script Editor, and clicking them opens Script Editor."""
    message = " ".join(str(message).split())[:180]
    if os.path.isdir(HUD_APP):
        # quote, not quote_plus: AgentHUD's URLComponents reads '+' as a literal plus.
        url = "agenthud://notify?" + urllib.parse.urlencode(
            {"sid": sid, "title": title, "body": message}, quote_via=urllib.parse.quote)
        try:
            r = subprocess.run(["open", "-g", "-b", HUD_BUNDLE, url],
                               capture_output=True, timeout=10)
            if r.returncode == 0:
                return
        except Exception:
            pass
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

FOCUSED_RE = re.compile(rb"setFocusedSession: sessionId=(\S+)")


def desktop_shows(host_id, log_offset, timeout=3.0):
    """True once the desktop app's log says it is showing `host_id`: either a new
    setFocusedSession line after `log_offset`, or (when it was already showing that chat and
    logs nothing new) the last such line before it."""
    try:
        with open(DESKTOP_LOG, "rb") as f:
            f.seek(max(0, log_offset - 256 * 1024))
            before = f.read(log_offset - max(0, log_offset - 256 * 1024))
    except OSError:
        return False
    prior = FOCUSED_RE.findall(before)
    deadline = time.time() + timeout
    while True:
        try:
            with open(DESKTOP_LOG, "rb") as f:
                f.seek(log_offset)
                new = FOCUSED_RE.findall(f.read())
        except OSError:
            new = []
        if new:
            if new[-1].decode() == host_id:
                return True
        elif prior and prior[-1].decode() == host_id and time.time() > deadline - timeout + 0.5:
            return True  # already showing it; the app logged no change
        if time.time() > deadline:
            return False
        time.sleep(0.1)


def find_host_session_id(cli_sid):
    """Look up the desktop app's local_... ID for a Claude Code session ID in the app's own
    session records (<org>/<account>/local_<id>.json, each holding a cliSessionId). Covers
    sessions whose hooks haven't run since agentbar started recording the ID."""
    needle = cli_sid.encode()
    if not cli_sid or not os.path.isdir(DESKTOP_SESSIONS_DIR):
        return ""
    for root, _dirs, files in os.walk(DESKTOP_SESSIONS_DIR):
        for name in files:
            if not (name.startswith("local_") and name.endswith(".json")):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, "rb") as f:
                    raw = f.read()
                if needle not in raw:
                    continue
                rec = json.loads(raw)
            except (OSError, ValueError):
                continue
            host_id = rec.get("sessionId", "")
            if rec.get("cliSessionId") == cli_sid and HOST_SESSION_RE.match(host_id):
                return host_id
    return ""


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
    if bundle == DESKTOP_BUNDLE and not HOST_SESSION_RE.match(host_id):
        host_id = find_host_session_id(st.get("session_id", ""))
        if host_id:
            st["host_session_id"] = host_id
            write_state(st)
    if bundle == DESKTOP_BUNDLE and HOST_SESSION_RE.match(host_id):
        try:
            log_size = os.path.getsize(DESKTOP_LOG)
        except OSError:
            log_size = 0
        try:
            subprocess.run(["open", "-b", DESKTOP_BUNDLE,
                            f"claude://code/continue?session={host_id}"],
                           capture_output=True, timeout=10)
        except Exception:
            return FOCUS_MISSING
        # The app logs which conversation it is showing; only that confirms the exact chat.
        return FOCUS_EXACT if desktop_shows(host_id, log_size) else FOCUS_APP
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
        choice = st.get("pending_choice")
        if choice:
            # The turn ended on a question with answer buttons (the desktop app's next-step box).
            new = "needs_input"
            prompt = "choice"
            detail = choice.get("ask", "")  # the answers stay in pending_choice["options"]

    if event == "PostToolUse" and data.get("tool_name", "").endswith(WRAP_UP_TOOL_SUFFIX):
        # Claude Code desktop's next-step box: a question plus buttons, shown when the turn
        # ends. It is app UI, not a Claude Code prompt, so no prompt hook fires for it.
        tin = data.get("tool_input") or {}
        ask = str(tin.get("ask") or "").strip()
        if ask:
            labels = [str(a.get("label") or a.get("action") or "").strip()
                      for a in tin.get("actions") or [] if isinstance(a, dict)]
            st["pending_choice"] = {"ask": ask, "options": [l for l in labels if l]}
        else:
            st.pop("pending_choice", None)
    elif event == "StopFailure":
        new = "error"
        detail = data.get("error", "") or "Turn failed"

    if event in TURN_EDGE_EVENTS:
        # A desktop-app prompt logged before this can't still be open (see sync_desktop_prompts).
        st["turn_edge"] = now
        st.pop("desktop_request", None)
        if event != "Stop":  # a new turn means the next-step question was answered
            st.pop("pending_choice", None)
    elif st.get("desktop_request") and old == "needs_input":
        # The desktop app is showing a prompt for this session. Tool events from parallel tool
        # calls don't answer it; the app logs the answer, and sync_desktop_prompts clears it.
        new = old

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

    if new != old:
        alert(st, new)


def alert(st, new):
    """Sound / notification / optional focus for a session that just entered `new`."""
    if new in ("needs_input", "done", "error"):
        cfg = load_config()
        title = f"Claude · {st.get('project', '?')}"
        if new == "needs_input":
            play(cfg["sound_needs_input"])
            if cfg["notify"]:
                notify(title, st.get("detail", "Waiting for you"), st.get("session_id", ""))
            if cfg["focus_on_needs_input"]:
                focus_session(st)
        elif new == "done":
            play(cfg["sound_done"])
            if cfg["notify"]:
                notify(title, st.get("detail", "Finished"), st.get("session_id", ""))
        else:
            play(cfg["sound_error"])
            if cfg["notify"]:
                notify(title, st.get("detail", "Failed"), st.get("session_id", ""))


# ---------- Claude desktop app prompts ----------
#
# The desktop app shows approve/deny and question prompts itself, so Claude Code's
# PermissionRequest / Notification hooks never fire for them. The app does log them:
#   2026-11-24 16:10:18 [info] Emitted tool permission request <req> for <Tool> in session local_...
#   2026-11-24 16:10:49 [info] Received permission response for <req>: once (tool: <Tool>)
# sync_desktop_prompts() reads new log lines (from the menu refresh, focus commands and the
# HUD) and moves the matching session to / from needs_input.

DESKTOP_LOG = os.path.expanduser("~/Library/Logs/Claude/main.log")
DESKTOP_CURSOR = os.path.join(BASE, "desktop-log-cursor.json")
FIRST_SCAN_BYTES = 256 * 1024
EMIT_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d).*Emitted tool permission request "
                     r"([A-Za-z0-9-]+) for (\S+) in session (local_[A-Za-z0-9-]{1,64})")
RESPONSE_RES = (re.compile(r"Received permission response for ([A-Za-z0-9-]+)"),
                re.compile(r"respondToToolPermission: requestId=([A-Za-z0-9-]+)"))


def read_new_log_lines():
    """New complete lines of the app log since the last call. Handles rotation (main.log is
    renamed to main1.log at ~10 MB) by starting over on a new file or a shrunk one."""
    try:
        stat = os.stat(DESKTOP_LOG)
    except OSError:
        return []
    try:
        with open(DESKTOP_CURSOR) as f:
            cur = json.load(f)
    except (OSError, ValueError):
        cur = None
    if cur is None:
        offset = max(0, stat.st_size - FIRST_SCAN_BYTES)
    elif cur.get("inode") != stat.st_ino or cur.get("offset", 0) > stat.st_size:
        offset = 0
    else:
        offset = cur.get("offset", 0)
    with open(DESKTOP_LOG, "rb") as f:
        f.seek(offset)
        chunk = f.read()
    end = chunk.rfind(b"\n") + 1  # leave a half-written last line for next time
    os.makedirs(BASE, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=BASE, suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump({"inode": stat.st_ino, "offset": offset + end}, f)
    os.replace(tmp, DESKTOP_CURSOR)
    return chunk[:end].decode("utf-8", "replace").splitlines()


def state_for_host_id(host_id, sessions):
    for st in sessions:
        if st.get("host_session_id") == host_id:
            return st
    # Not recorded yet: the app's record for this chat names its Claude Code session.
    for root, _dirs, files in os.walk(DESKTOP_SESSIONS_DIR):
        if host_id + ".json" in files:
            try:
                with open(os.path.join(root, host_id + ".json")) as f:
                    cli_sid = json.load(f).get("cliSessionId", "")
            except (OSError, ValueError):
                return None
            st = read_state(cli_sid) if cli_sid else None
            if st:
                st["host_session_id"] = host_id
            return st
    return None


def sync_desktop_prompts():
    try:
        import fcntl
        lock = open(os.path.join(BASE, "desktop-log.lock"), "w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return  # another agentbar process is syncing right now
    try:
        lines = read_new_log_lines()
        if not lines:
            return
        pending = {}   # request id -> (time, tool, host id), in log order
        answered = set()
        for line in lines:
            m = EMIT_RE.search(line)
            if m:
                pending[m.group(2)] = (m.group(1), m.group(3), m.group(4))
                continue
            for rx in RESPONSE_RES:
                r = rx.search(line)
                if r:
                    pending.pop(r.group(1), None)
                    answered.add(r.group(1))
                    break

        sessions = all_sessions()
        now = time.time()
        for st in sessions:
            if st.get("desktop_request") in answered and st.get("state") == "needs_input":
                st.pop("desktop_request", None)
                st.pop("prompt", None)
                st.pop("detail", None)
                st["state"] = "working"
                st["since"] = now
                write_state(st)

        for req, (stamp, tool, host_id) in pending.items():
            st = state_for_host_id(host_id, sessions)
            if not st or st.get("desktop_request") == req:
                continue
            try:
                emitted = time.mktime(time.strptime(stamp, "%Y-%m-%d %H:%M:%S"))
            except ValueError:
                continue
            # A new prompt or end of turn came after this, so it was answered or cancelled.
            if emitted < st.get("turn_edge", 0) - 1:
                continue
            # Sessions tracked before turn_edge existed: don't revive long-gone prompts.
            if "turn_edge" not in st and emitted < now - 1800:
                continue
            was_waiting = st.get("state") == "needs_input"
            st["desktop_request"] = req
            st["state"] = "needs_input"
            if tool == "AskUserQuestion":
                st["prompt"] = "other"
                st["detail"] = "Question waiting for your answer"
            else:
                st["prompt"] = "permission"
                st["detail"] = f"Approve {tool}"
            if not was_waiting:
                st["since"] = now
            write_state(st)
            if not was_waiting:
                alert(st, "needs_input")
    finally:
        lock.close()


def priority_order(sessions):
    rank = {"needs_input": 0, "error": 1, "done": 2}
    picks = [s for s in sessions if s.get("state") in rank]
    # Waiting/errored: oldest first (been waiting longest). Done: newest first.
    picks.sort(key=lambda s: (rank[s["state"]],
                              s.get("since", 0) if s["state"] != "done" else -s.get("since", 0)))
    return picks


# ---------- recent Claude chats (desktop app) ----------
#
# The app keeps no chat list on disk, but it caches recently used chats in its claude.ai
# IndexedDB, a LevelDB database: one record per chat with conversationUuid, product ("hub"
# for chats), lastOpenedAt / conversationUpdatedAt, and often the messages. Values are V8
# serialized (strings readable as bytes); large ones are snappy-compressed. The minimal
# read-only LevelDB + snappy reader below needs no third-party packages.

CHAT_DB = os.path.expanduser(
    "~/Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb")
CHATS_CACHE = os.path.join(BASE, "chats-cache.json")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _varint(b, i):
    n = sh = 0
    while True:
        c = b[i]
        i += 1
        n |= (c & 0x7F) << sh
        sh += 7
        if c < 0x80:
            return n, i


def _snappy(b):
    _n, i = _varint(b, 0)
    out = bytearray()
    while i < len(b):
        tag = b[i]
        i += 1
        kind = tag & 3
        if kind == 0:                      # literal
            ln = tag >> 2
            if ln >= 60:
                nb = ln - 59
                ln = int.from_bytes(b[i:i + nb], "little")
                i += nb
            ln += 1
            out += b[i:i + ln]
            i += ln
            continue
        if kind == 1:                      # copy, 1-byte offset
            ln = ((tag >> 2) & 7) + 4
            off = ((tag >> 5) << 8) | b[i]
            i += 1
        elif kind == 2:                    # copy, 2-byte offset
            ln = (tag >> 2) + 1
            off = int.from_bytes(b[i:i + 2], "little")
            i += 2
        else:                              # copy, 4-byte offset
            ln = (tag >> 2) + 1
            off = int.from_bytes(b[i:i + 4], "little")
            i += 4
        for _ in range(ln):
            out.append(out[-off])
    return bytes(out)


def _block_entries(blk):
    nrest = int.from_bytes(blk[-4:], "little")
    end = len(blk) - 4 * (nrest + 1)
    i, key = 0, b""
    while i < end:
        shared, i = _varint(blk, i)
        nonshared, i = _varint(blk, i)
        vlen, i = _varint(blk, i)
        key = key[:shared] + blk[i:i + nonshared]
        i += nonshared
        yield key, blk[i:i + vlen]
        i += vlen


def _read_block(data, off, size):
    raw = data[off:off + size]
    return _snappy(raw) if data[off + size] == 1 else raw


def _table_items(path):
    with open(path, "rb") as f:
        data = f.read()
    footer = data[-48:]
    _, j = _varint(footer, 0)
    _, j = _varint(footer, j)              # metaindex handle (unused)
    ioff, j = _varint(footer, j)
    isize, j = _varint(footer, j)
    for _k, handle in _block_entries(_read_block(data, ioff, isize)):
        off, k = _varint(handle, 0)
        size, k = _varint(handle, k)
        for ikey, val in _block_entries(_read_block(data, off, size)):
            tag = int.from_bytes(ikey[-8:], "little")
            yield ikey[:-8], tag >> 8, tag & 0xFF, val


def _log_items(path):
    with open(path, "rb") as f:
        data = f.read()
    records, buf, pos = [], b"", 0
    while pos + 7 <= len(data):
        left = 32768 - (pos % 32768)
        if left < 7:                       # block trailer
            pos += left
            continue
        ln = int.from_bytes(data[pos + 4:pos + 6], "little")
        typ = data[pos + 6]
        frag = data[pos + 7:pos + 7 + ln]
        pos += 7 + ln
        if typ == 0 and ln == 0:
            break
        if typ == 1:
            records.append(frag)
        elif typ == 2:
            buf = frag
        elif typ == 3:
            buf += frag
        elif typ == 4:
            records.append(buf + frag)
            buf = b""
    for r in records:
        if len(r) < 12:
            continue
        seq = int.from_bytes(r[:8], "little")
        i = 12
        for n in range(int.from_bytes(r[8:12], "little")):
            t = r[i]
            i += 1
            kl, i = _varint(r, i)
            key = r[i:i + kl]
            i += kl
            val = b""
            if t == 1:
                vl, i = _varint(r, i)
                val = r[i:i + vl]
                i += vl
            yield key, seq + n, t, val


def _leveldb_values(dirpath):
    """Live values of a LevelDB, newest version of each key."""
    best = {}
    for name in os.listdir(dirpath):
        path = os.path.join(dirpath, name)
        if name.endswith(".ldb"):
            items = _table_items(path)
        elif name.endswith(".log"):
            items = _log_items(path)
        else:
            continue
        try:
            for key, seq, typ, val in items:
                if key not in best or seq > best[key][0]:
                    best[key] = (seq, typ, val)
        except (IndexError, ValueError):
            continue                       # a file being written right now; skip it
    return [v for (_s, t, v) in best.values() if t == 1]


def _unwrap_idb_value(v):
    """Chrome stores large IndexedDB values snappy-compressed behind ff 11 02."""
    if len(v) < 4:
        return v
    _, i = _varint(v, 0)
    if v[i:i + 3] == b"\xff\x11\x02":
        try:
            return _snappy(v[i + 3:])
        except (IndexError, ValueError):
            return b""
    return v


def _v8_string_at(v, i):
    tag = v[i]
    n, j = _varint(v, i + 1)
    if tag == 0x22:                        # one-byte string
        return v[j:j + n].decode("latin1")
    if tag == 0x63:                        # two-byte string
        return v[j:j + n].decode("utf-16-le", "replace")
    return None


def _v8_field(v, name):
    m = re.search(b'"' + bytes([len(name)]) + name.encode(), v)
    if not m or m.end() >= len(v):
        return None
    if v[m.end()] == 0x4E:                 # 'N': double
        return struct.unpack("<d", v[m.end() + 1:m.end() + 9])[0]
    return _v8_string_at(v, m.end())


def _first_human_text(v):
    m = re.search(rb'"\x06sender"\x05human', v)
    if not m:
        return None
    t = re.search(rb'"\x04text"\x04text[\x22\x63]', v[m.end():])
    if not t:
        return None
    return _v8_string_at(v, m.end() + t.end() - 1)


def _read_recent_chats():
    chats = {}
    for raw in _leveldb_values(CHAT_DB):
        if b"conversationUuid" not in raw:
            continue
        v = _unwrap_idb_value(raw)
        cid = _v8_field(v, "conversationUuid")
        if not isinstance(cid, str) or not UUID_RE.match(cid):
            continue
        c = chats.setdefault(cid, {"id": cid})
        product = _v8_field(v, "product")
        if isinstance(product, str):
            c["product"] = product
        for f in ("conversationUpdatedAt", "lastOpenedAt"):
            x = _v8_field(v, f)
            if isinstance(x, float):
                c["last_activity"] = max(c.get("last_activity", 0), x / 1000)
        text = _first_human_text(v)
        if text:
            c["title"] = " ".join(text.split())[:120]
    return [
        {"kind": "chat", "id": c["id"], "title": c.get("title") or "Untitled chat",
         "project": "Chat", "last_activity": c["last_activity"]}
        for c in chats.values()
        if c.get("product") == "hub" and c.get("last_activity")
    ]


def recent_chats():
    """Recent Claude chats, re-read only when the app's chat cache changed on disk."""
    try:
        sig = sorted((n, os.path.getsize(os.path.join(CHAT_DB, n)),
                      int(os.path.getmtime(os.path.join(CHAT_DB, n))))
                     for n in os.listdir(CHAT_DB) if n.endswith((".ldb", ".log")))
    except OSError:
        return []
    sig = [list(s) for s in sig]
    try:
        with open(CHATS_CACHE) as f:
            cached = json.load(f)
        if cached.get("sig") == sig:
            return cached.get("chats", [])
    except (OSError, ValueError):
        pass
    chats = _read_recent_chats()
    os.makedirs(BASE, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=BASE, suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump({"sig": sig, "chats": chats}, f)
    os.replace(tmp, CHATS_CACHE)
    return chats


def cmd_open_chat(chat_id):
    if not UUID_RE.match(chat_id):
        return 1
    try:
        subprocess.run(["open", "-b", DESKTOP_BUNDLE, f"claude://claude.ai/chat/{chat_id}"],
                       capture_output=True, timeout=10)
    except Exception:
        return 1
    return 0


# ---------- recent Claude Code sessions (desktop app) ----------

RECENT_PATH = os.path.join(BASE, "recent.json")
RECENT_LIMIT = 5


def recent_code_sessions(active):
    """Recently active Claude Code sessions of the desktop app that aren't already in
    `active`, newest first. Read from the app's own session records; only the newest files
    are opened."""
    shown = {s.get("host_session_id") for s in active if s.get("host_session_id")}
    try:
        paths = []
        for root, _dirs, files in os.walk(DESKTOP_SESSIONS_DIR):
            paths += [os.path.join(root, n) for n in files
                      if n.startswith("local_") and n.endswith(".json")]
        paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    except OSError:
        return []
    out = []
    for p in paths[:RECENT_LIMIT * 6]:
        try:
            with open(p) as f:
                rec = json.load(f)
        except (OSError, ValueError):
            continue
        host_id = rec.get("sessionId", "")
        if rec.get("isArchived") or host_id in shown or not HOST_SESSION_RE.match(host_id):
            continue
        cwd = rec.get("cwd") or ""
        out.append({
            "kind": "code",
            "id": host_id,
            "title": " ".join(str(rec.get("title") or "").split())[:120] or "Untitled session",
            "project": os.path.basename(cwd.rstrip("/")) or "~",
            "last_activity": (rec.get("lastActivityAt") or 0) / 1000,
        })
        if len(out) >= RECENT_LIMIT * 2:
            break
    out.sort(key=lambda r: r["last_activity"], reverse=True)
    return out[:RECENT_LIMIT]


def recent_sessions(active):
    """One Recent list: Claude Code sessions and Claude chats together, newest first,
    RECENT_LIMIT in all. Each entry: kind ("code" / "chat"), id, title, project,
    last_activity."""
    items = recent_code_sessions(active)
    try:
        items += recent_chats()
    except Exception as e:  # the chat cache is an app internal; never break the menu over it
        try:
            with open(os.path.join(BASE, "error.log"), "a") as f:
                f.write(f"{time.ctime()} recent chats: {e!r}\n")
        except OSError:
            pass
    items.sort(key=lambda r: r["last_activity"], reverse=True)
    return items[:RECENT_LIMIT]


def write_recent(active):
    """recent.json is what AgentHUD reads for its Recent section."""
    recent = recent_sessions(active)
    os.makedirs(BASE, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=BASE, suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(recent, f)
    os.replace(tmp, RECENT_PATH)
    return recent


def cmd_open_host(host_id):
    """Open a desktop-app Claude Code session by its local_... ID (a Recent entry)."""
    if not HOST_SESSION_RE.match(host_id):
        return 1
    st = {"session_id": "", "bundle_id": DESKTOP_BUNDLE, "host_session_id": host_id}
    return 0 if focus_session(st) == FOCUS_EXACT else 2


def safe_sync():
    try:
        sync_desktop_prompts()
    except Exception as e:  # a log format change must not break the menu or focus
        try:
            with open(os.path.join(BASE, "error.log"), "a") as f:
                f.write(f"{time.ctime()} sync: {e!r}\n")
        except OSError:
            pass


def cmd_focus():
    safe_sync()
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
    safe_sync()
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
        if state == "needs_input" and s.get("prompt") == "choice":
            for i, opt in enumerate((s.get("pending_choice") or {}).get("options", [])[:9], 1):
                print(f"--{i}  {menu_text(opt)[:60]} | bash={py} param1={SELF} param2=focus-sid "
                      f"param3={s['session_id']} terminal=false refresh=true")
    try:
        recent = write_recent(sessions)
    except Exception:
        recent = []
    if recent:
        print("---")
        print("Recent | size=11 color=gray")
        for r in recent:
            icon, cmd = ("💬", "open-chat") if r["kind"] == "chat" else ("⌘", "open-host")
            line = f"{icon} {menu_text(r['title'])[:60]} — {menu_text(r['project'])} · {age(now - r['last_activity'])}"
            print(f"{line} | bash={py} param1={SELF} param2={cmd} param3={r['id']} "
                  f"terminal=false refresh=true")
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
        elif cmd == "sync":
            safe_sync()
            write_recent(all_sessions())
        elif cmd == "open-host" and len(args) > 1:
            code = cmd_open_host(args[1])
        elif cmd == "open-chat" and len(args) > 1:
            code = cmd_open_chat(args[1])
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
