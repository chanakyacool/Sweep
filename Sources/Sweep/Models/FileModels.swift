import CryptoKit
import Foundation
import SwiftUI

// MARK: - Large & old files

enum FileKind: String, CaseIterable, Identifiable {
    case video = "Video", audio = "Audio", image = "Image", archive = "Archive"
    case diskImage = "Disk Image", document = "Document", other = "Other"

    var id: String { rawValue }

    private static let table: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = kind }
        }
        add(.video, "mp4 mov mkv avi m4v wmv flv webm mpg mpeg ts")
        add(.audio, "mp3 wav aiff flac m4a aac ogg caf")
        add(.image, "jpg jpeg png heic tiff tif raw cr2 nef arw psd gif bmp dng")
        add(.archive, "zip tar gz tgz bz2 xz 7z rar zst jar war")
        add(.diskImage, "dmg iso img pkg xip vmdk qcow2 vdi ova")
        add(.document, "pdf doc docx xls xlsx ppt pptx csv json sql txt log epub")
        return map
    }()

    static func of(_ name: String) -> FileKind {
        table[(name as NSString).pathExtension.lowercased()] ?? .other
    }
}

struct FileHit: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let size: Int64
    let modified: Date
    let kindName: String

    var folder: String { Fmt.tilde((path as NSString).deletingLastPathComponent) }
}

enum AgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age", month = "Older than 1 month", halfYear = "Older than 6 months", year = "Older than 1 year"
    var id: String { rawValue }
    var cutoff: Date? {
        switch self {
        case .any: return nil
        case .month: return Date().addingTimeInterval(-30 * 86_400)
        case .halfYear: return Date().addingTimeInterval(-182 * 86_400)
        case .year: return Date().addingTimeInterval(-365 * 86_400)
        }
    }
}

enum LargeFileScanner {
    /// Finds files of at least `minimum` bytes under the home folder, ignoring app data and packages.
    static func scan(minimum: Int64, report: ProgressReport, cancel: CancelFlag) -> [FileHit] {
        var hits: [FileHit] = []
        var visited = 0
        FS.walk(FS.home) { kind, entry in
            visited += 1
            if visited % 2_048 == 0 {
                if cancel.isCancelled { return .stop }
                if kind == .directory { report(Fmt.tilde(entry.path)) }
            }
            switch kind {
            case .directory:
                guard entry.level > 0 else { return .proceed }
                let name = entry.name
                if name.hasPrefix(".") || FS.isPackage(name) { return .skip }
                if entry.level == 1, name == "Library" || name == "Applications" { return .skip }
                return Prefs.isExcluded(entry.path) ? .skip : .proceed
            case .file:
                guard entry.size >= minimum, !entry.isDataless else { return .proceed }
                let name = entry.name
                guard !name.hasPrefix(".") else { return .proceed }
                hits.append(FileHit(path: entry.path, name: name, size: entry.size,
                                    modified: entry.modified, kindName: FileKind.of(name).rawValue))
                return .proceed
            case .directoryEnd:
                return .proceed
            }
        }
        return hits.sorted { $0.size > $1.size }
    }
}

@MainActor
final class LargeFilesModel: ObservableObject {
    @Published private(set) var results: [FileHit] = []
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var progress = ""
    @Published private(set) var lastOutcome: Remover.Outcome?
    @Published var selection = Set<String>()
    @Published var sortOrder = [KeyPathComparator(\FileHit.size, order: .reverse)]
    @Published var ageFilter: AgeFilter = .any
    @Published var kindFilter: String = "All"
    @Published var search = ""

    private var cancelFlag = CancelFlag()

    var filtered: [FileHit] {
        let cutoff = ageFilter.cutoff
        let needle = search.lowercased()
        return results.filter { hit in
            if let cutoff, hit.modified > cutoff { return false }
            if kindFilter != "All", hit.kindName != kindFilter { return false }
            if !needle.isEmpty, !hit.path.lowercased().contains(needle) { return false }
            return true
        }.sorted(using: sortOrder)
    }

