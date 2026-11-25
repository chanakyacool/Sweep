import AppKit
import Foundation

/// Fast file-system traversal built on `fts(3)`, which is several times quicker than
/// `FileManager.enumerator` for the large trees a disk cleaner has to measure.
enum FS {
    static let home = NSHomeDirectory()

    /// Bundle-like directories that are treated as a single opaque item.
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "xpc",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx",
        "xcodeproj", "xcworkspace", "xcarchive", "playground", "lproj", "sparsebundle",
        "pages", "numbers", "key", "rtfd", "band", "aplibrary", "photolibrary",
    ]

    static func isPackage(_ name: String) -> Bool {
        packageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    enum Kind { case directory, file, directoryEnd }
    enum Action { case proceed, skip, stop }

    /// A lightweight view over the current `fts` entry. Valid only inside the walk callback.
    struct Entry {
        fileprivate let pointer: UnsafeMutablePointer<FTSENT>

        var path: String { String(cString: pointer.pointee.fts_path) }

        var name: String {
            if pointer.pointee.fts_level == 0 { return (path as NSString).lastPathComponent }
            let offset = Int(pointer.pointee.fts_pathlen) - Int(pointer.pointee.fts_namelen)
            return String(cString: pointer.pointee.fts_path + offset)
        }

        var level: Int { Int(pointer.pointee.fts_level) }
        private var info: stat { pointer.pointee.fts_statp.pointee }

        /// Space actually allocated on disk, which is what gets freed on deletion.
        var size: Int64 { Int64(info.st_blocks) * 512 }
        var logicalSize: Int64 { Int64(info.st_size) }
        var modified: Date { Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) }
        var accessed: Date { Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec)) }
        var inode: UInt64 { UInt64(info.st_ino) }
        var hardLinks: Int { Int(info.st_nlink) }

        /// Cloud placeholders (iCloud, File Provider) whose content is not on this Mac.
        var isDataless: Bool { info.st_flags & 0x4000_0000 != 0 }
    }

    /// Walks `root` depth-first without following symbolic links or crossing volumes.
    /// Returning `.skip` for a directory prunes its subtree; its `.directoryEnd` is still delivered.
    static func walk(_ root: String, _ body: (Kind, Entry) -> Action) {
        guard let cRoot = strdup(root) else { return }
        defer { free(cRoot) }
        let argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let stream = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(stream) }

        while let entry = fts_read(stream) {
            let kind: Kind
            switch Int32(entry.pointee.fts_info) {
            case FTS_D: kind = .directory
            case FTS_F: kind = .file
            case FTS_DP, FTS_DNR: kind = .directoryEnd
            default: continue
            }
            switch body(kind, Entry(pointer: entry)) {
            case .proceed: break
            case .skip: if kind == .directory { fts_set(stream, entry, FTS_SKIP) }
            case .stop: return
            }
        }
    }

    /// Allocated size of a file or of an entire directory tree. Hard links are counted once.
    static func size(of path: String, cancel: CancelFlag? = nil) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return Int64(info.st_blocks) * 512 }

        var total: Int64 = 0
        var seenInodes = Set<UInt64>()
        var visited = 0
        walk(path) { kind, entry in
            visited += 1
            if visited % 4_096 == 0, cancel?.isCancelled == true { return .stop }
            guard kind == .file else { return .proceed }
            if entry.hardLinks > 1, !seenInodes.insert(entry.inode).inserted { return .proceed }
            total += entry.size
            return .proceed
        }
        return total
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Full paths of the immediate children of a directory; empty when unreadable.
    static func children(of directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0 != ".DS_Store" && $0 != ".localized" }.map { "\(directory)/\($0)" }
    }

    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }
}

// MARK: - Removal

/// The single choke point through which Sweep deletes anything.
enum Remover {
    struct Target: Sendable {
        let path: String
        let size: Int64
    }

    struct Outcome: Sendable {
        var freed: Int64 = 0
        var removed = 0
        var failures: [String] = []
        /// Original path to its new location in the Trash, for items that can be put back.
        var trashed: [String: String] = [:]

        static func + (a: Outcome, b: Outcome) -> Outcome {
            Outcome(freed: a.freed + b.freed, removed: a.removed + b.removed, failures: a.failures + b.failures,
                    trashed: a.trashed.merging(b.trashed) { _, new in new })
        }
    }

    private static let protectedExact: Set<String> = {
        let h = FS.home
        var set: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/bin", "/sbin", "/usr",
            "/etc", "/var", "/tmp", "/private", "/opt", "/cores", "/dev",
            h, "\(h)/.Trash", "\(h)/Library/Application Support", "\(h)/Library/Preferences",
            "\(h)/Library/Containers", "\(h)/Library/Group Containers", "\(h)/Library/Caches",
            "\(h)/Library/Logs", "\(h)/Library/Mobile Documents", "\(h)/Library/Keychains",
        ]
        for folder in ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications"] {
            set.insert("\(h)/\(folder)")
        }
        return set
    }()

    private static let protectedPrefixes = ["/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/", "/private/var/db/"]

    /// Rejects anything that is a system location or a top-level user folder.
    static func isSafeToRemove(_ path: String) -> Bool {
        let standard = (path as NSString).standardizingPath
        guard standard.hasPrefix("/"), standard == path, !path.contains("/../") else { return false }
        if protectedExact.contains(standard) { return false }
        if protectedPrefixes.contains(where: standard.hasPrefix) { return false }
        if standard.hasPrefix(FS.home + "/Library/Keychains/") { return false }
        return standard.split(separator: "/").count >= 2
    }

    /// Removes items and records the result in the history under the given section name.
    static func remove(_ targets: [Target], permanently: Bool, viaFinderOnFailure: Bool = false, logAs section: String) -> Outcome {
        let outcome = remove(targets, permanently: permanently, viaFinderOnFailure: viaFinderOnFailure)
        History.shared.recordCleanup(section: section, targets: targets, outcome: outcome)
        return outcome
    }

    /// Moves items to the Trash, or deletes them outright when `permanently` is set.
    static func remove(_ targets: [Target], permanently: Bool, viaFinderOnFailure: Bool = false) -> Outcome {
        var outcome = Outcome()
        let manager = FileManager.default
        for target in targets {
            guard isSafeToRemove(target.path) else {
                outcome.failures.append("\(Fmt.tilde(target.path)): protected location")
                continue
            }
            guard FS.exists(target.path) else { continue }
            let url = URL(fileURLWithPath: target.path)
            do {
                if permanently {
                    try manager.removeItem(at: url)
                } else {
                    var location: NSURL?
                    try manager.trashItem(at: url, resultingItemURL: &location)
                    if let path = location?.path { outcome.trashed[target.path] = path }
                }
                outcome.freed += target.size
                outcome.removed += 1
            } catch {
                if viaFinderOnFailure, !permanently, trashWithFinder(target.path) {
                    outcome.freed += target.size
                    outcome.removed += 1
                } else {
                    outcome.failures.append("\(Fmt.tilde(target.path)): \(error.localizedDescription)")
                }
            }
        }
        return outcome
    }

    /// Finder can authenticate to trash root-owned items such as App Store apps.
    private static func trashWithFinder(_ path: String) -> Bool {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)"
        return Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120).ok && !FS.exists(path)
    }
}
