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

    var id: String { session_id }
    var st: String { state ?? "idle" }
    var needsInput: Bool { st == "needs_input" }

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

func formatAge(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selected: Int = 0
    @Published var now: Double = Date().timeIntervalSince1970

    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/agentbar/sessions")

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

        let previousID = current?.id
        sessions = list
        let last = max(0, visibleCount - 1)
        if autoselect {
            selected = 0
        } else if let pid = previousID, let i = list.firstIndex(where: { $0.id == pid }), i <= last {
            selected = i
        } else {
            selected = min(selected, last)
        }
    }

    /// The HUD shows at most this many rows; selection never goes past them.
    static let maxVisible = 9
    var visibleCount: Int { min(sessions.count, Store.maxVisible) }

    var current: Session? { selected < visibleCount ? sessions[selected] : nil }

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
                if let d = s.detail, !d.isEmpty, s.st != "working", s.st != "idle" {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Claude Code").font(.system(size: 13, weight: .semibold))
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

            if store.sessions.isEmpty {
                Text("No active Claude Code sessions")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(store.sessions.prefix(Store.maxVisible).enumerated()), id: \.element.id) { i, s in
                        Row(s: s, selected: i == store.selected, now: store.now)
                            .onTapGesture(count: 2) { onOpen(s) }
                            .onTapGesture { store.selected = i }
                    }
                }
                .padding(8)
            }

            Divider().opacity(0.5)

            HStack(spacing: 14) {
                Hint(key: "↑↓", text: "select")
                Hint(key: "↩", text: "open chat")
                Hint(key: "A", text: "approve", enabled: store.current?.canApprove ?? false)
                Hint(key: "D", text: "deny", enabled: store.current?.canApprove ?? false)
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
            self?.act(s, key: nil)
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
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.store.reload(autoselect: false)
            self.resize(center: false)
        }
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
        case 126: store.move(-1); return true                 // up
        case 125: store.move(1); return true                  // down
        case 36, 76:                                          // return, keypad enter
            if let s = store.current { act(s, key: nil) }
            return true
        default: break
        }
        switch chars {
        case "k", "8": store.move(-1)
        case "j", "2": store.move(1)
        case "o": if let s = store.current { act(s, key: nil) }
        case "a", "1":
            if let s = store.current, s.canApprove { act(s, key: 36) } else { NSSound.beep() }
        case "d", "0":
            if let s = store.current, s.canApprove { act(s, key: 53) } else { NSSound.beep() }
        default: return false
        }
        return true
    }

    /// Focus the session's window; optionally press a key there (36 = Return approves, 53 = Esc denies).
    func act(_ s: Session, key: CGKeyCode?) {
        if key != nil && !ensureAccessibility() { return }
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
            DispatchQueue.main.async {
                if key != nil && !found {
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
    func finishAct(_ s: Session, key: CGKeyCode?, attempt: Int) {
        guard let key = key else { performingAction = false; return }
        guard let want = s.expectedBundle else {
            performingAction = false
            NSSound.beep()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == want {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self else { return }
                self.performingAction = false
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == want,
                      self.store.stillWaiting(s) else {
                    // Wrong app in front, or the prompt was already answered: pressing
                    // Return now could submit whatever is typed in Claude's input box.
                    NSSound.beep()
                    return
                }
                AppDelegate.post(key)
            }
        } else if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finishAct(s, key: key, attempt: attempt + 1)
            }
        } else {
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
        NSSound.beep()
        return false
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
