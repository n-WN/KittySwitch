import Cocoa

// MARK: - Kitty Data Models

struct KittyOSWindow: Codable {
    let id: Int
    let isActive: Bool
    let tabs: [KittyTab]

    enum CodingKeys: String, CodingKey {
        case id, tabs
        case isActive = "is_active"
    }
}

struct KittyTab: Codable {
    let id: Int
    let title: String
    let isActive: Bool
    let windows: [KittyWindow]

    enum CodingKeys: String, CodingKey {
        case id, title, windows
        case isActive = "is_active"
    }
}

struct KittyWindow: Codable {
    let id: Int
    let pid: Int
    let cwd: String
    let foregroundProcesses: [FGProcess]

    enum CodingKeys: String, CodingKey {
        case id, pid, cwd
        case foregroundProcesses = "foreground_processes"
    }
}

struct FGProcess: Codable {
    let pid: Int
    let cmdline: [String]
}

// MARK: - Claude Data Models

struct ClaudeSessionFile: Codable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Int64
}

struct SessionMeta {
    let firstPrompt: String
    let cwd: String

    static let empty = SessionMeta(firstPrompt: "", cwd: "")
}

struct ClaudeInfo {
    let sessionId: String
    let pid: Int
    let args: [String]
    let meta: SessionMeta
    let startedAt: Date
    let messageCount: Int
}

struct ProcessInfo {
    let pid: Int
    let ppid: Int
    let rssMB: Double
    let cpu: Double
    let command: String
}

struct TabResources {
    let processes: [ProcessInfo]
    var totalRSS: Double { processes.reduce(0) { $0 + $1.rssMB } }
    var totalCPU: Double { processes.reduce(0) { $0 + $1.cpu } }
    var count: Int { processes.count }
}

struct HistorySession {
    let sessionId: String
    let meta: SessionMeta
    let lastModified: Date
    let messageCount: Int
    let sizeKB: Int
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var refreshTimer: Timer?

    private var cachedState: [KittyOSWindow] = []
    private var sessionFileCache: [Int: ClaudeSessionFile] = [:]
    private var sessionMetaCache: [String: SessionMeta] = [:]
    private var messageCountCache: [String: Int] = [:]
    private var tabResourceCache: [Int: TabResources] = [:]  // shell PID → resources

    let slowInterval: TimeInterval = 5.0
    let fastInterval: TimeInterval = 1.0

