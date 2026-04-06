import Foundation

// Standalone tests for KittySwitch core logic.
// swiftc -O -o KittySwitchTest KittySwitchTest.swift && ./KittySwitchTest

// MARK: - Test Helpers

var passed = 0, failed = 0

func assert(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if cond { passed += 1; print("  ✓ \(msg)") }
    else { failed += 1; print("  ✗ \(msg)  [\(file):\(line)]") }
}

func shell(_ args: String...) -> String? {
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch { return nil }
}

func shortenPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func truncate(_ text: String, to max: Int) -> String {
    text.count > max ? String(text.prefix(max - 3)) + "..." : text
}

func formatRSS(_ mb: Double) -> String {
    mb < 1 ? "<1MB" : mb >= 1024 ? String(format: "%.1fGB", mb / 1024) : String(format: "%.0fMB", mb)
}

// MARK: - Tests

print("=== shortenPath ===")
let home = FileManager.default.homeDirectoryForCurrentUser.path
assert(shortenPath(home) == "~", "home → ~")
assert(shortenPath(home + "/Projects") == "~/Projects", "subdir")
assert(shortenPath("/usr/local") == "/usr/local", "non-home unchanged")
assert(shortenPath("") == "", "empty")

print("\n=== truncate ===")
assert(truncate("hello", to: 10) == "hello", "short unchanged")
assert(truncate("hello world!", to: 8) == "hello...", "long truncated")
assert(truncate("abc", to: 3) == "abc", "exact limit")
assert(truncate("abcd", to: 3) == "...", "one over")

print("\n=== formatRSS ===")
assert(formatRSS(0.5) == "<1MB", "sub-1MB")
assert(formatRSS(1.0) == "1MB", "1MB")
assert(formatRSS(512) == "512MB", "512MB")
assert(formatRSS(1024) == "1.0GB", "1GB")
assert(formatRSS(2560) == "2.5GB", "2.5GB")

print("\n=== kitty @ ls JSON decode ===")
struct KittyOSWindow: Codable { let id: Int; let isActive: Bool; let tabs: [KittyTab]
    enum CodingKeys: String, CodingKey { case id, tabs; case isActive = "is_active" } }
struct KittyTab: Codable { let id: Int; let title: String; let isActive: Bool; let layout: String; let windows: [KittyWindow]
    enum CodingKeys: String, CodingKey { case id, title, layout, windows; case isActive = "is_active" } }
struct KittyWindow: Codable { let id: Int; let pid: Int; let cwd: String; let cmdline: [String]; let foregroundProcesses: [FGProcess]
    enum CodingKeys: String, CodingKey { case id, pid, cwd, cmdline; case foregroundProcesses = "foreground_processes" } }
struct FGProcess: Codable { let pid: Int; let cmdline: [String] }

if let output = shell("kitty", "@", "ls"), let data = output.data(using: .utf8),
   let osWindows = try? JSONDecoder().decode([KittyOSWindow].self, from: data) {
    assert(!osWindows.isEmpty, "decoded OS windows")
    let tabs = osWindows.flatMap(\.tabs)
    assert(!tabs.isEmpty, "has tabs")
    assert(tabs.first?.layout.count ?? 0 > 0, "tab has layout field")
    assert(tabs.first?.windows.first?.cmdline.count ?? 0 > 0, "window has cmdline field")
    print("  Tabs: \(tabs.count)")
} else {
    assert(false, "kitty @ ls decode failed")
}

print("\n=== ps -eo parse (two-pass) ===")
if let psOutput = shell("ps", "-eo", "pid=,ppid=,rss=,%cpu=,comm=") {
    var ppidOf: [Int: Int] = [:]
    var children: [Int: [Int]] = [:]
    for line in psOutput.split(separator: "\n") {
        let trimmed = line.drop(while: { $0 == " " })
        guard let si = trimmed.firstIndex(of: " "), let pid = Int(trimmed[..<si]) else { continue }
        let rest = trimmed[si...].drop(while: { $0 == " " })
        guard let si2 = rest.firstIndex(of: " "), let ppid = Int(rest[..<si2]) else { continue }
        ppidOf[pid] = ppid
        children[ppid, default: []].append(pid)
    }
    assert(ppidOf.count > 100, "parsed \(ppidOf.count) processes")
    assert(ppidOf[1] == 0, "PID 1 parent is 0")
    assert(children[1]?.count ?? 0 > 5, "launchd has children")
} else {
    assert(false, "ps -eo failed")
}

print("\n=== session files ===")
struct ClaudeSessionFile: Codable { let pid: Int; let sessionId: String; let cwd: String; let startedAt: Int64 }
let sessDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
if let files = try? FileManager.default.contentsOfDirectory(at: sessDir, includingPropertiesForKeys: nil) {
    var sessions: [Int: ClaudeSessionFile] = [:]
    for f in files where f.pathExtension == "json" {
        if let d = try? Data(contentsOf: f), let sf = try? JSONDecoder().decode(ClaudeSessionFile.self, from: d) {
            sessions[sf.pid] = sf
        }
    }
    assert(!sessions.isEmpty, "loaded \(sessions.count) session files")
    if let (pid, sf) = sessions.first {
        assert(sf.pid == pid, "PID key matches content")
        assert(sf.sessionId.count > 30, "sessionId is UUID")
        assert(!sf.cwd.isEmpty, "cwd non-empty")
    }
}