    var totalSize: Int64 { results.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { results.reduce(0) { $0 + (selection.contains($1.id) ? $1.size : 0) } }

    func scan() { Task { await scanAndWait() } }

    func scanAndWait() async {
        guard state != .scanning, state != .cleaning else { return }
        state = .scanning
        progress = "Preparing…"
        lastOutcome = nil
        selection = []
        let flag = CancelFlag()
        cancelFlag = flag
        let minimum = Prefs.largeMinBytes
        let report: ProgressReport = { [weak self] text in Task { @MainActor in self?.progress = text } }
        let found = await Task.detached(priority: .userInitiated) {
            LargeFileScanner.scan(minimum: minimum, report: report, cancel: flag)
        }.value
        results = flag.isCancelled ? [] : found
        state = flag.isCancelled ? .idle : .ready
    }

    func cancel() { cancelFlag.cancel() }

    func removeSelected() async {
        guard state == .ready, !selection.isEmpty else { return }
        state = .cleaning
        let targets = results.filter { selection.contains($0.id) }.map { Remover.Target(path: $0.path, size: $0.size) }
        let permanently = Prefs.permanentDelete
        let outcome = await Task.detached { Remover.remove(targets, permanently: permanently, logAs: "Large & Old Files") }.value
        results.removeAll { selection.contains($0.id) && !FS.exists($0.path) }
        selection = []
        lastOutcome = outcome
        state = .ready
    }
}

// MARK: - Duplicates

struct DuplicateFile: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let modified: Date
}

struct DuplicateGroup: Identifiable, Sendable {
    let id: String          // content hash
    let size: Int64
    var files: [DuplicateFile]

    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
    var name: String { (files.first?.path as NSString?)?.lastPathComponent ?? "" }
}