    lazy var claudeSessionsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }()

    lazy var claudeProjectsDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let encoded = home.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)")
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Kitty")
            button.image?.size = NSSize(width: 16, height: 16)
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateMenu()
        startTimer(interval: slowInterval)
    }

    // MARK: - Timer

    private func startTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateMenu()
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenu()
        startTimer(interval: fastInterval)
    }

    func menuDidClose(_ menu: NSMenu) {
        startTimer(interval: slowInterval)
    }

    // MARK: - Menu Construction

    private func updateMenu() {
        sessionMetaCache = [:]
        messageCountCache = [:]
        tabResourceCache = [:]
        cachedState = fetchKittyState()
        collectAllTabResources()
        sessionFileCache = loadSessionFiles()
        menu.removeAllItems()

        buildActiveSection()
        buildHistorySection()
        buildFooter()

        let tabCount = cachedState.reduce(0) { $0 + $1.tabs.count }
        statusItem.button?.title = " \(tabCount)"
    }

    private func buildActiveSection() {
        addLabel("Kitty Tabs", bold: true)
        addSeparator()

        guard !cachedState.isEmpty else {
            addLabel("Kitty not running")
            return
        }

        for (i, osWin) in cachedState.enumerated() {
            if cachedState.count > 1 {
                if i > 0 { addSeparator() }
                let suffix = osWin.isActive ? "  (active)" : ""
                addLabel("Window \(i + 1)\(suffix)", bold: true, size: 12)
            }
            for tab in osWin.tabs {
                addTabItem(tab)
            }
        }

        addSeparator()
        let total = cachedState.reduce(0) { $0 + $1.tabs.count }
        let totalRSS = tabResourceCache.values.reduce(0.0) { $0 + $1.totalRSS }
        let totalCPU = tabResourceCache.values.reduce(0.0) { $0 + $1.totalCPU }
        let rssStr = totalRSS >= 1024 ? String(format: "%.1f GB", totalRSS / 1024) : String(format: "%.0f MB", totalRSS)
        addLabel("\(total) tabs  ·  \(rssStr)  ·  \(String(format: "%.1f", totalCPU))% CPU")
    }

    private func addTabItem(_ tab: KittyTab) {
        let info = extractClaudeInfo(from: tab)
        let res = resourcesForTab(tab)
        let title = truncate(tab.title, to: 50)
        let cwd = tab.windows.first.map { shortenPath($0.cwd) } ?? ""

        let item = NSMenuItem(title: title, action: #selector(focusTab(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tab.id
        item.state = tab.isActive ? .on : .off

        let attr = NSMutableAttributedString()
        if info != nil { attr.append(styled("◆ ", size: 13, color: .systemOrange)) }
        attr.append(styled(title, size: 13))
        attr.append(styled("  \(cwd)", size: 11, color: .secondaryLabelColor))

        // Resource summary inline
        if let res {
            let resStr = formatResourceSummary(res)
            let color: NSColor = res.totalRSS > 500 ? .systemOrange : .tertiaryLabelColor
            attr.append(styled("  \(resStr)", size: 10, color: color, mono: true))
        }
        item.attributedTitle = attr

        // Tooltip with full details
        var tip = tab.title
        if let info {
            tip += "\n\nClaude Code (PID \(info.pid))"
            tip += "\nSession: \(info.sessionId)"
            tip += "\nArgs: \(info.args.joined(separator: " "))"
            if !info.meta.firstPrompt.isEmpty { tip += "\nPrompt: \(info.meta.firstPrompt)" }
        }
        if let res {
            tip += "\n\nResources: \(formatResourceSummary(res))"
            for proc in res.processes.sorted(by: { $0.rssMB > $1.rssMB }) {
                let rss = proc.rssMB < 1 ? "<1" : String(format: "%.0f", proc.rssMB)
                tip += "\n  PID \(proc.pid)  \(rss)MB  \(String(format: "%.1f", proc.cpu))%  \(proc.command)"
            }
        }
        item.toolTip = tip
        menu.addItem(item)

        // Detail line: claude info + process tree
        if info != nil || (res != nil && res!.count > 1) {
            let detail = buildDetailLine(info: info, res: res)
            let sub = NSMenuItem()
            sub.isEnabled = false
            sub.attributedTitle = styled(detail, size: 10, color: .tertiaryLabelColor, mono: true)
            menu.addItem(sub)
        }
    }

    private func buildDetailLine(info: ClaudeInfo?, res: TabResources?) -> String {
        var parts: [String] = ["    "]

        if let info {
            parts.append("⏣ \(info.sessionId.prefix(8))…")
            let flags = info.args.filter { $0.hasPrefix("--") && $0 != "--resume" }
            if !flags.isEmpty { parts.append(flags.joined(separator: " ")) }
        }

        if let res, res.count > 1 {
            // Show top processes by RSS (excluding the shell itself)
            let significant = res.processes
                .filter { $0.rssMB > 0.5 }
                .sorted { $0.rssMB > $1.rssMB }
                .prefix(3)
            let tree = significant.map { proc in
                let rss = proc.rssMB >= 1024
                    ? String(format: "%.1fG", proc.rssMB / 1024)
                    : String(format: "%.0fM", proc.rssMB)
                return "\(proc.command)(\(rss))"
            }.joined(separator: " + ")
            if !tree.isEmpty { parts.append(tree) }
        }

        return parts.joined(separator: "  ")
    }

    private func buildHistorySection() {
        addSeparator()
        addLabel("Recent Sessions", bold: true, size: 12)
        addSeparator()

        let active = getActiveSessionIds()
        let history = fetchHistorySessions(excluding: active)

        guard !history.isEmpty else {
            addLabel("No recent sessions")
            return
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"

        for session in history.prefix(10) {
            let prompt = session.meta.firstPrompt.isEmpty ? "(no prompt)" : truncate(session.meta.firstPrompt, to: 40)
            let time = fmt.string(from: session.lastModified)
            let cwd = shortenPath(session.meta.cwd)
            let size = session.sizeKB > 1024
                ? String(format: "%.1fMB", Double(session.sizeKB) / 1024)
                : "\(session.sizeKB)KB"

            // Normal resume
            let item = NSMenuItem(title: prompt, action: nil, keyEquivalent: "")
            item.target = self

            let attr = NSMutableAttributedString()
            attr.append(styled("↻ ", size: 12, color: .systemBlue))
            attr.append(styled(prompt, size: 12))
            attr.append(styled("  \(cwd)  \(time)  \(session.messageCount) msgs", size: 10, color: .tertiaryLabelColor))
            item.attributedTitle = attr
            item.toolTip = "Session: \(session.sessionId)\nCWD: \(session.meta.cwd)\nSize: \(size)\nMessages: \(session.messageCount)"

            // Submenu: two resume modes
            let sub = NSMenu()
            let normalItem = NSMenuItem(title: "Resume", action: #selector(resumeSession(_:)), keyEquivalent: "")
            normalItem.target = self
            normalItem.representedObject = ResumeInfo(sessionId: session.sessionId, cwd: session.meta.cwd, dangerousMode: false)
            sub.addItem(normalItem)

            let dangerItem = NSMenuItem(title: "Resume (skip permissions)", action: #selector(resumeSession(_:)), keyEquivalent: "")
            dangerItem.target = self
            dangerItem.representedObject = ResumeInfo(sessionId: session.sessionId, cwd: session.meta.cwd, dangerousMode: true)
            sub.addItem(dangerItem)

            item.submenu = sub
            menu.addItem(item)
        }
    }

    private func buildFooter() {
        addSeparator()
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Menu Helpers

    private func addLabel(_ title: String, bold: Bool = false, size: CGFloat = 13) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        menu.addItem(item)
    }

    private func addSeparator() {
        menu.addItem(.separator())
    }

    private func styled(_ text: String, size: CGFloat, color: NSColor? = nil, mono: Bool = false) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        ]
        if let c = color { attrs[.foregroundColor] = c }
        return NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - Actions

    class ResumeInfo: NSObject {
        let sessionId: String
        let cwd: String
        let dangerousMode: Bool
        init(sessionId: String, cwd: String, dangerousMode: Bool) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.dangerousMode = dangerousMode
        }
    }

    @objc func focusTab(_ sender: NSMenuItem) {
        shell("kitty", "@", "focus-tab", "--match", "id:\(sender.tag)")
        activateKitty()
    }

    @objc func resumeSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? ResumeInfo else { return }
        let cwd = info.cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : info.cwd

        var launchArgs = ["kitty", "@", "launch", "--type=tab", "--cwd=\(cwd)", "claude"]
        if info.dangerousMode {
            launchArgs.append("--dangerously-skip-permissions")
        }
        launchArgs.append(contentsOf: ["--resume", info.sessionId])

        shell(launchArgs)
        activateKitty()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func activateKitty() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "net.kovidgoyal.kitty").first?.activate()
    }

    // MARK: - Kitty Communication

    private func fetchKittyState() -> [KittyOSWindow] {
        guard let output = shell("kitty", "@", "ls"), !output.isEmpty,
              let data = output.data(using: .utf8)
        else { return [] }
        return (try? JSONDecoder().decode([KittyOSWindow].self, from: data)) ?? []
    }

    // MARK: - Claude Session Detection

    private func loadSessionFiles() -> [Int: ClaudeSessionFile] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: claudeSessionsDir, includingPropertiesForKeys: nil
        ) else { return [:] }

        var map: [Int: ClaudeSessionFile] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data)
            else { continue }
            map[session.pid] = session
        }
        return map
    }

    private func extractClaudeInfo(from tab: KittyTab) -> ClaudeInfo? {
        for win in tab.windows {
            for proc in win.foregroundProcesses {
                guard let idx = proc.cmdline.firstIndex(where: { $0 == "claude" || $0.hasSuffix("/claude") })
                else { continue }

                let args = Array(proc.cmdline[(idx + 1)...])

                // Resolve session ID: session file (by PID) → --resume arg fallback
                var sessionId: String?
                var startedAt: Date?

                if let sf = sessionFileCache[proc.pid] {
                    sessionId = sf.sessionId
                    startedAt = Date(timeIntervalSince1970: Double(sf.startedAt) / 1000)
                } else if let ri = args.firstIndex(of: "--resume"), ri + 1 < args.count,
                          args[ri + 1].count > 30, args[ri + 1].contains("-") {
                    sessionId = args[ri + 1]
                }

                guard let sid = sessionId else { continue }

                return ClaudeInfo(
                    sessionId: sid,
                    pid: proc.pid,
                    args: args,
                    meta: readSessionMeta(sessionId: sid),
                    startedAt: startedAt ?? Date(),
                    messageCount: countMessages(sessionId: sid)
                )
            }
        }
        return nil
    }

    private func getActiveSessionIds() -> Set<String> {
        var ids = Set<String>()
        for osWin in cachedState {
            for tab in osWin.tabs {
                for win in tab.windows {
                    for proc in win.foregroundProcesses {
                        if let sf = sessionFileCache[proc.pid] { ids.insert(sf.sessionId) }
                    }
                }
            }
        }
        return ids
    }

    // MARK: - JSONL Reading

    private func readSessionMeta(sessionId: String) -> SessionMeta {
        if let cached = sessionMetaCache[sessionId] { return cached }
        let file = claudeProjectsDir.appendingPathComponent("\(sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .empty }
        defer { handle.closeFile() }

        let chunk = handle.readData(ofLength: 65536)
        guard let text = String(data: chunk, encoding: .utf8) else { return .empty }

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "user",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"]
            else { continue }

            let cwd = obj["cwd"] as? String ?? ""
            let prompt: String
            if let text = content as? String {
                prompt = String(text.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let arr = content as? [[String: Any]],
                      let first = arr.first,
                      let text = first["text"] as? String {
                prompt = String(text.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                prompt = ""
            }
            let result = SessionMeta(firstPrompt: prompt, cwd: cwd)
            sessionMetaCache[sessionId] = result
            return result
        }
        sessionMetaCache[sessionId] = .empty
        return .empty
    }

    /// Count lines by streaming in 64KB chunks instead of loading the entire file.
    private func countMessages(sessionId: String) -> Int {
        if let cached = messageCountCache[sessionId] { return cached }
        let file = claudeProjectsDir.appendingPathComponent("\(sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { handle.closeFile() }

        var count = 0
        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            count += chunk.withUnsafeBytes { buf in
                buf.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
            }
        }
        messageCountCache[sessionId] = count
        return count
    }

    // MARK: - History

    private func fetchHistorySessions(excluding active: Set<String>) -> [HistorySession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }

        // First pass: collect candidates with file attributes only (no I/O)
        struct Candidate {
            let sid: String
            let mtime: Date
            let sizeKB: Int
        }
        var candidates: [Candidate] = []
        for file in files where file.pathExtension == "jsonl" {
            let sid = file.deletingPathExtension().lastPathComponent
            guard sid.count > 30, !active.contains(sid),
                  let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = attrs.contentModificationDate,
                  let size = attrs.fileSize,
                  size / 1024 > 10  // skip sub-agents / test sessions
            else { continue }
            candidates.append(Candidate(sid: sid, mtime: mtime, sizeKB: size / 1024))
        }

        // Sort by mtime descending, then only read JSONL for the top 10
        candidates.sort { $0.mtime > $1.mtime }

        return candidates.prefix(10).map { c in
            HistorySession(
                sessionId: c.sid,
                meta: readSessionMeta(sessionId: c.sid),
                lastModified: c.mtime,
                messageCount: countMessages(sessionId: c.sid),
                sizeKB: c.sizeKB
            )
        }
    }

    // MARK: - Process Resources

    /// Collect resource info for all kitty tabs using a single `ps -eo` call.
    /// Builds the process tree in memory — no recursive pgrep, no per-tab fork.
    private func collectAllTabResources() {
        var shellPids = Set<Int>()
        for osWin in cachedState {
            for tab in osWin.tabs {
                for win in tab.windows { shellPids.insert(win.pid) }
            }
        }
        guard !shellPids.isEmpty else { return }

        // One ps call for the ENTIRE system process table
        guard let psOutput = shell("ps", "-eo", "pid=,ppid=,rss=,%cpu=,comm=") else { return }

        // Parse into flat list + parent→children map
        struct RawProc {
            let pid: Int, ppid: Int, rss: Int
            let cpu: Double, command: String
        }
        var allProcs: [Int: RawProc] = [:]
        var children: [Int: [Int]] = [:]  // ppid → [child pids]

        for line in psOutput.split(separator: "\n") {
            // split omitting empty subsequences handles leading/multiple spaces
            let tokens = line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " })
            guard tokens.count >= 5,
                  let pid = Int(tokens[0]),
                  let ppid = Int(tokens[1]),
                  let rss = Int(tokens[2]),
                  let cpu = Double(tokens[3])
            else { continue }
            let command = tokens[4...].joined(separator: " ")
            allProcs[pid] = RawProc(pid: pid, ppid: ppid, rss: rss, cpu: cpu, command: command)
            children[ppid, default: []].append(pid)
        }

        // For each shell PID, walk the tree in memory to find all descendants
        func descendants(of pid: Int) -> [Int] {
            var result = [pid]
            for child in children[pid] ?? [] {
                result.append(contentsOf: descendants(of: child))
            }
            return result
        }

        for shellPid in shellPids {
            let pids = descendants(of: shellPid)
            let procs = pids.compactMap { pid -> ProcessInfo? in
                guard let r = allProcs[pid] else { return nil }
                return ProcessInfo(
                    pid: r.pid, ppid: r.ppid,
                    rssMB: Double(r.rss) / 1024,
                    cpu: r.cpu,
                    command: shortenCommand(r.command)
                )
            }
            tabResourceCache[shellPid] = TabResources(processes: procs)
        }
    }

    private func shortenCommand(_ cmd: String) -> String {
        // "/opt/homebrew/bin/fish" → "fish"
        let base = (cmd as NSString).lastPathComponent
        return base.isEmpty ? cmd : base
    }

    private func resourcesForTab(_ tab: KittyTab) -> TabResources? {
        guard let win = tab.windows.first else { return nil }
        return tabResourceCache[win.pid]
    }

    private func formatResourceSummary(_ res: TabResources) -> String {
        let rss = res.totalRSS < 1 ? "<1MB" :
                  res.totalRSS >= 1024 ? String(format: "%.1fGB", res.totalRSS / 1024) :
                  String(format: "%.0fMB", res.totalRSS)
        let cpu = res.totalCPU < 0.1 ? "0%" : String(format: "%.1f%%", res.totalCPU)
        return "\(rss)  \(cpu)  \(res.count)p"
    }

    // MARK: - Helpers

    @discardableResult
    private func shell(_ args: String...) -> String? { shell(args) }

    @discardableResult
    private func shell(_ args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func truncate(_ text: String, to max: Int) -> String {
        text.count > max ? String(text.prefix(max - 3)) + "..." : text
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
