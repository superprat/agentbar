// AgentHUD: keyboard-driven picker for Claude Code sessions tracked by agentbar.
//
// Open:     Caps Lock + Num 5 (Karabiner runs `open -a AgentHUD`). Press again to close.
// Keys:     ↑/↓ (or j/k, Num 8/2)  select
//           ↩ / Num Enter / O      open chat (focus the session)
//           A / 1                  approve (focus session, press Return on the permission prompt)
//           D / 0                  deny    (focus session, press Esc on the permission prompt)
//           Esc                    close
//
// Build:    swiftc -O main.swift -o AgentHUD   (install.sh does this and wraps it in an .app)

import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Model

struct Session: Identifiable, Decodable {
    let session_id: String
    let project: String?
    let state: String?
    let since: Double?
    let detail: String?
    let term_program: String?
    let bundle_id: String?
    let pid: Int?
    let prompt: String?
    let tty: String?
    let iterm_id: String?
    let host_session_id: String?
    let pending_choice: PendingChoice?

    struct PendingChoice: Decodable {
        let ask: String?
        let options: [String]?
    }

    var id: String { session_id }
    var st: String { state ?? "idle" }
    var needsInput: Bool { st == "needs_input" }

    /// The turn ended on a question with answer buttons (Claude desktop's next-step box).
    var choices: [String] {
        guard needsInput, prompt == "choice" else { return [] }
        return Array((pending_choice?.options ?? []).prefix(2))
    }

    /// 1/A and 2/D send an answer: the desktop app chat can be brought up exactly
    /// (agentbar confirms it from the app's log before reporting success).
    var canChoose: Bool {
        !choices.isEmpty && bundle_id == "com.anthropic.claudefordesktop"
            && !(host_session_id ?? "").isEmpty
    }

    /// agentbar can bring this session's own tab to the front (not just its app), so a
    /// key pressed afterwards lands in this session and nowhere else.
    var canTargetExactly: Bool {
        switch term_program ?? "" {
        case "iTerm.app": return !(iterm_id ?? "").isEmpty
        case "Apple_Terminal": return !(tty ?? "").isEmpty
        default: return false
        }
    }

    /// A/D are safe: it's a permission prompt (Return = approve, Esc = deny) in a tab we can target.
    var canApprove: Bool { needsInput && prompt == "permission" && canTargetExactly }

    var expectedBundle: String? {
        if let b = bundle_id, !b.isEmpty { return b }
        switch term_program ?? "" {
        case "iTerm.app": return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "vscode": return "com.microsoft.VSCode"
        default: return nil
        }
    }

    var label: String {
        switch st {
        case "needs_input": return "needs you"
        case "error": return "failed"
        case "working": return "working"
        case "done": return "finished"
        default: return "idle"
        }
    }
}

/// A recently used Claude Code session ("code", opened via claude://code/continue) or
/// Claude chat ("chat", opened via claude://claude.ai/chat/<id>), from recent.json.
struct RecentSession: Identifiable, Decodable {
    let kind: String
    let item_id: String
    let title: String
    let project: String
    let last_activity: Double

    enum CodingKeys: String, CodingKey {
        case kind, title, project, last_activity
        case item_id = "id"
    }

    var id: String { "recent:\(kind):\(item_id)" }
    var isChat: Bool { kind == "chat" }
}