enum DuplicateScanner {
    /// Three-stage match: identical size, then a cheap head/tail hash, then a full SHA-256.
    /// Only byte-for-byte identical files end up in the same group.
    static func scan(roots: [String], minimum: Int64, report: ProgressReport, cancel: CancelFlag) -> [DuplicateGroup] {
        struct Candidate { let path: String; let modified: Date; let allocated: Int64 }
        var bySize: [Int64: [Candidate]] = [:]
        var seenInodes = Set<UInt64>()
        var visited = 0

        for root in roots {
            FS.walk(root) { kind, entry in
                visited += 1
                if visited % 2_048 == 0 {
                    if cancel.isCancelled { return .stop }
                    if kind == .directory { report("Indexing " + Fmt.tilde(entry.path)) }
                }
                switch kind {
                case .directory:
                    guard entry.level > 0 else { return .proceed }
                    let name = entry.name
                    if name.hasPrefix(".") || FS.isPackage(name) || Prefs.isExcluded(entry.path) { return .skip }
                    return .proceed
                case .file:
                    let logical = entry.logicalSize
                    guard logical >= minimum, !entry.isDataless, !entry.name.hasPrefix(".") else { return .proceed }
                    // The same inode reached twice is one file, not a duplicate.
                    guard seenInodes.insert(entry.inode).inserted else { return .proceed }
                    bySize[logical, default: []].append(Candidate(path: entry.path, modified: entry.modified, allocated: entry.size))
                    return .proceed
                case .directoryEnd:
                    return .proceed
                }
            }
            if cancel.isCancelled { return [] }
        }

        let sizeMatches = bySize.filter { $0.value.count > 1 }
        let total = sizeMatches.values.reduce(0) { $0 + $1.count }
        var processed = 0
        var groups: [DuplicateGroup] = []

        for (size, candidates) in sizeMatches {
            if cancel.isCancelled { return [] }
            var byQuickHash: [String: [Candidate]] = [:]
            for candidate in candidates {
                processed += 1
                if processed % 25 == 0 { report("Comparing \(processed) of \(total) files") }
                if let digest = hash(candidate.path, quick: true) { byQuickHash[digest, default: []].append(candidate) }
            }
            for bucket in byQuickHash.values where bucket.count > 1 {
                if cancel.isCancelled { return [] }
                var byFullHash: [String: [Candidate]] = [:]
                // Files no larger than the sampled region were already hashed in full.
                let quickIsComplete = size <= 2 * sampleLength
                for candidate in bucket {
                    let digest = quickIsComplete ? hash(candidate.path, quick: true) : hash(candidate.path, quick: false)
                    if let digest { byFullHash[digest, default: []].append(candidate) }
                }
                for (digest, same) in byFullHash where same.count > 1 {
                    let files = same.sorted { $0.modified < $1.modified }.map { DuplicateFile(path: $0.path, modified: $0.modified) }
                    groups.append(DuplicateGroup(id: digest, size: same[0].allocated, files: files))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    private static let sampleLength: Int64 = 65_536

    static func hash(_ path: String, quick: Bool) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            if quick {
                hasher.update(data: try handle.read(upToCount: Int(sampleLength)) ?? Data())
                let end = try handle.seekToEnd()
                if end > UInt64(2 * sampleLength) {
                    try handle.seek(toOffset: end - UInt64(sampleLength))
                    hasher.update(data: try handle.read(upToCount: Int(sampleLength)) ?? Data())
                }
            } else {
                while true {
                    let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) ?? Data() }
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var roots: [String] = ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"]
        .map { FS.home + "/" + $0 }.filter(FS.isDirectory)
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var progress = ""
    @Published private(set) var lastOutcome: Remover.Outcome?
    @Published var selection = Set<String>()

    private var cancelFlag = CancelFlag()

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    var selectedSize: Int64 {
        groups.reduce(0) { sum, group in
            sum + group.size * Int64(group.files.filter { selection.contains($0.id) }.count)
        }
    }

    /// Groups in which every copy is selected, i.e. nothing would be left.
    var fullySelectedGroups: Int {
        groups.filter { group in group.files.allSatisfy { selection.contains($0.id) } }.count
    }

    func scan() {
        guard state != .scanning, state != .cleaning, !roots.isEmpty else { return }
        state = .scanning
        progress = "Preparing…"
        lastOutcome = nil
        selection = []
        let flag = CancelFlag()
        cancelFlag = flag
        let roots = self.roots
        let minimum = Prefs.duplicateMinBytes
        let report: ProgressReport = { [weak self] text in Task { @MainActor in self?.progress = text } }
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DuplicateScanner.scan(roots: roots, minimum: minimum, report: report, cancel: flag)
            }.value
            groups = flag.isCancelled ? [] : found
            state = flag.isCancelled ? .idle : .ready
        }
    }

    func cancel() { cancelFlag.cancel() }

    /// Returns to the folder-selection screen.
    func reset() {
        guard state == .ready else { return }
        groups = []
        selection = []
        lastOutcome = nil
        state = .idle
    }

    /// Selects every copy except the oldest in each group.
    func autoSelect() {
        selection = Set(groups.flatMap { $0.files.dropFirst().map(\.id) })
    }

    func removeSelected() async {
        guard state == .ready, !selection.isEmpty else { return }
        state = .cleaning
        let targets = groups.flatMap { group in
            group.files.filter { selection.contains($0.id) }.map { Remover.Target(path: $0.path, size: group.size) }
        }
        let permanently = Prefs.permanentDelete
        let outcome = await Task.detached { Remover.remove(targets, permanently: permanently, logAs: "Duplicates") }.value
        for index in groups.indices {
            groups[index].files.removeAll { selection.contains($0.id) && !FS.exists($0.path) }
        }
        groups.removeAll { $0.files.count < 2 }
        selection = []
        lastOutcome = outcome
        state = .ready
    }
}
