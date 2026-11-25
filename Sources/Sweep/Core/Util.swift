import AppKit
import Foundation

// MARK: - Formatting

enum Fmt {
    private static func formatter(_ style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowsNonnumericFormatting = false   // "0 KB" rather than "Zero KB"
        return f
    }

    private static let fileFormatter = formatter(.file)
    private static let memoryFormatter = formatter(.memory)

    static func bytes(_ n: Int64) -> String {
        fileFormatter.string(fromByteCount: max(0, n))
    }

    static func bytes(_ n: UInt64) -> String { bytes(Int64(clamping: n)) }

    static func memory(_ n: UInt64) -> String {
        memoryFormatter.string(fromByteCount: Int64(clamping: n))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let medium: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func ago(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }

    static func date(_ date: Date) -> String { medium.string(from: date) }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let (d, h, m) = (s / 86_400, (s % 86_400) / 3_600, (s % 3_600) / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Replaces the home directory prefix with `~` for display.
    static func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Cancellation

/// A thread-safe flag that long-running scans poll to stop early.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }
}

// MARK: - Shell

enum Shell {
    struct Output {
        let status: Int32
        let text: String
        var ok: Bool { status == 0 }
    }

    /// Runs an executable and returns its combined stdout and stderr.
    /// Pass `mergeErrors: false` when the output is parsed (for example JSON) and warnings must not pollute it.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 120, mergeErrors: Bool = true) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Apps launched from Finder get a minimal PATH; tools such as Homebrew and Docker expect more.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeErrors ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return Output(status: -1, text: error.localizedDescription)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Output(status: process.terminationStatus, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs a shell command line through `/bin/sh`.
    @discardableResult
    static func sh(_ command: String, timeout: TimeInterval = 120) -> Output {
        run("/bin/sh", ["-c", command], timeout: timeout)
    }

    /// Runs a shell command as root. macOS shows its standard administrator password prompt.
    static func admin(_ command: String) -> Output {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript",
                   ["-e", "do shell script \"\(escaped)\" with administrator privileges"],
                   timeout: 900)
    }

    /// Quotes a string for safe use as a single shell argument.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Locates a command-line tool by checking the file system only, so it is safe to call from any thread.
    static func which(_ tool: String) -> String? {
        let home = NSHomeDirectory()
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let wellKnown = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                         "\(home)/.docker/bin", "\(home)/.orbstack/bin", "\(home)/.kiri/bin", "\(home)/.local/bin"]
        for directory in wellKnown + inherited where FileManager.default.isExecutableFile(atPath: "\(directory)/\(tool)") {
            return "\(directory)/\(tool)"
        }
        return nil
    }
}

// MARK: - Finder helpers

enum Finder {
    static func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func icon(_ path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openFullDiskAccessSettings() {
        openSettings("com.apple.preference.security?Privacy_AllFiles")
    }

    /// Presents a folder picker and returns the chosen paths.
    @MainActor
    static func chooseFolders(multiple: Bool = true, prompt: String = "Choose") -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }
}

// MARK: - Preferences

enum Prefs {
    private static var defaults: UserDefaults { .standard }

    enum Key {
        static let permanentDelete = "permanentDelete"
        static let largeMinMB = "largeMinMB"
        static let duplicateMinKB = "duplicateMinKB"
        static let exclusions = "exclusions"
        static let scheduleDays = "scheduleDays"
        static let lowDiskGB = "lowDiskGB"
        static let junkAlertGB = "junkAlertGB"
        static let lastScheduledScan = "lastScheduledScan"
        static let lastLowDiskAlert = "lastLowDiskAlert"
    }

    /// Days between automatic junk scans; 0 turns them off.
    static var scheduleDays: Int { defaults.integer(forKey: Key.scheduleDays) }
    /// Free-space level in GB below which Sweep warns; 0 turns the warning off.
    static var lowDiskGB: Int { defaults.integer(forKey: Key.lowDiskGB) }
    /// Minimum junk in GB for a scheduled scan to notify.
    static var junkAlertGB: Int { defaults.object(forKey: Key.junkAlertGB) as? Int ?? 2 }

    static var lastScheduledScan: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Key.lastScheduledScan)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastScheduledScan) }
    }

    static var lastLowDiskAlert: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Key.lastLowDiskAlert)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastLowDiskAlert) }
    }

    static var permanentDelete: Bool { defaults.bool(forKey: Key.permanentDelete) }

    static var largeMinBytes: Int64 {
        let mb = defaults.integer(forKey: Key.largeMinMB)
        return Int64(mb > 0 ? mb : 100) * 1_000_000
    }

    static var duplicateMinBytes: Int64 {
        let kb = defaults.integer(forKey: Key.duplicateMinKB)
        return Int64(kb > 0 ? kb : 1_000) * 1_000
    }

    static var exclusions: [String] {
        get { defaults.stringArray(forKey: Key.exclusions) ?? [] }
        set { defaults.set(newValue, forKey: Key.exclusions) }
    }

    static func isExcluded(_ path: String) -> Bool {
        exclusions.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

// MARK: - Permissions

enum Permissions {
    /// Full Disk Access is inferred by probing a file only readable with that entitlement.
    static var hasFullDiskAccess: Bool {
        let probe = FS.home + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
        try? handle.close()
        return true
    }
}