func formatAge(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var recent: [RecentSession] = []
    @Published var selected: Int = 0
    @Published var now: Double = Date().timeIntervalSince1970
    /// A message shown above the footer when an action can't run (cleared on open).
    @Published var notice: String? = nil

    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/agentbar/sessions")
    let recentFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/agentbar/recent.json")

    static func rank(_ s: String) -> Int {
        switch s {
        case "needs_input": return 0
        case "error": return 1
        case "done": return 2
        case "working": return 3
        default: return 4
        }
    }

    func reload(autoselect: Bool) {
        now = Date().timeIntervalSince1970
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var list: [Session] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let s = try? JSONDecoder().decode(Session.self, from: data) else { continue }
            if let p = s.pid, p > 0, kill(pid_t(p), 0) != 0, errno == ESRCH { continue }
            list.append(s)
        }
        list.sort { a, b in
            let ra = Store.rank(a.st), rb = Store.rank(b.st)
            if ra != rb { return ra < rb }
            let sa = a.since ?? 0, sb = b.since ?? 0
            // Waiting/failed: longest-waiting first. Everything else: most recent first.
            return ra <= 1 ? sa < sb : sa > sb
        }

        // Recent desktop sessions (written by `agentbar.py sync` / `menu`), minus any that are
        // active right now, so a session never shows twice.
        let activeHosts = Set(list.compactMap { $0.host_session_id })
        let recentList = ((try? Data(contentsOf: recentFile))
            .flatMap { try? JSONDecoder().decode([RecentSession].self, from: $0) } ?? [])
            .filter { $0.isChat || !activeHosts.contains($0.item_id) }

        let previousID = selectedID
        sessions = list
        recent = Array(recentList.prefix(Store.maxRecent))
        let ids = rowIDs
        let last = max(0, ids.count - 1)
        if autoselect {
            selected = 0
        } else if let pid = previousID, let i = ids.firstIndex(of: pid) {
            selected = i
        } else {
            selected = min(selected, last)
        }
    }

    /// The HUD shows at most this many active rows, then up to maxRecent recent ones;
    /// selection never goes past them.
    static let maxVisible = 9
    static let maxRecent = 5
    var activeCount: Int { min(sessions.count, Store.maxVisible) }
    var visibleCount: Int { activeCount + recent.count }

    private var rowIDs: [String] {
        sessions.prefix(Store.maxVisible).map { $0.id } + recent.map { $0.id }
    }
    private var selectedID: String? { current?.id ?? currentRecent?.id }

    var current: Session? { selected < activeCount ? sessions[selected] : nil }
    var currentRecent: RecentSession? {
        let i = selected - activeCount
        return i >= 0 && i < recent.count ? recent[i] : nil
    }

    func move(_ delta: Int) {
        let n = visibleCount
        guard n > 0 else { return }
        selected = (selected + delta + n) % n
    }

    /// Re-read the session's state file: true only if it is still on the same permission prompt
    /// the user saw in the HUD (same state, same start time).
    func stillWaiting(_ s: Session) -> Bool {
        let f = dir.appendingPathComponent(s.session_id + ".json")
        guard let data = try? Data(contentsOf: f),
              let fresh = try? JSONDecoder().decode(Session.self, from: data) else { return false }
        return fresh.canApprove && fresh.since == s.since
    }

    /// Same, for a question with answers: still open, and still offering the same answers.
    func stillAsking(_ s: Session) -> Bool {
        let f = dir.appendingPathComponent(s.session_id + ".json")
        guard let data = try? Data(contentsOf: f),
              let fresh = try? JSONDecoder().decode(Session.self, from: data) else { return false }
        return fresh.canChoose && fresh.since == s.since && fresh.choices == s.choices
    }

    func count(_ state: String) -> Int { sessions.filter { $0.st == state }.count }
}

// MARK: - Views

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct StatusIcon: View {
    let state: String
    var body: some View {
        Group {
            switch state {
            case "needs_input":
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
            case "error":
                Image(systemName: "xmark.octagon.fill").foregroundColor(.orange)
            case "done":
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case "working":
                ProgressView().controlSize(.small)
            default:
                Image(systemName: "circle").foregroundColor(.gray)
            }
        }
        .font(.system(size: 17))
        .frame(width: 22, height: 22)
    }
}

struct KeyCap: View {
    let key: String
    let light: Bool
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(light ? Color.white.opacity(0.25) : Color.primary.opacity(0.10))
            )
    }
}

struct Row: View {
    let s: Session
    let selected: Bool
    let now: Double

