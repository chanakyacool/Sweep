import AppKit
import CoreServices
import Foundation
import SwiftUI

// MARK: - Uninstaller

struct InstalledApp: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String
    let version: String
    var size: Int64 = 0
    var lastUsed: Date?
}

struct Leftover: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    var selected: Bool
    let isSystemLevel: Bool
}

enum AppCatalog {
    static func installedApps() -> [InstalledApp] {
        var apps: [InstalledApp] = []
        let ownPath = Bundle.main.bundlePath
        for directory in ["/Applications", "/Applications/Utilities", FS.home + "/Applications"] {
            for path in FS.children(of: directory) where path.hasSuffix(".app") && path != ownPath {
                guard let bundle = Bundle(path: path) else { continue }
                let info = bundle.infoDictionary ?? [:]
                let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                apps.append(InstalledApp(
                    path: path,
                    name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName,
                    bundleID: bundle.bundleIdentifier ?? "",
                    version: (info["CFBundleShortVersionString"] as? String) ?? "",
                    lastUsed: lastUsedDate(path)))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Finds support files an app leaves behind, matched by bundle identifier and, where safe, by name.
    static func leftovers(for app: InstalledApp, otherBundleIDs: [String]) -> [Leftover] {
        let library = FS.home + "/Library"
        let bundleID = app.bundleID.lowercased()
        let appName = app.name.lowercased()
        let fileName = ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let others = otherBundleIDs.map { $0.lowercased() }.filter { $0 != bundleID && !$0.isEmpty }
        let strippedSuffixes = [".plist", ".savedstate", ".binarycookies", ".sfl2", ".sfl3", ".sfl4"]

        func matches(_ rawName: String, allowName: Bool) -> Bool {
            var name = rawName.lowercased()
            for suffix in strippedSuffixes where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
            if bundleID.split(separator: ".").count >= 2 {
                let related = name == bundleID || name.hasPrefix(bundleID + ".") || name.hasSuffix("." + bundleID)
                // "com.vendor.app.beta" belongs to another installed app, not to "com.vendor.app".
                let ownedByOther = others.contains { name == $0 || name.hasPrefix($0 + ".") && $0.count > bundleID.count }
                if related && !ownedByOther { return true }
            }
            if allowName, appName.count >= 4 || fileName.count >= 4 {
                return name == appName || name == fileName
            }
            return false
        }

        // (directory, match by display name too, requires administrator rights)
        let locations: [(String, Bool, Bool)] = [
            (library + "/Application Support", true, false),
            (library + "/Caches", true, false),
            (library + "/Logs", true, false),
            (library + "/Preferences", false, false),
            (library + "/Preferences/ByHost", false, false),
            (library + "/Containers", false, false),
            (library + "/Group Containers", false, false),
            (library + "/Application Scripts", false, false),
            (library + "/Saved Application State", false, false),
            (library + "/HTTPStorages", false, false),
            (library + "/WebKit", false, false),
            (library + "/Cookies", false, false),
            (library + "/LaunchAgents", false, false),
            ("/Library/Application Support", true, true),
            ("/Library/Caches", false, true),
            ("/Library/Preferences", false, true),
            ("/Library/LaunchAgents", false, true),
            ("/Library/LaunchDaemons", false, true),
            ("/Library/PrivilegedHelperTools", false, true),
        ]

        var found: [Leftover] = []
        for (directory, allowName, system) in locations {
            for path in FS.children(of: directory) where matches((path as NSString).lastPathComponent, allowName: allowName) {
                found.append(Leftover(path: path, size: FS.size(of: path), selected: !system, isSystemLevel: system))
            }
        }
        return found.sorted { $0.size > $1.size }
    }
}

enum AppSort: String, CaseIterable, Identifiable {
    case name = "Name", size = "Size", lastUsed = "Last Used"
    var id: String { rawValue }
}

@MainActor
final class UninstallerModel: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var loading = false
    @Published var selectedID: String? { didSet { loadLeftovers() } }
    @Published private(set) var leftovers: [Leftover] = []
    @Published private(set) var leftoversLoading = false
    @Published private(set) var working = false
    @Published private(set) var lastOutcome: Remover.Outcome?
    @Published var sort: AppSort = .name
    @Published var search = ""

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedID } }

    var visibleApps: [InstalledApp] {
        let needle = search.lowercased()
        let list = needle.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(needle) || $0.bundleID.lowercased().contains(needle) }
        switch sort {
        case .name: return list
        case .size: return list.sorted { $0.size > $1.size }
        case .lastUsed: return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    var selectedLeftoverSize: Int64 { leftovers.reduce(0) { $0 + ($1.selected ? $1.size : 0) } }

    func load() {
        guard !loading else { return }
        loading = true
        Task {
            let list = await Task.detached(priority: .userInitiated) { AppCatalog.installedApps() }.value
            apps = list
            loading = false
            // Sizes arrive progressively so the list is usable immediately.
            for app in list {
                let size = await Task.detached(priority: .utility) { FS.size(of: app.path) }.value
                if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index].size = size }
            }
        }
    }

    private func loadLeftovers() {
        leftovers = []
        lastOutcome = nil
        guard let app = selectedApp else { return }
        leftoversLoading = true
        let others = apps.map(\.bundleID)
        Task {
            let found = await Task.detached(priority: .userInitiated) { AppCatalog.leftovers(for: app, otherBundleIDs: others) }.value
            guard selectedID == app.id else { return }
            leftovers = found
            leftoversLoading = false
        }
    }

    func setLeftover(_ id: String, selected: Bool) {
        if let index = leftovers.firstIndex(where: { $0.id == id }) { leftovers[index].selected = selected }
    }

    /// Removes the selected support files and, unless `keepApp` is set, the application itself.
    func remove(keepApp: Bool) async {
        guard let app = selectedApp, !working else { return }
        working = true
        if !app.bundleID.isEmpty {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            running.forEach { $0.terminate() }
            if !running.isEmpty { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        var targets = leftovers.filter(\.selected).map { Remover.Target(path: $0.path, size: $0.size) }
        if !keepApp { targets.insert(Remover.Target(path: app.path, size: app.size), at: 0) }
        let permanently = Prefs.permanentDelete
        let section = keepApp ? "Reset \(app.name)" : "Uninstall \(app.name)"
        let outcome = await Task.detached {
            Remover.remove(targets, permanently: permanently, viaFinderOnFailure: true, logAs: section)
        }.value
        lastOutcome = outcome
        working = false
        if !FS.exists(app.path) {
            apps.removeAll { $0.id == app.id }
            selectedID = nil
            lastOutcome = outcome
        } else {
            leftovers.removeAll { !FS.exists($0.path) }
        }
    }
}

// MARK: - Space Lens

/// A directory or file in the disk-usage tree.
final class DiskNode: Identifiable, @unchecked Sendable {
    let name: String
    let isDirectory: Bool
    /// A synthetic entry standing in for many small files.
    let isAggregate: Bool
    var size: Int64
    var children: [DiskNode] = []
    weak var parent: DiskNode?
    private let rootPath: String?

    init(name: String, isDirectory: Bool, size: Int64 = 0, isAggregate: Bool = false, rootPath: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.isAggregate = isAggregate
        self.rootPath = rootPath
    }

    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        return isAggregate ? parent.path : parent.path + "/" + name
    }

    var ancestors: [DiskNode] {
        var chain: [DiskNode] = []
        var node: DiskNode? = self
        while let current = node { chain.insert(current, at: 0); node = current.parent }
        return chain
    }
}

enum DiskMapper {
    /// Files below this size are folded into one "smaller files" entry per folder to bound memory use.
    private static let individualFileThreshold: Int64 = 1_000_000

    static func map(_ root: String, report: ProgressReport, cancel: CancelFlag) -> DiskNode? {
        let rootNode = DiskNode(name: (root as NSString).lastPathComponent, isDirectory: true, rootPath: root)
        var stack: [DiskNode] = []
        var smallFiles: [(count: Int, size: Int64)] = []
        var seenInodes = Set<UInt64>()
        var visited = 0

        FS.walk(root) { kind, entry in
            visited += 1
            if visited % 4_096 == 0 {
                if cancel.isCancelled { return .stop }
                report("\(visited.formatted()) items · " + Fmt.tilde(entry.path))
            }
            switch kind {
            case .directory:
                let node = entry.level == 0 ? rootNode : DiskNode(name: entry.name, isDirectory: true)
                node.parent = stack.last
                stack.last?.children.append(node)
                stack.append(node)
                smallFiles.append((0, 0))
            case .file:
                guard let directory = stack.last else { return .proceed }
                if entry.hardLinks > 1, !seenInodes.insert(entry.inode).inserted { return .proceed }
                let size = entry.size
                directory.size += size
                if size >= individualFileThreshold {
                    let node = DiskNode(name: entry.name, isDirectory: false, size: size)
                    node.parent = directory
                    directory.children.append(node)
                } else {
                    smallFiles[smallFiles.count - 1].count += 1
                    smallFiles[smallFiles.count - 1].size += size
                }
            case .directoryEnd:
                guard let finished = stack.popLast(), let small = smallFiles.popLast() else { return .proceed }
                if small.count > 0, small.size > 0 {
                    let label = small.count == 1 ? "1 smaller file" : "\(small.count.formatted()) smaller files"
                    let node = DiskNode(name: label, isDirectory: false, size: small.size, isAggregate: true)
                    node.parent = finished
                    finished.children.append(node)
                }
                finished.children.sort { $0.size > $1.size }
                stack.last?.size += finished.size
            }
            return .proceed
        }
        return cancel.isCancelled ? nil : rootNode
    }
}

@MainActor
final class SpaceLensModel: ObservableObject {
    @Published private(set) var root: DiskNode?
    @Published var current: DiskNode?
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var progress = ""
    @Published private(set) var message: String?

    private var cancelFlag = CancelFlag()

    func scan(_ path: String) {
        guard state != .scanning else { return }
        state = .scanning
        progress = "Preparing…"
        message = nil
        let flag = CancelFlag()
        cancelFlag = flag
        let report: ProgressReport = { [weak self] text in Task { @MainActor in self?.progress = text } }
        Task {
            let tree = await Task.detached(priority: .userInitiated) {
                DiskMapper.map(path, report: report, cancel: flag)
            }.value
            root = tree
            current = tree
            state = tree == nil ? .idle : .ready
        }
    }

    func cancel() { cancelFlag.cancel() }

    func reset() {
        root = nil
        current = nil
        state = .idle
    }

    /// Trashes a node and subtracts its size from every ancestor so the map stays accurate.
    func remove(_ node: DiskNode) async {
        guard !node.isAggregate, let parent = node.parent else { return }
        let target = Remover.Target(path: node.path, size: node.size)
        let permanently = Prefs.permanentDelete
        let outcome = await Task.detached { Remover.remove([target], permanently: permanently, logAs: "Space Lens") }.value
        if outcome.removed == 1 {
            parent.children.removeAll { $0 === node }
            var ancestor: DiskNode? = parent
            while let a = ancestor { a.size -= node.size; ancestor = a.parent }
            message = "Removed \(node.name) · freed \(Fmt.bytes(node.size))"
            objectWillChange.send()
        } else {
            message = outcome.failures.first ?? "Could not remove \(node.name)"
        }
    }
}
