import AppKit
import Foundation
import ImageIO
import SwiftUI

struct ImageHit: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    let modified: Date
    let width: Int
    let height: Int
    let fingerprint: UInt64

    var pixels: Int { width * height }
}

struct SimilarGroup: Identifiable, Sendable {
    var id: String { files.first?.path ?? "" }
    /// Best copy first: highest resolution, then largest file.
    var files: [ImageHit]

    /// Space recovered by keeping only the best copy.
    var reclaimable: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

enum SimilarImageScanner {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"]
    private static let maximumImages = 12_000
    /// Two fingerprints at most this many bits apart are treated as the same picture.
    private static let maximumDistance = 5

    /// Finds pictures that look alike (resized, re-compressed or lightly edited copies and burst shots)
    /// by comparing a 64-bit difference hash of each image.
    /// Files smaller than `minimumFileSize` are ignored; they are icons and thumbnails rather than photos.
    static func scan(roots: [String], minimumFileSize: Int64 = 30_000, report: @escaping ProgressReport, cancel: CancelFlag) -> [SimilarGroup] {
        struct Candidate { let path: String; let size: Int64; let modified: Date }
        var candidates: [Candidate] = []
        for root in roots {
            FS.walk(root) { kind, entry in
                if cancel.isCancelled || candidates.count >= maximumImages { return .stop }
                switch kind {
                case .directory:
                    guard entry.level > 0 else { return .proceed }
                    let name = entry.name
                    if candidates.count % 64 == 0 { report("Indexing " + Fmt.tilde(entry.path)) }
                    return name.hasPrefix(".") || FS.isPackage(name) || Prefs.isExcluded(entry.path) ? .skip : .proceed
                case .file:
                    let name = entry.name
                    guard entry.size >= minimumFileSize, !entry.isDataless, !name.hasPrefix("."),
                          extensions.contains((name as NSString).pathExtension.lowercased()) else { return .proceed }
                    candidates.append(Candidate(path: entry.path, size: entry.size, modified: entry.modified))
                    return .proceed
                case .directoryEnd:
                    return .proceed
                }
            }
        }
        guard !cancel.isCancelled, candidates.count > 1 else { return [] }

        // Fingerprinting decodes every image, so spread it across the cores.
        var hits = [ImageHit?](repeating: nil, count: candidates.count)
        let lock = NSLock()
        var done = 0
        hits.withUnsafeMutableBufferPointer { buffer in
            let storage = buffer
            DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
                if cancel.isCancelled { return }
                let candidate = candidates[index]
                let hit = fingerprint(candidate.path).map {
                    ImageHit(path: candidate.path, size: candidate.size, modified: candidate.modified,
                             width: $0.width, height: $0.height, fingerprint: $0.hash)
                }
                lock.lock()
                storage[index] = hit
                done += 1
                if done % 40 == 0 { report("Analysing \(done) of \(candidates.count) pictures") }
                lock.unlock()
            }
        }
        if cancel.isCancelled { return [] }
        let images = hits.compactMap { $0 }

        // Union-find over all pairs; a popcount per pair keeps this fast for thousands of images.
        var parent = Array(images.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for a in images.indices {
            if a % 500 == 0 {
                if cancel.isCancelled { return [] }
                report("Comparing pictures")
            }
            let first = images[a]
            let firstRatio = Double(first.width) / Double(max(first.height, 1))
            for b in (a + 1)..<images.count {
                let second = images[b]
                guard (first.fingerprint ^ second.fingerprint).nonzeroBitCount <= maximumDistance else { continue }
                let ratio = Double(second.width) / Double(max(second.height, 1))
                guard abs(ratio - firstRatio) / firstRatio < 0.06 else { continue }
                let (ra, rb) = (root(a), root(b))
                if ra != rb { parent[rb] = ra }
            }
        }
        var clusters: [Int: [ImageHit]] = [:]
        for index in images.indices { clusters[root(index), default: []].append(images[index]) }
        return clusters.values
            .filter { $0.count > 1 }
            .map { SimilarGroup(files: $0.sorted { ($0.pixels, $0.size) > ($1.pixels, $1.size) }) }
            .sorted { $0.reclaimable > $1.reclaimable }
    }

    /// A difference hash: the image is reduced to 9×8 grey pixels and each bit says whether a pixel is
    /// brighter than its right-hand neighbour. Scaling and re-compression barely change it.
    static func fingerprint(_ path: String) -> (hash: UInt64, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 72,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let (columns, rows) = (9, 8)
        var pixels = [UInt8](repeating: 0, count: columns * rows)
        guard let context = CGContext(data: &pixels, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: columns, height: rows))

        var hash: UInt64 = 0
        for row in 0..<rows {
            for column in 0..<(columns - 1) {
                hash <<= 1
                if pixels[row * columns + column] > pixels[row * columns + column + 1] { hash |= 1 }
            }
        }
        // Near-uniform pictures (blank scans, solid colours) all hash alike and would be false matches.
        guard (6...58).contains(hash.nonzeroBitCount) else { return nil }
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? thumbnail.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? thumbnail.height
        return (hash, width, height)
    }

    /// A display thumbnail, decoded off the main thread and cached.
    static func thumbnail(_ path: String, side: Int = 320) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(result, forKey: path as NSString)
        return result
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()
}

@MainActor
final class SimilarPhotosModel: ObservableObject {
    @Published var roots: [String] = ["Pictures", "Desktop", "Downloads", "Documents"]
        .map { FS.home + "/" + $0 }.filter(FS.isDirectory)
    @Published private(set) var groups: [SimilarGroup] = []
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var progress = ""
    @Published private(set) var lastOutcome: Remover.Outcome?
    @Published var selection = Set<String>()

    private var cancelFlag = CancelFlag()

    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }

    var selectedSize: Int64 {
        groups.reduce(0) { sum, group in sum + group.files.reduce(0) { $0 + (selection.contains($1.id) ? $1.size : 0) } }
    }

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
        let report: ProgressReport = { [weak self] text in Task { @MainActor in self?.progress = text } }
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                SimilarImageScanner.scan(roots: roots, report: report, cancel: flag)
            }.value
            groups = flag.isCancelled ? [] : found
            state = flag.isCancelled ? .idle : .ready
        }
    }

    func cancel() { cancelFlag.cancel() }

    func reset() {
        guard state == .ready else { return }
        groups = []
        selection = []
        lastOutcome = nil
        state = .idle
    }

    /// Selects everything except the best copy in each group.
    func autoSelect() {
        selection = Set(groups.flatMap { $0.files.dropFirst().map(\.id) })
    }

    func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func removeSelected() async {
        guard state == .ready, !selection.isEmpty else { return }
        state = .cleaning
        let targets = groups.flatMap(\.files).filter { selection.contains($0.id) }.map { Remover.Target(path: $0.path, size: $0.size) }
        let permanently = Prefs.permanentDelete
        let outcome = await Task.detached { Remover.remove(targets, permanently: permanently, logAs: "Similar Photos") }.value
        for index in groups.indices {
            groups[index].files.removeAll { selection.contains($0.id) && !FS.exists($0.path) }
        }
        groups.removeAll { $0.files.count < 2 }
        selection = []
        lastOutcome = outcome
        state = .ready
    }
}