    var body: some View {
        let secondary = selected ? Color.white.opacity(0.80) : Color.secondary
        HStack(spacing: 12) {
            StatusIcon(state: s.st)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(s.project ?? "?")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(s.label) · \(formatAge(now - (s.since ?? now)))")
                        .font(.system(size: 12))
                        .foregroundColor(secondary)
                }
                if !s.choices.isEmpty {
                    // A question waiting on you: show it in full, answers as numbered chips.
                    if let q = s.pending_choice?.ask, !q.isEmpty {
                        Text(q)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(s.choices.enumerated()), id: \.offset) { i, label in
                            ChoiceChip(number: i + 1, label: label, selected: selected,
                                       primary: i == 0, enabled: s.canChoose)
                        }
                    }
                    .padding(.top, 4)
                } else if let d = s.detail, !d.isEmpty, s.st != "working", s.st != "idle" {
                    Text(d)
                        .font(.system(size: 12))
                        .foregroundColor(secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if selected && s.canApprove {
                HStack(spacing: 4) {
                    KeyCap(key: "A", light: true)
                    KeyCap(key: "D", light: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .foregroundColor(selected ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

/// A recent session: quieter than an active row (no status color, regular weight), same
/// spacing and selection style so the list reads as one.
struct RecentRow: View {
    let r: RecentSession
    let selected: Bool
    let now: Double

    var body: some View {
        let secondary = selected ? Color.white.opacity(0.80) : Color.secondary
        HStack(spacing: 12) {
            Image(systemName: r.isChat ? "bubble.left" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 14))
                .foregroundColor(selected ? .white.opacity(0.85) : .secondary)
                .frame(width: 22, height: 22)
            HStack(spacing: 8) {
                Text(r.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(r.project) · \(formatAge(now - r.last_activity))")
                    .font(.system(size: 12))
                    .foregroundColor(secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundColor(selected ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

/// One answer of a pending question. The first one is Claude's recommendation, so it gets a
/// slightly stronger fill; the number is the key that sends it.
struct ChoiceChip: View {
    let number: Int
    let label: String
    let selected: Bool
    let primary: Bool
    let enabled: Bool

    var body: some View {
        let fill: Color = selected
            ? Color.white.opacity(primary ? 0.22 : 0.12)
            : Color.primary.opacity(primary ? 0.10 : 0.05)
        HStack(spacing: 6) {
            if enabled {
                KeyCap(key: "\(number)", light: selected)
            }
            Text(label)
                .font(.system(size: 12, weight: primary ? .semibold : .regular))
                .lineLimit(1)
        }
        .padding(.leading, enabled ? 4 : 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
    }
}

struct Hint: View {
    let key: String
    let text: String
    var enabled: Bool = true
    var body: some View {
        HStack(spacing: 5) {
            KeyCap(key: key, light: false)
            Text(text).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .opacity(enabled ? 1 : 0.35)
    }
}

struct HUDView: View {
    @ObservedObject var store: Store
    var onOpen: (Session) -> Void
    var onOpenRecent: (RecentSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Claude").font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.count("needs_input") > 0 {
                    Text("\(store.count("needs_input")) need you")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.red)
                }
                if store.count("working") > 0 {
                    Text("\(store.count("working")) working")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.5)

            if store.sessions.isEmpty && store.recent.isEmpty {
                Text("No Claude Code sessions")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if store.sessions.isEmpty {
                        Text("No active sessions")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(store.sessions.prefix(Store.maxVisible).enumerated()), id: \.element.id) { i, s in
                        Row(s: s, selected: i == store.selected, now: store.now)
                            .onTapGesture(count: 2) { onOpen(s) }
                            .onTapGesture { store.selected = i }
                    }
                    if !store.recent.isEmpty {
                        Text("RECENT")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, store.sessions.isEmpty ? 4 : 12)
                            .padding(.bottom, 4)
                        ForEach(Array(store.recent.enumerated()), id: \.element.id) { j, r in
                            let i = store.activeCount + j
                            RecentRow(r: r, selected: i == store.selected, now: store.now)
                                .onTapGesture(count: 2) { onOpenRecent(r) }
                                .onTapGesture { store.selected = i }
                        }
                    }
                }
                .padding(8)
            }

            if let notice = store.notice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(notice)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
            }

            Divider().opacity(0.5)

            HStack(spacing: 14) {
                Hint(key: "↑↓", text: "select")
                Hint(key: "↩", text: "open chat")
                if store.current?.canChoose ?? false {
                    Hint(key: "1", text: "first answer")
                    if (store.current?.choices.count ?? 0) > 1 {
                        Hint(key: "2", text: "second answer")
                    }
                } else {
                    Hint(key: "A", text: "approve", enabled: store.current?.canApprove ?? false)
                    Hint(key: "D", text: "deny", enabled: store.current?.canApprove ?? false)
                }
                Spacer()
                Hint(key: "esc", text: "close")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 580)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Window

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var panel: HUDPanel!
    var host: NSHostingView<HUDView>!
    var timer: Timer?
    var keyMonitor: Any?
    var performingAction = false
    var syncRunning = false
    var ticks = 0

    let python = "/usr/bin/python3"
    let script = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/agentbar/agentbar.py").path

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // NSPanel hides itself on deactivation by default (and re-shows on activation);
        // we manage visibility ourselves in the didResignActive observer below.
        panel.hidesOnDeactivate = false

        host = NSHostingView(rootView: HUDView(store: store, onOpen: { [weak self] s in
            self?.act(s, .open)
        }, onOpenRecent: { [weak self] r in
            self?.openRecent(r)
        }))
        panel.contentView = host

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel.isVisible else { return event }
            return self.handleKey(event) ? nil : event
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.performingAction else { return }
            self.panel.orderOut(nil)
            self.timer?.invalidate()
        }

        show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel.isVisible && NSApp.isActive { dismiss() } else { show() }
        return false
    }

    func show() {
        performingAction = false
        store.notice = nil
        store.reload(autoselect: true)
        resize(center: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // SwiftUI may not have applied the reloaded list yet, so fittingSize can be one
        // update behind; measure again on the next runloop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.panel.isVisible else { return }
            self.resize(center: true)
        }
        timer?.invalidate()
        sync()
        ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.ticks += 1
            if self.ticks % 2 == 0 { self.sync() }
            self.store.reload(autoselect: false)
            self.resize(center: false)
        }
    }

    /// `agentbar.py sync` picks up prompts the Claude desktop app shows itself (they don't
    /// reach Claude Code hooks). Runs in the background; the next reload shows the result.
    func sync() {
        guard !syncRunning else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script, "sync"]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.syncRunning = false
                if self.panel.isVisible {
                    // The sync started on open finishes within a moment: re-select the top row
                    // so a just-found prompt is what ↩ opens.
                    self.store.reload(autoselect: self.ticks < 1)
                    self.resize(center: false)
                }
            }
        }
        do { try p.run(); syncRunning = true } catch { syncRunning = false }
    }

    func resize(center: Bool) {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let top: CGFloat
        if center || !panel.isVisible {
            top = vf.maxY - vf.height * 0.22
        } else {
            top = panel.frame.maxY
        }
        let x = center || !panel.isVisible ? vf.midX - size.width / 2 : panel.frame.minX
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }

    /// Close and hand focus back to whatever app was in front before.
    func dismiss() {
        timer?.invalidate()
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let chars = (e.charactersIgnoringModifiers ?? "").lowercased()
        switch e.keyCode {
        case 53: dismiss(); return true                       // esc
        case 126, 91: store.move(-1); return true             // up, keypad 8
        case 125, 84: store.move(1); return true              // down, keypad 2 (never answers)
        case 36, 76:                                          // return, keypad enter
            if let s = store.current { act(s, .open) }
            else if let r = store.currentRecent { openRecent(r) }
            return true
        default: break
        }
        let s = store.current
        let choices = s?.canChoose == true ? s!.choices : []
        switch chars {
        case "k", "8": store.move(-1)
        case "j": store.move(1)
        case "2":                                             // top-row 2
            if let s = s, choices.count > 1 { act(s, .answer(choices[1])) } else { store.move(1) }
        case "o":
            if let s = s { act(s, .open) }
            else if let r = store.currentRecent { openRecent(r) }
        case "a", "1":
            if let s = s, !choices.isEmpty { act(s, .answer(choices[0])) }
            else if let s = s, s.canApprove { act(s, .key(36)) }
            else {
                AppDelegate.log("key \(chars): nothing to answer on this row (state=\(s?.st ?? "-") "
                    + "prompt=\(s?.prompt ?? "-") answers=\(s?.choices.count ?? 0) "
                    + "bundle=\(s?.bundle_id ?? "-") host=\(s?.host_session_id == nil ? "no" : "yes"))")
                NSSound.beep()
            }
        case "d":
            if let s = s, choices.count > 1 { act(s, .answer(choices[1])) }
            else if let s = s, s.canApprove { act(s, .key(53)) }
            else { NSSound.beep() }
        case "0":
            if let s = s, s.canApprove { act(s, .key(53)) } else { NSSound.beep() }
        default: return false
        }
        return true
    }

    /// Open a recent Claude Code session or chat. Nothing is typed into it, so no checks are needed
    /// beyond the open itself.
    func openRecent(_ r: RecentSession) {
        timer?.invalidate()
        panel.orderOut(nil)
        NSApp.hide(nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script, r.isChat ? "open-chat" : "open-host", r.item_id]
        do { try p.run() } catch { NSSound.beep() }
    }

    enum Action {
        case open                 // just bring the session up
        case key(CGKeyCode)       // 36 = Return approves, 53 = Esc denies a permission prompt
        case answer(String)       // type this answer + Return, as clicking its button would send
    }

    /// Focus the session's window, then optionally press a key or send an answer there.
    func act(_ s: Session, _ action: Action) {
        let key: Action? = { if case .open = action { return nil } else { return action } }()
        AppDelegate.log("act \(action) on \(s.project ?? "?") (state=\(s.st) prompt=\(s.prompt ?? "-"))")
        if key != nil && !ensureAccessibility() {
            AppDelegate.log("  stop: no Accessibility permission")
            return
        }
        performingAction = true
        timer?.invalidate()
        panel.orderOut(nil)
        // Give up keyboard focus right away, so that if focusing the session fails we are
        // not left as an active app with no window swallowing keystrokes.
        NSApp.hide(nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script, "focus-sid", s.session_id]
        do { try p.run() } catch { NSSound.beep(); performingAction = false; return }

        DispatchQueue.global().async { [weak self] in
            p.waitUntilExit()
            // focus-sid exits 0 only when the session's exact tab is in front
            // (2 = only its app was activated, 1 = failed).
            let found = p.terminationStatus == 0
            AppDelegate.log("  focus-sid exit \(p.terminationStatus)")
            DispatchQueue.main.async {
                if key != nil && !found {
                    AppDelegate.log("  stop: couldn't confirm the exact chat is showing")
                    self?.performingAction = false
                    NSSound.beep()
                    return
                }
                self?.finishAct(s, key: key, attempt: 0)
            }
        }
    }

    /// After the focus script exits: wait (up to ~2s) for the session's app to actually be
    /// frontmost, let it settle, then press the key. Never presses a key into any other app.
    func finishAct(_ s: Session, key: Action?, attempt: Int) {
        guard let key = key else { performingAction = false; return }
        guard let want = s.expectedBundle else {
            performingAction = false
            NSSound.beep()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == want {
            // The desktop app swaps the conversation in after the link; give it longer to settle.
            let settle: Double = { if case .answer = key { return 0.6 } else { return 0.25 } }()
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self = self else { return }
                self.performingAction = false
                let stillOpen: Bool = {
                    if case .answer = key { return self.store.stillAsking(s) }
                    return self.store.stillWaiting(s)
                }()
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
                guard front == want, stillOpen else {
                    // Wrong app in front, or the prompt was already answered: pressing
                    // Return now could submit whatever is typed in Claude's input box.
                    AppDelegate.log("  stop: front app \(front), expected \(want); prompt still open: \(stillOpen)")
                    NSSound.beep()
                    return
                }
                switch key {
                case .key(let code):
                    AppDelegate.post(code)
                    AppDelegate.log("  sent key \(code)")
                case .answer(let text):
                    AppDelegate.type(text)
                    AppDelegate.post(36)
                    AppDelegate.log("  typed answer (\(text.count) chars) + Return")
                case .open: break
                }
            }
        } else if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finishAct(s, key: key, attempt: attempt + 1)
            }
        } else {
            AppDelegate.log("  stop: \(want) never came to the front (front: "
                + "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))")
            performingAction = false
            NSSound.beep()
        }
    }

    func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Literal value of kAXTrustedCheckOptionPrompt (the global itself trips Swift's
        // shared-mutable-state concurrency check on newer compilers).
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        // Say why nothing happened, and open the page where it's fixed.
        store.notice = "AgentHUD needs Accessibility access to send keys. Turn it on in System Settings, then try again."
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        NSSound.beep()
        return false
    }

    /// One line per step of a key action, so a key that "does nothing" can be traced.
    static func log(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/agentbar/hud.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Type text into the frontmost app, as unicode key events (independent of keyboard layout).
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []
                chunk.withUnsafeBufferPointer { buf in
                    e?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                e?.post(tap: .cghidEventTap)
            }
            i += 16
        }
    }

    static func post(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        // Plain Return/Esc even if a modifier (e.g. the Caps Lock layer key) is still held.
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// AppDelegate is main-actor isolated (via NSApplicationDelegate); top-level code is only
// treated as main-actor isolated in some compiler modes, so make it explicit.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate          // weak reference; keep `delegate` alive across run()
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