print("\n=== JSONL prompt extraction ===")
let projDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects/-Users-rand")
if let jsonls = try? FileManager.default.contentsOfDirectory(at: projDir, includingPropertiesForKeys: [.fileSizeKey]),
   let testFile = jsonls.filter({ $0.pathExtension == "jsonl" }).first(where: {
       (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 50000
   }) {
    let handle = try! FileHandle(forReadingFrom: testFile)
    let head = handle.readData(ofLength: 65536)
    let text = String(data: head, encoding: .utf8) ?? ""

    // First prompt
    var firstPrompt = ""
    for line in text.components(separatedBy: "\n") where !line.isEmpty {
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              obj["type"] as? String == "user",
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] else { continue }
        if let t = content as? String { firstPrompt = String(t.prefix(80)) }
        else if let arr = content as? [[String: Any]], let t = arr.first?["text"] as? String { firstPrompt = String(t.prefix(80)) }
        break
    }
    assert(!firstPrompt.isEmpty, "extracted first prompt: \(firstPrompt.prefix(40))...")

    // Last prompt from tail
    let fileSize = handle.seekToEndOfFile()
    if fileSize > 65536 {
        handle.seek(toFileOffset: fileSize - 65536)
        let tail = handle.readData(ofLength: 65536)
        let tailText = String(data: tail, encoding: .utf8) ?? ""
        var lastPrompt = ""
        for line in tailText.components(separatedBy: "\n") where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "user",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] else { continue }
            if let t = content as? String { lastPrompt = String(t.prefix(80)) }
            else if let arr = content as? [[String: Any]], let t = arr.first?["text"] as? String { lastPrompt = String(t.prefix(80)) }
        }
        assert(!lastPrompt.isEmpty, "extracted last prompt: \(lastPrompt.prefix(40))...")
    }
    handle.closeFile()
}

print("\n=== ClosedTab serialization ===")
struct ClosedTab: Codable {
    let title: String; let cwd: String; let layout: String
    let shell: [String]; let foregroundCmd: [String]
    let closedAt: Date; let claudeSessionId: String?
}
let testClosed = [
    ClosedTab(title: "Test Tab", cwd: "/tmp", layout: "fat", shell: ["/bin/zsh"],
              foregroundCmd: ["vim", "test.txt"], closedAt: Date(), claudeSessionId: nil),
    ClosedTab(title: "Claude Tab", cwd: "/Users/test", layout: "tall", shell: ["/opt/homebrew/bin/fish"],
              foregroundCmd: ["claude", "--resume", "abc-123"], closedAt: Date().addingTimeInterval(-3600),
              claudeSessionId: "abc-123")
]
let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
if let data = try? enc.encode(testClosed), let decoded = try? dec.decode([ClosedTab].self, from: data) {
    assert(decoded.count == 2, "roundtrip count")
    assert(decoded[0].title == "Test Tab", "roundtrip title")
    assert(decoded[0].claudeSessionId == nil, "nil session preserved")
    assert(decoded[1].claudeSessionId == "abc-123", "session ID preserved")
    assert(abs(decoded[1].closedAt.timeIntervalSince(testClosed[1].closedAt)) < 1, "date preserved")

    // Expiry test
    let old = ClosedTab(title: "Old", cwd: "/", layout: "fat", shell: [], foregroundCmd: [],
                        closedAt: Date().addingTimeInterval(-8 * 86400), claudeSessionId: nil)
    let mixed = try! enc.encode([old] + testClosed)
    let filtered = (try! dec.decode([ClosedTab].self, from: mixed))
        .filter { $0.closedAt > Date().addingTimeInterval(-7 * 86400) }
    assert(filtered.count == 2, "expired entry filtered out")
} else {
    assert(false, "ClosedTab serialization failed")
}

print("\n=== pipe deadlock prevention ===")
// Verify large output doesn't deadlock (read before waitUntilExit)
if let output = shell("ps", "-eo", "pid=,ppid=,rss=,%cpu=,comm=") {
    assert(output.count > 50000, "large ps output received (\(output.count) bytes)")
} else {
    assert(false, "ps command failed (possible deadlock)")
}

print("\n=== Claude detection in foreground processes ===")
if let output = shell("kitty", "@", "ls"), let data = output.data(using: .utf8),
   let osWindows = try? JSONDecoder().decode([KittyOSWindow].self, from: data) {
    var claudeCount = 0
    for osWin in osWindows { for tab in osWin.tabs { for win in tab.windows {
        for proc in win.foregroundProcesses {
            if proc.cmdline.contains(where: { $0 == "claude" || $0.hasSuffix("/claude") }) {
                claudeCount += 1
            }
        }
    } } }
    assert(claudeCount > 0, "found \(claudeCount) Claude processes")
}

// Summary
print("\n=============================")
print("Results: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
