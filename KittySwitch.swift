import Cocoa
import Darwin

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
    let layout: String
    let windows: [KittyWindow]

    enum CodingKeys: String, CodingKey {
        case id, title, layout, windows
        case isActive = "is_active"
    }
}

struct KittyWindow: Codable {
    let id: Int
    let pid: Int
    let cwd: String
    let cmdline: [String]
    let foregroundProcesses: [FGProcess]

    enum CodingKeys: String, CodingKey {
        case id, pid, cwd, cmdline
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
    let lastPrompt: String
    let cwd: String
    static let empty = SessionMeta(firstPrompt: "", lastPrompt: "", cwd: "")
}

/// Lightweight Claude detection result — no I/O, just IDs and args.
struct ClaudeInfo {
    let sessionId: String
    let jsonlSessionId: String
    let pid: Int
    let args: [String]
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

struct ClosedTab: Codable {
    let title: String
    let cwd: String
    let layout: String
    let shell: [String]
    let foregroundCmd: [String]
    let closedAt: Date
    let claudeSessionId: String?
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
    private var previousTabIds = Set<Int>()
    private var previousTabSnapshots: [Int: ClosedTab] = [:]
    private var closedTabs: [ClosedTab] = []
    private let maxClosedTabs = 20

    private var sessionFileCache: [Int: ClaudeSessionFile] = [:]
    private var sessionMetaCache: [String: SessionMeta] = [:]
    private var tabResourceCache: [Int: TabResources] = [:]

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
        closedTabs = loadClosedTabs()
        refreshDataInBackground()
        startTimer(interval: slowInterval)
    }

    // MARK: - Background Data Refresh

    private func refreshDataInBackground() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let (state, sessions, resources) = autoreleasepool {
                () -> ([KittyOSWindow], [Int: ClaudeSessionFile], [Int: TabResources]) in
                let state = self.fetchKittyState()
                let sessions = self.loadSessionFiles()
                let resources = state.isEmpty ? [:] : self.buildResourceMap(for: state)
                return (state, sessions, resources)
            }
            malloc_zone_pressure_relief(nil, 0)

