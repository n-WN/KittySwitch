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
    let lastPrompt: String
    let cwd: String

    static let empty = SessionMeta(firstPrompt: "", lastPrompt: "", cwd: "")
}

struct ClaudeInfo {
    let sessionId: String       // current session ID (from session file)
    let jsonlSessionId: String  // ID that maps to the .jsonl filename
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
        refreshDataInBackground()
        startTimer(interval: slowInterval)
    }

    // MARK: - Background Data Refresh

    /// Refresh data in background so menu opens instantly from cache.
    private func refreshDataInBackground() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // autoreleasepool ensures temporary strings from shell() and parsing
            // are freed promptly instead of accumulating in malloc's free pool.
            let (state, sessions, resources) = autoreleasepool { () -> ([KittyOSWindow], [Int: ClaudeSessionFile], [Int: TabResources]) in
                let state = self.fetchKittyState()
                let sessions = self.loadSessionFiles()
                var resources: [Int: TabResources] = [:]
                if !state.isEmpty {
                    resources = self.buildResourceMap(for: state)
                }
                return (state, sessions, resources)
            }

            // Return malloc's free pages to the OS
            malloc_zone_pressure_relief(nil, 0)

            DispatchQueue.main.async {
                self.cachedState = state
                self.sessionFileCache = sessions
                self.tabResourceCache = resources
                self.sessionMetaCache = [:]
                self.messageCountCache = [:]

                let tabCount = state.reduce(0) { $0 + $1.tabs.count }
                self.statusItem.button?.title = " \(tabCount)"
            }
        }
    }

    /// Build resource map using a single `ps -eo` call.
    /// Two-pass: first build pid→ppid tree (lightweight), then only parse full
    /// info for PIDs in the kitty subtrees.
    private func buildResourceMap(for state: [KittyOSWindow]) -> [Int: TabResources] {
        var shellPids = Set<Int>()
        for osWin in state {
            for tab in osWin.tabs {
                for win in tab.windows { shellPids.insert(win.pid) }
            }
        }
        guard !shellPids.isEmpty,
              let psData = shell("ps", "-eo", "pid=,ppid=,rss=,%cpu=,comm=")?.utf8
        else { return [:] }
        let psOutput = String(psData)

        // Pass 1: build pid→ppid map and children map (only parse first 2 columns)
        var ppidOf: [Int: Int] = [:]
        var children: [Int: [Int]] = [:]
        // Also store each line's range for pass 2
        var lineRanges: [Int: Substring] = [:]  // pid → full line

        for line in psOutput.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int(trimmed[trimmed.startIndex..<spaceIdx]) else { continue }

            let rest = trimmed[spaceIdx...].drop(while: { $0 == " " })
            guard let spaceIdx2 = rest.firstIndex(of: " ") else { continue }
            guard let ppid = Int(rest[rest.startIndex..<spaceIdx2]) else { continue }

            ppidOf[pid] = ppid
            children[ppid, default: []].append(pid)
            lineRanges[pid] = line
        }

        // Find all PIDs in kitty subtrees
        func descendants(of pid: Int) -> [Int] {
            var result = [pid]
            for child in children[pid] ?? [] { result.append(contentsOf: descendants(of: child)) }
            return result
        }

        var relevantPids = Set<Int>()
        for shellPid in shellPids {
            for pid in descendants(of: shellPid) { relevantPids.insert(pid) }
        }

        // Pass 2: full parse only for relevant PIDs (~30 instead of ~1000)
        var procMap: [Int: ProcessInfo] = [:]
        for pid in relevantPids {
            guard let line = lineRanges[pid] else { continue }
            let tokens = line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " })
            guard tokens.count >= 5,
                  let rss = Int(tokens[2]),
                  let cpu = Double(tokens[3]) else { continue }
            let cmd = tokens[4...].joined(separator: " ")
            procMap[pid] = ProcessInfo(
                pid: pid, ppid: ppidOf[pid] ?? 0,
                rssMB: Double(rss) / 1024, cpu: cpu,
                command: shortenCommand(cmd)
            )
        }

        var map: [Int: TabResources] = [:]
        for shellPid in shellPids {
            let procs = descendants(of: shellPid).compactMap { procMap[$0] }
            map[shellPid] = TabResources(processes: procs)
        }
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
        // Build menu instantly from cached data (0 ms)
        rebuildMenuFromCache()
        // Kick off a fresh background refresh for next open
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
        let title = truncate(tab.title, to: 50)
        let cwd = tab.windows.first.map { shortenPath($0.cwd) } ?? ""

        let item = NSMenuItem(title: title, action: #selector(focusTab(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tab.id
        item.state = tab.isActive ? .on : .off

        // Main line: icon + title + cwd + resource summary (from cache, no I/O)
        let res = resourcesForTab(tab)
        let attr = NSMutableAttributedString()
        if info != nil { attr.append(styled("◆ ", size: 13, color: .systemOrange)) }
        attr.append(styled(title, size: 13))
        attr.append(styled("  \(cwd)", size: 11, color: .secondaryLabelColor))
        if let res {
            let color: NSColor = res.totalRSS > 500 ? .systemOrange : .tertiaryLabelColor
            attr.append(styled("  \(formatResourceSummary(res))", size: 10, color: color, mono: true))
        }
        item.attributedTitle = attr

        // Lazy submenu — content built on hover, not during main menu construction
        let sub = LazyTabMenu(appDelegate: self, tab: tab, claudeInfo: info, resources: res)
        item.submenu = sub
        menu.addItem(item)
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

            let item = NSMenuItem(title: prompt, action: nil, keyEquivalent: "")

            let attr = NSMutableAttributedString()
            attr.append(styled("↻ ", size: 12, color: .systemBlue))
            attr.append(styled(prompt, size: 12))
            attr.append(styled("  \(time)  \(session.messageCount) msgs", size: 10, color: .tertiaryLabelColor))
            item.attributedTitle = attr

            // Submenu: info + resume actions
            let sub = NSMenu()

            // Session ID — click to copy
            let idItem = NSMenuItem(title: session.sessionId, action: #selector(copyText(_:)), keyEquivalent: "")
            idItem.target = self
            idItem.representedObject = session.sessionId
            idItem.toolTip = "Click to copy session ID"
            idItem.attributedTitle = styled("⏣  \(session.sessionId)", size: 10, color: .secondaryLabelColor, mono: true)
            sub.addItem(idItem)

            let cwdLabel = NSMenuItem()
            cwdLabel.isEnabled = false
            cwdLabel.attributedTitle = styled("  \(cwd)  ·  \(size)", size: 10, color: .tertiaryLabelColor)
            sub.addItem(cwdLabel)

            sub.addItem(.separator())

            // Resume actions
            let normalItem = NSMenuItem(title: "Resume", action: #selector(resumeSession(_:)), keyEquivalent: "")
            normalItem.target = self
            normalItem.representedObject = ResumeInfo(sessionId: session.sessionId, cwd: session.meta.cwd, dangerousMode: false)
            normalItem.attributedTitle = styled("▶  Resume", size: 12)
            sub.addItem(normalItem)

            let dangerItem = NSMenuItem(title: "Resume (skip permissions)", action: #selector(resumeSession(_:)), keyEquivalent: "")
            dangerItem.target = self
            dangerItem.representedObject = ResumeInfo(sessionId: session.sessionId, cwd: session.meta.cwd, dangerousMode: true)
            dangerItem.attributedTitle = styled("  Resume (skip permissions)", size: 12, color: .systemOrange)
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

    @objc func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func killProcess(_ sender: NSMenuItem) {
        let pid = sender.tag
        guard pid > 0 else { return }
        kill(Int32(pid), SIGTERM)
    }

    @objc func closeKittyTab(_ sender: NSMenuItem) {
        shell("kitty", "@", "close-tab", "--match", "id:\(sender.tag)")
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

                var sessionId: String?
                var jsonlId: String?
                var startedAt: Date?

                // Session file gives us the current (possibly new) session ID
                if let sf = sessionFileCache[proc.pid] {
                    sessionId = sf.sessionId
                    startedAt = Date(timeIntervalSince1970: Double(sf.startedAt) / 1000)
                }

                // --resume arg gives us the original session ID (= JSONL filename)
                if let ri = args.firstIndex(of: "--resume"), ri + 1 < args.count,
                   args[ri + 1].count > 30, args[ri + 1].contains("-") {
                    jsonlId = args[ri + 1]
                }

                // Resolve JSONL ID: --resume arg > session file ID > scan by content
                var resolvedJsonlId = [jsonlId, sessionId].compactMap { $0 }.first {
                    FileManager.default.fileExists(atPath:
                        claudeProjectsDir.appendingPathComponent("\($0).jsonl").path)
                }

                // For auto-resume, search all project dirs
                if resolvedJsonlId == nil, let sid = sessionId {
                    resolvedJsonlId = findJsonlForSession(sid)
                }

                // Still not found: will be resolved by mtime matching in a post-pass
                // Store unresolved sessions for later

                guard let sid = sessionId ?? jsonlId else { continue }

                return ClaudeInfo(
                    sessionId: sid,
                    jsonlSessionId: resolvedJsonlId ?? sid,
                    pid: proc.pid,
                    args: args,
                    meta: .empty,
                    startedAt: startedAt ?? Date(),
                    messageCount: 0
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

    /// Find the JSONL file for a session. Tries:
    /// 1. Direct filename match in all project dirs
    /// 2. Mtime-based matching for resumed sessions whose PID file ID differs from JSONL filename
    private func findJsonlForSession(_ targetId: String) -> String? {
        let projectsBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsBase, includingPropertiesForKeys: nil
        ) else { return nil }

        // 1. Direct match
        for dir in projectDirs {
            let candidate = dir.appendingPathComponent("\(targetId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return targetId
            }
        }

        // 2. Mtime-based: find recently-modified JSOJNLs not already claimed by another session
        let claimedIds = Set(sessionFileCache.values.compactMap { sf -> String? in
            let path = claudeProjectsDir.appendingPathComponent("\(sf.sessionId).jsonl").path
            return FileManager.default.fileExists(atPath: path) ? sf.sessionId : nil
        })

        // Get recent JSONL files sorted by mtime desc
        guard let jsonls = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let candidates = jsonls.filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (String, Date)? in
                let sid = url.deletingPathExtension().lastPathComponent
                guard !claimedIds.contains(sid),
                      let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = attrs.contentModificationDate,
                      Date().timeIntervalSince(mtime) < 86400  // modified in last 24h
                else { return nil }
                return (sid, mtime)
            }
            .sorted { $0.1 > $1.1 }

        // Return the most recently modified unclaimed JSONL
        return candidates.first?.0
    }

    /// Resolve the project dir that contains a given session's JSONL.
    func resolveJsonlPath(sessionId: String) -> URL? {
        let projectsBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsBase, includingPropertiesForKeys: nil
        ) else { return nil }

        for dir in projectDirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - JSONL Reading

    func readSessionMeta(sessionId: String) -> SessionMeta {
        if let cached = sessionMetaCache[sessionId] { return cached }
        // Try primary project dir first, then search all dirs
        let file = resolveJsonlPath(sessionId: sessionId)
            ?? claudeProjectsDir.appendingPathComponent("\(sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .empty }
        defer { handle.closeFile() }

        // Read first user message from head (64KB)
        let headChunk = handle.readData(ofLength: 65536)
        let firstPrompt = extractFirstUserPrompt(from: headChunk)
        let cwd = extractCwd(from: headChunk)

        // Read last user message from tail (64KB)
        var lastPrompt = ""
        let fileSize = handle.seekToEndOfFile()
        if fileSize > 65536 {
            handle.seek(toFileOffset: fileSize - 65536)
            let tailChunk = handle.readData(ofLength: 65536)
            lastPrompt = extractLastUserPrompt(from: tailChunk)
        } else {
            // Small file — scan the head chunk for the last user message too
            lastPrompt = extractLastUserPrompt(from: headChunk)
        }
        if lastPrompt == firstPrompt { lastPrompt = "" }  // don't repeat

        let result = SessionMeta(firstPrompt: firstPrompt, lastPrompt: lastPrompt, cwd: cwd)
        sessionMetaCache[sessionId] = result
        return result
    }

    private func extractUserPrompt(from obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "user",
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"]
        else { return nil }

        if let text = content as? String {
            return String(text.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let arr = content as? [[String: Any]],
           let first = arr.first,
           let text = first["text"] as? String {
            return String(text.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func extractCwd(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "user"
            else { continue }
            return obj["cwd"] as? String ?? ""
        }
        return ""
    }

    private func extractFirstUserPrompt(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let prompt = extractUserPrompt(from: obj)
            else { continue }
            return prompt
        }
        return ""
    }

    private func extractLastUserPrompt(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        var last = ""
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let prompt = extractUserPrompt(from: obj)
            else { continue }
            last = prompt
        }
        return last
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

    // collectAllTabResources moved to buildResourceMap (runs off main thread)

    private func shortenCommand(_ cmd: String) -> String {
        // "/opt/homebrew/bin/fish" → "fish"
        let base = (cmd as NSString).lastPathComponent
        return base.isEmpty ? cmd : base
    }

    private func resourcesForTab(_ tab: KittyTab) -> TabResources? {
        guard let win = tab.windows.first else { return nil }
        return tabResourceCache[win.pid]
    }

    func formatRSS(_ mb: Double) -> String {
        mb < 1 ? "<1MB" : mb >= 1024 ? String(format: "%.1fGB", mb / 1024) : String(format: "%.0fMB", mb)
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
            // Read BEFORE waitUntilExit to avoid pipe buffer deadlock.
            // If output > 64KB (pipe buffer), the child blocks on write
            // while we block on waitUntilExit → deadlock.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    func truncate(_ text: String, to max: Int) -> String {
        text.count > max ? String(text.prefix(max - 3)) + "..." : text
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Lazy Submenu (built on hover, not during main menu construction)

class LazyTabMenu: NSMenu, NSMenuDelegate {
    let appDelegate: AppDelegate
    let tab: KittyTab
    let claudeInfo: ClaudeInfo?
    let resources: TabResources?
    var built = false

    init(appDelegate: AppDelegate, tab: KittyTab, claudeInfo: ClaudeInfo?, resources: TabResources?) {
        self.appDelegate = appDelegate
        self.tab = tab
        self.claudeInfo = claudeInfo
        self.resources = resources
        super.init(title: "")
        self.delegate = self
        // Placeholder so NSMenu shows the submenu arrow
        addItem(NSMenuItem(title: "Loading...", action: nil, keyEquivalent: ""))
    }

    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !built else { return }
        built = true
        removeAllItems()

        let ad = appDelegate
        let italicFont = NSFont(descriptor: NSFont.systemFont(ofSize: 10).fontDescriptor.withSymbolicTraits(.italic), size: 10) ?? NSFont.systemFont(ofSize: 10)
        let italicAttrs: [NSAttributedString.Key: Any] = [.font: italicFont, .foregroundColor: NSColor.tertiaryLabelColor]

        // Session info
        if let info = claudeInfo {
            let sessionItem = NSMenuItem(title: info.sessionId, action: #selector(AppDelegate.copyText(_:)), keyEquivalent: "")
            sessionItem.target = ad
            sessionItem.representedObject = info.sessionId
            sessionItem.toolTip = "Click to copy session ID"
            let sAttr = NSMutableAttributedString()
            sAttr.append(ad.styled("⏣ ", size: 11, color: .systemOrange))
            sAttr.append(ad.styled(info.sessionId, size: 10, color: .secondaryLabelColor, mono: true))
            sessionItem.attributedTitle = sAttr
            addItem(sessionItem)

            let flags = info.args.filter { $0.hasPrefix("--") && $0 != "--resume" }
            if !flags.isEmpty {
                let flagLabel = NSMenuItem()
                flagLabel.isEnabled = false
                flagLabel.attributedTitle = ad.styled("  \(flags.joined(separator: " "))", size: 10, color: .tertiaryLabelColor, mono: true)
                addItem(flagLabel)
            }

            // JSONL read happens HERE — only when submenu is opened
            let meta = ad.readSessionMeta(sessionId: info.jsonlSessionId)
            if !meta.firstPrompt.isEmpty {
                let first = NSMenuItem()
                first.isEnabled = false
                first.attributedTitle = NSAttributedString(string: "  first: \(ad.truncate(meta.firstPrompt, to: 45))", attributes: italicAttrs)
                addItem(first)
            }
            if !meta.lastPrompt.isEmpty {
                let last = NSMenuItem()
                last.isEnabled = false
                last.attributedTitle = NSAttributedString(string: "  last:  \(ad.truncate(meta.lastPrompt, to: 45))", attributes: italicAttrs)
                addItem(last)
            }
            addItem(.separator())
        }

        // Process tree
        if let res = resources, let rootPid = tab.windows.first?.pid {
            let header = NSMenuItem()
            header.isEnabled = false
            header.attributedTitle = ad.styled("Processes", size: 11, color: .secondaryLabelColor)
            addItem(header)

            // Build parent → children map
            let procMap = Dictionary(uniqueKeysWithValues: res.processes.map { ($0.pid, $0) })
            var childrenMap: [Int: [ProcessInfo]] = [:]
            for proc in res.processes {
                childrenMap[proc.ppid, default: []].append(proc)
            }

            // Recursive tree render
            func addTreeNode(_ pid: Int, prefix: String, isLast: Bool, isRoot: Bool) {
                guard let proc = procMap[pid] else { return }
                let rss = ad.formatRSS(proc.rssMB)
                let cpu = proc.cpu < 0.1 ? "0%" : String(format: "%.1f%%", proc.cpu)

                // Use figure space (U+2007) for indentation — NSMenu strips regular spaces
                let indent = prefix.replacingOccurrences(of: " ", with: "\u{2007}")
                let connector = isRoot ? "" : (isLast ? "└\u{2007}" : "├\u{2007}")
                let procItem = NSMenuItem(title: proc.command, action: #selector(AppDelegate.killProcess(_:)), keyEquivalent: "")
                procItem.target = ad
                procItem.tag = proc.pid

                let pAttr = NSMutableAttributedString()
                let dotColor: NSColor = proc.rssMB > 100 ? .systemRed : proc.rssMB > 10 ? .systemYellow : .tertiaryLabelColor
                if !indent.isEmpty || !connector.isEmpty {
                    pAttr.append(ad.styled("\(indent)\(connector)", size: 11, color: .tertiaryLabelColor, mono: true))
                }
                pAttr.append(ad.styled("● ", size: 8, color: dotColor))
                pAttr.append(ad.styled(proc.command, size: 12))
                pAttr.append(ad.styled("  \(rss)  \(cpu)", size: 10, color: .secondaryLabelColor, mono: true))
                pAttr.append(ad.styled("  \(proc.pid)", size: 9, color: .tertiaryLabelColor, mono: true))
                procItem.attributedTitle = pAttr
                procItem.toolTip = "Click to send SIGTERM to PID \(proc.pid)"
                addItem(procItem)

                let kids = childrenMap[pid] ?? []
                for (i, child) in kids.enumerated() {
                    let ext = isLast ? "  " : "│ "
                    addTreeNode(child.pid, prefix: prefix + ext, isLast: i == kids.count - 1, isRoot: false)
                }
                // Note: prefix uses regular spaces internally; converted to figure spaces at render time
            }

            addTreeNode(rootPid, prefix: "", isLast: true, isRoot: true)
            addItem(.separator())
        }

        // Close tab
        let closeTab = NSMenuItem(title: "Close Tab", action: #selector(AppDelegate.closeKittyTab(_:)), keyEquivalent: "")
        closeTab.target = ad
        closeTab.tag = tab.id
        closeTab.attributedTitle = ad.styled("✕  Close Tab", size: 12, color: .systemRed)
        addItem(closeTab)
    }
}

// MARK: - Entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