            DispatchQueue.main.async {
                self.detectClosedTabs(newState: state, sessions: sessions)
                self.snapshotTabs(state: state, sessions: sessions)
                self.cachedState = state
                self.sessionFileCache = sessions
                self.tabResourceCache = resources
                self.sessionMetaCache = [:]
                self.statusItem.button?.title = " \(state.reduce(0) { $0 + $1.tabs.count })"
            }
        }
    }

    private func detectClosedTabs(newState: [KittyOSWindow], sessions: [Int: ClaudeSessionFile]) {
        let currentIds = Set(newState.flatMap { $0.tabs.map(\.id) })
        guard !previousTabIds.isEmpty else { return }

        var changed = false
        for tabId in previousTabIds.subtracting(currentIds) {
            if let snapshot = previousTabSnapshots[tabId] {
                closedTabs.insert(snapshot, at: 0)
                changed = true
            }
        }
        if closedTabs.count > maxClosedTabs {
            closedTabs = Array(closedTabs.prefix(maxClosedTabs))
        }
        if changed { saveClosedTabs() }
    }

    private func snapshotTabs(state: [KittyOSWindow], sessions: [Int: ClaudeSessionFile]) {
        previousTabIds = Set(state.flatMap { $0.tabs.map(\.id) })
        previousTabSnapshots = [:]
        for osWin in state {
            for tab in osWin.tabs {
                guard let win = tab.windows.first else { continue }
                let claudeId = findClaudeSessionId(in: win, sessions: sessions)
                let fgCmd = win.foregroundProcesses.first {
                    $0.cmdline.contains { $0 == "claude" || $0.hasSuffix("/claude") }
                }?.cmdline ?? []
                previousTabSnapshots[tab.id] = ClosedTab(
                    title: tab.title, cwd: win.cwd, layout: tab.layout,
                    shell: win.cmdline, foregroundCmd: fgCmd,
                    closedAt: Date(), claudeSessionId: claudeId
                )
            }
        }
    }

    /// Shared Claude detection: find session ID from a kitty window's foreground processes.
    private func findClaudeSessionId(in win: KittyWindow, sessions: [Int: ClaudeSessionFile]) -> String? {
        for proc in win.foregroundProcesses {
            guard proc.cmdline.contains(where: { $0 == "claude" || $0.hasSuffix("/claude") })
            else { continue }
            if let sf = sessions[proc.pid] { return sf.sessionId }
            if let ri = proc.cmdline.firstIndex(of: "--resume"), ri + 1 < proc.cmdline.count,
               proc.cmdline[ri + 1].count > 30, proc.cmdline[ri + 1].contains("-") {
                return proc.cmdline[ri + 1]
            }
        }
        return nil
    }

    private func buildResourceMap(for state: [KittyOSWindow]) -> [Int: TabResources] {
        var shellPids = Set<Int>()
        for osWin in state { for tab in osWin.tabs { for win in tab.windows { shellPids.insert(win.pid) } } }
        guard !shellPids.isEmpty,
              let psOutput = shell("ps", "-eo", "pid=,ppid=,rss=,%cpu=,comm=")
        else { return [:] }

        var ppidOf: [Int: Int] = [:]
        var children: [Int: [Int]] = [:]
        var lineRanges: [Int: Substring] = [:]

        for line in psOutput.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let si = trimmed.firstIndex(of: " "), let pid = Int(trimmed[..<si]) else { continue }
            let rest = trimmed[si...].drop(while: { $0 == " " })
            guard let si2 = rest.firstIndex(of: " "), let ppid = Int(rest[..<si2]) else { continue }
            ppidOf[pid] = ppid
            children[ppid, default: []].append(pid)
            lineRanges[pid] = line
        }

        func descendants(of pid: Int) -> [Int] {
            var result = [pid]
            for child in children[pid] ?? [] { result.append(contentsOf: descendants(of: child)) }
            return result
        }

        var relevantPids = Set<Int>()
        for shellPid in shellPids { for pid in descendants(of: shellPid) { relevantPids.insert(pid) } }

        var procMap: [Int: ProcessInfo] = [:]
        for pid in relevantPids {
            guard let line = lineRanges[pid] else { continue }
            let tokens = line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " })
            guard tokens.count >= 5, let rss = Int(tokens[2]), let cpu = Double(tokens[3]) else { continue }
            procMap[pid] = ProcessInfo(pid: pid, ppid: ppidOf[pid] ?? 0,
                                       rssMB: Double(rss) / 1024, cpu: cpu,
                                       command: shortenCommand(tokens[4...].joined(separator: " ")))
        }

        var map: [Int: TabResources] = [:]
        for shellPid in shellPids { map[shellPid] = TabResources(processes: descendants(of: shellPid).compactMap { procMap[$0] }) }
        return map
    }

    // MARK: - Timer

    private func startTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshDataInBackground()
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuFromCache()
        refreshDataInBackground()
        startTimer(interval: fastInterval)
    }

    func menuDidClose(_ menu: NSMenu) {
        startTimer(interval: slowInterval)
    }

    // MARK: - Menu Construction

    private func rebuildMenuFromCache() {
        menu.removeAllItems()
        buildActiveSection()
        buildClosedSection()
        buildHistorySection()
        buildFooter()
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
                addLabel("Window \(i + 1)\(osWin.isActive ? "  (active)" : "")", bold: true, size: 12)
            }
            for tab in osWin.tabs { addTabItem(tab) }
        }

        addSeparator()
        let total = cachedState.reduce(0) { $0 + $1.tabs.count }
        let totalRSS = tabResourceCache.values.reduce(0.0) { $0 + $1.totalRSS }
        let totalCPU = tabResourceCache.values.reduce(0.0) { $0 + $1.totalCPU }
        addLabel("\(total) tabs  ·  \(formatRSS(totalRSS))  ·  \(String(format: "%.1f", totalCPU))% CPU")

        statusItem.button?.title = " \(total)"
    }

    private func addTabItem(_ tab: KittyTab) {
        let info = extractClaudeInfo(from: tab)
        let title = truncate(tab.title, to: 50)
        let cwd = tab.windows.first.map { shortenPath($0.cwd) } ?? ""
        let res = tabResourceCache[tab.windows.first?.pid ?? 0]

        let item = NSMenuItem(title: title, action: #selector(focusTab(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tab.id
        item.state = tab.isActive ? .on : .off

        let attr = NSMutableAttributedString()
        if info != nil { attr.append(styled("◆ ", size: 13, color: .systemOrange)) }
        attr.append(styled(title, size: 13))
        attr.append(styled("  \(cwd)", size: 11, color: .secondaryLabelColor))
        if let res {
            let color: NSColor = res.totalRSS > 500 ? .systemOrange : .tertiaryLabelColor
            attr.append(styled("  \(formatRSS(res.totalRSS))  \(res.count)p", size: 10, color: color, mono: true))
        }
        item.attributedTitle = attr
        item.submenu = LazyTabMenu(appDelegate: self, tab: tab, claudeInfo: info, resources: res)
        menu.addItem(item)
    }

    private func buildClosedSection() {
        guard !closedTabs.isEmpty else { return }
        addSeparator()
        addLabel("Recently Closed", bold: true, size: 12)
        addSeparator()

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        for (i, closed) in closedTabs.prefix(8).enumerated() {
            let item = NSMenuItem(title: closed.title, action: #selector(restoreClosedTab(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            let attr = NSMutableAttributedString()
            if closed.claudeSessionId != nil { attr.append(styled("◆ ", size: 12, color: .systemOrange)) }
            attr.append(styled(truncate(closed.title, to: 45), size: 12))
            attr.append(styled("  \(shortenPath(closed.cwd))  \(fmt.string(from: closed.closedAt))", size: 10, color: .tertiaryLabelColor))
            item.attributedTitle = attr
            menu.addItem(item)
        }
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
            let item = NSMenuItem(title: prompt, action: nil, keyEquivalent: "")

            let attr = NSMutableAttributedString()
            attr.append(styled("↻ ", size: 12, color: .systemBlue))
            attr.append(styled(prompt, size: 12))
            attr.append(styled("  \(fmt.string(from: session.lastModified))  \(session.messageCount) msgs", size: 10, color: .tertiaryLabelColor))
            item.attributedTitle = attr

            let sub = NSMenu()
            let idItem = NSMenuItem(title: session.sessionId, action: #selector(copyText(_:)), keyEquivalent: "")
            idItem.target = self
            idItem.representedObject = session.sessionId
            idItem.attributedTitle = styled("⏣  \(session.sessionId)", size: 10, color: .secondaryLabelColor, mono: true)
            sub.addItem(idItem)

            let cwdLabel = NSMenuItem()
            cwdLabel.isEnabled = false
            let size = session.sizeKB > 1024 ? String(format: "%.1fMB", Double(session.sizeKB) / 1024) : "\(session.sizeKB)KB"
            cwdLabel.attributedTitle = styled("  \(shortenPath(session.meta.cwd))  ·  \(size)", size: 10, color: .tertiaryLabelColor)
            sub.addItem(cwdLabel)
            sub.addItem(.separator())

            for (title, danger) in [("▶  Resume", false), ("  Resume (skip permissions)", true)] {
                let ri = NSMenuItem(title: title, action: #selector(resumeSession(_:)), keyEquivalent: "")
                ri.target = self
                ri.representedObject = ResumeInfo(sessionId: session.sessionId, cwd: session.meta.cwd, dangerousMode: danger)
                ri.attributedTitle = styled(title, size: 12, color: danger ? .systemOrange : nil)
                sub.addItem(ri)
            }
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
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        ])
        menu.addItem(item)
    }

    private func addSeparator() { menu.addItem(.separator()) }

    func styled(_ text: String, size: CGFloat, color: NSColor? = nil, mono: Bool = false) -> NSAttributedString {
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
            self.sessionId = sessionId; self.cwd = cwd; self.dangerousMode = dangerousMode
        }
    }

    @objc func focusTab(_ sender: NSMenuItem) {
        shell("kitty", "@", "focus-tab", "--match", "id:\(sender.tag)")
        activateKitty()
    }

    @objc func resumeSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? ResumeInfo else { return }
        let cwd = info.cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : info.cwd
        var args = ["kitty", "@", "launch", "--type=tab", "--cwd=\(cwd)", "claude"]
        if info.dangerousMode { args.append("--dangerously-skip-permissions") }
        args.append(contentsOf: ["--resume", info.sessionId])
        shell(args)
        activateKitty()
    }

    @objc func restoreClosedTab(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < closedTabs.count else { return }
        let closed = closedTabs[idx]

        if let sessionId = closed.claudeSessionId {
            shell("kitty", "@", "launch", "--type=tab", "--cwd=\(closed.cwd)",
                  "claude", "--dangerously-skip-permissions", "--resume", sessionId)
        } else if !closed.foregroundCmd.isEmpty {
            shell(["kitty", "@", "launch", "--type=tab", "--cwd=\(closed.cwd)"] + closed.foregroundCmd)
        } else {
            shell(["kitty", "@", "launch", "--type=tab", "--cwd=\(closed.cwd)"] + (closed.shell.isEmpty ? ["/bin/zsh"] : closed.shell))
        }
        closedTabs.remove(at: idx)
        saveClosedTabs()
        activateKitty()
    }

    @objc func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func killProcess(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        kill(Int32(sender.tag), SIGTERM)
    }

    @objc func closeKittyTab(_ sender: NSMenuItem) {
        shell("kitty", "@", "close-tab", "--match", "id:\(sender.tag)")
    }

    @objc func quitApp() { NSApplication.shared.terminate(nil) }

    private func activateKitty() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "net.kovidgoyal.kitty").first?.activate()
    }

    // MARK: - Kitty Communication

    private func fetchKittyState() -> [KittyOSWindow] {
        guard let output = shell("kitty", "@", "ls"), !output.isEmpty,
              let data = output.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([KittyOSWindow].self, from: data)) ?? []
    }

    // MARK: - Claude Session Detection

    private func loadSessionFiles() -> [Int: ClaudeSessionFile] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: claudeSessionsDir, includingPropertiesForKeys: nil)
        else { return [:] }
        var map: [Int: ClaudeSessionFile] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let sf = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data) else { continue }
            map[sf.pid] = sf
        }
        return map
    }

    private func extractClaudeInfo(from tab: KittyTab) -> ClaudeInfo? {
        for win in tab.windows {
            for proc in win.foregroundProcesses {
                guard let idx = proc.cmdline.firstIndex(where: { $0 == "claude" || $0.hasSuffix("/claude") })
                else { continue }
                let args = Array(proc.cmdline[(idx + 1)...])

                let sessionId = sessionFileCache[proc.pid]?.sessionId
                let resumeArg: String? = {
                    guard let ri = args.firstIndex(of: "--resume"), ri + 1 < args.count,
                          args[ri + 1].count > 30, args[ri + 1].contains("-") else { return nil }
                    return args[ri + 1]
                }()

                var jsonlId = [resumeArg, sessionId].compactMap { $0 }.first {
                    FileManager.default.fileExists(atPath: claudeProjectsDir.appendingPathComponent("\($0).jsonl").path)
                }
                if jsonlId == nil, let sid = sessionId { jsonlId = findJsonlForSession(sid) }

                guard let sid = sessionId ?? resumeArg else { continue }
                return ClaudeInfo(sessionId: sid, jsonlSessionId: jsonlId ?? sid, pid: proc.pid, args: args)
            }
        }
        return nil
    }

    private func getActiveSessionIds() -> Set<String> {
        var ids = Set<String>()
        for osWin in cachedState {
            for tab in osWin.tabs { for win in tab.windows { for proc in win.foregroundProcesses {
                if let sf = sessionFileCache[proc.pid] { ids.insert(sf.sessionId) }
            } } }
        }
        return ids
    }

    /// Find JSONL file: direct match across all project dirs, then mtime-based fallback.
    private func findJsonlForSession(_ targetId: String) -> String? {
        let projectsBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projectsBase, includingPropertiesForKeys: nil) else { return nil }

        // Direct match
        for dir in dirs {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(targetId).jsonl").path) { return targetId }
        }

        // Mtime-based fallback
        let claimedIds = Set(sessionFileCache.values.compactMap { sf -> String? in
            FileManager.default.fileExists(atPath: claudeProjectsDir.appendingPathComponent("\(sf.sessionId).jsonl").path) ? sf.sessionId : nil
        })
        guard let jsonls = try? FileManager.default.contentsOfDirectory(at: claudeProjectsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return jsonls.filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (String, Date)? in
                let sid = url.deletingPathExtension().lastPathComponent
                guard !claimedIds.contains(sid),
                      let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = attrs.contentModificationDate,
                      Date().timeIntervalSince(mtime) < 86400 else { return nil }
                return (sid, mtime)
            }
            .sorted { $0.1 > $1.1 }
            .first?.0
    }

    /// Resolve JSONL path across all project directories.
    func resolveJsonlPath(sessionId: String) -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let p = dir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: p.path) { return p }
        }
        return nil
    }

    // MARK: - JSONL Reading

    func readSessionMeta(sessionId: String) -> SessionMeta {
        if let cached = sessionMetaCache[sessionId] { return cached }
        let file = resolveJsonlPath(sessionId: sessionId) ?? claudeProjectsDir.appendingPathComponent("\(sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .empty }
        defer { handle.closeFile() }

        let headChunk = handle.readData(ofLength: 65536)
        let firstPrompt = extractPrompt(from: headChunk, last: false)
        let cwd = extractCwd(from: headChunk)

        var lastPrompt = ""
        let fileSize = handle.seekToEndOfFile()
        if fileSize > 65536 {
            handle.seek(toFileOffset: fileSize - 65536)
            lastPrompt = extractPrompt(from: handle.readData(ofLength: 65536), last: true)
        } else {
            lastPrompt = extractPrompt(from: headChunk, last: true)
        }
        if lastPrompt == firstPrompt { lastPrompt = "" }

        let result = SessionMeta(firstPrompt: firstPrompt, lastPrompt: lastPrompt, cwd: cwd)
        sessionMetaCache[sessionId] = result
        return result
    }

    /// Extract first or last user prompt from a JSONL chunk.
    private func extractPrompt(from data: Data, last: Bool) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        var result = ""
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "user",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] else { continue }

            let prompt: String
            if let t = content as? String {
                prompt = String(t.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let arr = content as? [[String: Any]], let t = arr.first?["text"] as? String {
                prompt = String(t.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else { continue }

            if last { result = prompt } else { return prompt }
        }
        return result
    }

    private func extractCwd(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "user" else { continue }
            return obj["cwd"] as? String ?? ""
        }
        return ""
    }

    private func countMessages(sessionId: String) -> Int {
        let file = claudeProjectsDir.appendingPathComponent("\(sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { handle.closeFile() }
        var count = 0
        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            count += chunk.withUnsafeBytes { $0.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) } }
        }
        return count
    }

    // MARK: - History

    private func fetchHistorySessions(excluding active: Set<String>) -> [HistorySession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: claudeProjectsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }

        struct Candidate { let sid: String; let mtime: Date; let sizeKB: Int }
        var candidates: [Candidate] = []
        for file in files where file.pathExtension == "jsonl" {
            let sid = file.deletingPathExtension().lastPathComponent
            guard sid.count > 30, !active.contains(sid),
                  let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = attrs.contentModificationDate, let size = attrs.fileSize,
                  size / 1024 > 10 else { continue }
            candidates.append(Candidate(sid: sid, mtime: mtime, sizeKB: size / 1024))
        }
        candidates.sort { $0.mtime > $1.mtime }
        return candidates.prefix(10).map {
            HistorySession(sessionId: $0.sid, meta: readSessionMeta(sessionId: $0.sid),
                           lastModified: $0.mtime, messageCount: countMessages(sessionId: $0.sid), sizeKB: $0.sizeKB)
        }
    }

    // MARK: - Closed Tab Persistence

    private lazy var closedTabsFile: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/kittyswitch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("closed_tabs.json")
    }()

    private func saveClosedTabs() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(closedTabs) else { return }
        try? data.write(to: closedTabsFile, options: .atomic)
    }

    private func loadClosedTabs() -> [ClosedTab] {
        guard let data = try? Data(contentsOf: closedTabsFile) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        return ((try? dec.decode([ClosedTab].self, from: data)) ?? []).filter { $0.closedAt > cutoff }
    }

    // MARK: - Helpers

    private func shortenCommand(_ cmd: String) -> String { (cmd as NSString).lastPathComponent }

    private func resourcesForTab(_ tab: KittyTab) -> TabResources? {
        guard let win = tab.windows.first else { return nil }
        return tabResourceCache[win.pid]
    }

    func formatRSS(_ mb: Double) -> String {
        mb < 1 ? "<1MB" : mb >= 1024 ? String(format: "%.1fGB", mb / 1024) : String(format: "%.0fMB", mb)
    }

    @discardableResult
    private func shell(_ args: String...) -> String? { shell(args) }

    @discardableResult
    private func shell(_ args: [String]) -> String? {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    func truncate(_ text: String, to max: Int) -> String {
        text.count > max ? String(text.prefix(max - 3)) + "..." : text
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Lazy Submenu

class LazyTabMenu: NSMenu, NSMenuDelegate {
    let ad: AppDelegate
    let tab: KittyTab
    let claudeInfo: ClaudeInfo?
    let resources: TabResources?
    var built = false

    init(appDelegate: AppDelegate, tab: KittyTab, claudeInfo: ClaudeInfo?, resources: TabResources?) {
        self.ad = appDelegate; self.tab = tab; self.claudeInfo = claudeInfo; self.resources = resources
        super.init(title: "")
        self.delegate = self
        addItem(NSMenuItem(title: "Loading...", action: nil, keyEquivalent: ""))
    }

    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !built else { return }
        built = true
        removeAllItems()

        let italicFont = NSFont(descriptor: NSFont.systemFont(ofSize: 10).fontDescriptor.withSymbolicTraits(.italic), size: 10)
            ?? NSFont.systemFont(ofSize: 10)
        let italicAttrs: [NSAttributedString.Key: Any] = [.font: italicFont, .foregroundColor: NSColor.tertiaryLabelColor]

        // Session info
        if let info = claudeInfo {
            let si = NSMenuItem(title: info.sessionId, action: #selector(AppDelegate.copyText(_:)), keyEquivalent: "")
            si.target = ad; si.representedObject = info.sessionId; si.toolTip = "Click to copy session ID"
            let sAttr = NSMutableAttributedString()
            sAttr.append(ad.styled("⏣ ", size: 11, color: .systemOrange))
            sAttr.append(ad.styled(info.sessionId, size: 10, color: .secondaryLabelColor, mono: true))
            si.attributedTitle = sAttr
            addItem(si)

            let flags = info.args.filter { $0.hasPrefix("--") && $0 != "--resume" }
            if !flags.isEmpty {
                let fl = NSMenuItem(); fl.isEnabled = false
                fl.attributedTitle = ad.styled("  \(flags.joined(separator: " "))", size: 10, color: .tertiaryLabelColor, mono: true)
                addItem(fl)
            }

            let meta = ad.readSessionMeta(sessionId: info.jsonlSessionId)
            if !meta.firstPrompt.isEmpty {
                let mi = NSMenuItem(); mi.isEnabled = false
                mi.attributedTitle = NSAttributedString(string: "  first: \(ad.truncate(meta.firstPrompt, to: 45))", attributes: italicAttrs)
                addItem(mi)
            }
            if !meta.lastPrompt.isEmpty {
                let mi = NSMenuItem(); mi.isEnabled = false
                mi.attributedTitle = NSAttributedString(string: "  last:  \(ad.truncate(meta.lastPrompt, to: 45))", attributes: italicAttrs)
                addItem(mi)
            }
            addItem(.separator())
        }

        // Process tree
        if let res = resources, let rootPid = tab.windows.first?.pid {
            let hdr = NSMenuItem(); hdr.isEnabled = false
            hdr.attributedTitle = ad.styled("Processes", size: 11, color: .secondaryLabelColor)
            addItem(hdr)

            let procMap = Dictionary(uniqueKeysWithValues: res.processes.map { ($0.pid, $0) })
            var childrenMap: [Int: [ProcessInfo]] = [:]
            for proc in res.processes { childrenMap[proc.ppid, default: []].append(proc) }

            func addNode(_ pid: Int, prefix: String, isLast: Bool, isRoot: Bool) {
                guard let proc = procMap[pid] else { return }
                let indent = prefix.replacingOccurrences(of: " ", with: "\u{2007}")
                let connector = isRoot ? "" : (isLast ? "└\u{2007}" : "├\u{2007}")
                let rss = ad.formatRSS(proc.rssMB)
                let cpu = proc.cpu < 0.1 ? "0%" : String(format: "%.1f%%", proc.cpu)
                let dotColor: NSColor = proc.rssMB > 100 ? .systemRed : proc.rssMB > 10 ? .systemYellow : .tertiaryLabelColor

                let pi = NSMenuItem(title: proc.command, action: #selector(AppDelegate.killProcess(_:)), keyEquivalent: "")
                pi.target = ad; pi.tag = proc.pid; pi.toolTip = "Click to send SIGTERM to PID \(proc.pid)"
                let pAttr = NSMutableAttributedString()
                if !indent.isEmpty || !connector.isEmpty { pAttr.append(ad.styled("\(indent)\(connector)", size: 11, color: .tertiaryLabelColor, mono: true)) }
                pAttr.append(ad.styled("● ", size: 8, color: dotColor))
                pAttr.append(ad.styled(proc.command, size: 12))
                pAttr.append(ad.styled("  \(rss)  \(cpu)", size: 10, color: .secondaryLabelColor, mono: true))
                pAttr.append(ad.styled("  \(proc.pid)", size: 9, color: .tertiaryLabelColor, mono: true))
                pi.attributedTitle = pAttr
                addItem(pi)

                for (i, child) in (childrenMap[pid] ?? []).enumerated() {
                    addNode(child.pid, prefix: prefix + (isLast ? "  " : "│ "), isLast: i == (childrenMap[pid]?.count ?? 1) - 1, isRoot: false)
                }
            }
            addNode(rootPid, prefix: "", isLast: true, isRoot: true)
            addItem(.separator())
        }

        let ct = NSMenuItem(title: "Close Tab", action: #selector(AppDelegate.closeKittyTab(_:)), keyEquivalent: "")
        ct.target = ad; ct.tag = tab.id
        ct.attributedTitle = ad.styled("✕  Close Tab", size: 12, color: .systemRed)
        addItem(ct)
    }
}

// MARK: - Entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
