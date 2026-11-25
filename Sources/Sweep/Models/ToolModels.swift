import Foundation
import SwiftUI

// MARK: - Shared shape for things removed by running a tool rather than deleting a file

struct ToolItem: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let size: Int64
    var selected: Bool
    /// Executable followed by its arguments; running it removes the item.
    let removal: [String]
}

struct ToolGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let icon: String
    let detail: String
    var items: [ToolItem] = []

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

// MARK: - Docker & simulators

enum ContainerScanner {
    struct Result: Sendable {
        var groups: [ToolGroup] = []
        var notes: [String] = []
    }

    static func scan() -> Result {
        var result = Result()
        scanDocker(into: &result)
        scanSimulators(into: &result)
        return result
    }

    /// Parses Docker's human-readable sizes such as "1.25GB", "340MB", "12.4kB" or "0B (virtual 187MB)".
    static func parseSize(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where token.hasSuffix(suffix) {
            return Int64((Double(token.dropLast(suffix.count)) ?? 0) * factor)
        }
        return 0
    }

    private static func scanDocker(into result: inout Result) {
        guard let docker = Shell.which("docker") else {
            result.notes.append("Docker is not installed, so there are no images or volumes to show.")
            return
        }
        let output = Shell.run(docker, ["system", "df", "-v", "--format", "{{json .}}"], timeout: 25, mergeErrors: false)
        guard output.ok, let data = output.text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.notes.append("Docker is installed but not running. Start it and rescan to see images, containers and volumes.")
            return
        }
        func rows(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
        func text(_ row: [String: Any], _ key: String) -> String { row[key].map { "\($0)" } ?? "" }

        var images = ToolGroup(id: "images", title: "Docker Images", icon: "shippingbox.fill",
                               detail: "Images no container is using. Untagged ones are selected; pull the others again if you need them.")
        for row in rows("Images") where text(row, "Containers") == "0" {
            let repository = text(row, "Repository"), tag = text(row, "Tag"), id = text(row, "ID")
            let dangling = repository == "<none>"
            images.items.append(ToolItem(id: "image-\(id)", title: dangling ? "Untagged image \(id.prefix(19))" : "\(repository):\(tag)",
                                         detail: "Created \(text(row, "CreatedSince"))", size: parseSize(text(row, "Size")),
                                         selected: dangling, removal: [docker, "rmi", id]))
        }

        var containers = ToolGroup(id: "containers", title: "Stopped Containers", icon: "cube.fill",
                                   detail: "Containers that are not running. Removing one discards anything written inside it.")
        for row in rows("Containers") where text(row, "State") != "running" {
            containers.items.append(ToolItem(id: "container-\(text(row, "ID"))", title: text(row, "Names"),
                                             detail: "\(text(row, "Image")) · \(text(row, "Status"))",
                                             size: parseSize(text(row, "Size")), selected: false,
                                             removal: [docker, "rm", text(row, "ID")]))
        }

        var volumes = ToolGroup(id: "volumes", title: "Unused Volumes", icon: "cylinder.fill",
                                detail: "Volumes not attached to any container. They can hold databases, so nothing is selected for you.")
        for row in rows("Volumes") where text(row, "Links") == "0" {
            let name = text(row, "Name")
            volumes.items.append(ToolItem(id: "volume-\(name)", title: name, detail: "Not attached to a container",
                                          size: parseSize(text(row, "Size")), selected: false,
                                          removal: [docker, "volume", "rm", name]))
        }

        var cache = ToolGroup(id: "cache", title: "Build Cache", icon: "hammer.fill",
                              detail: "Layers cached from image builds. The next build is slower, nothing else changes.")
        let unused = rows("BuildCache").filter { text($0, "InUse") != "true" }
        let cacheSize = unused.reduce(Int64(0)) { $0 + parseSize(text($1, "Size")) }
        if cacheSize > 0 {
            cache.items.append(ToolItem(id: "build-cache", title: "Unused build cache", detail: "\(unused.count) cached layers",
                                        size: cacheSize, selected: true, removal: [docker, "builder", "prune", "-f"]))
        }

        for var group in [images, containers, volumes, cache] where !group.items.isEmpty {
            group.items.sort { $0.size > $1.size }
            result.groups.append(group)
        }
        if images.items.isEmpty && containers.items.isEmpty && volumes.items.isEmpty && cache.items.isEmpty {
            result.notes.append("Docker is running and has nothing unused to remove.")
        }
    }

    private static func scanSimulators(into result: inout Result) {
        guard FS.isDirectory("/Applications/Xcode.app") else {
            result.notes.append("Xcode is not installed, so there are no simulators to manage.")
            return
        }
        let output = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], timeout: 30, mergeErrors: false)
        guard output.ok, let data = output.text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else {
            result.notes.append("Simulators could not be listed. Open Xcode once to finish its setup.")
            return
        }
        var group = ToolGroup(id: "simulators", title: "Simulator Devices", icon: "iphone",
                              detail: "Each device keeps its own apps and data. Devices for runtimes you no longer have are selected.")
        for (runtime, devices) in runtimes {
            let runtimeName = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "").replacingOccurrences(of: "-", with: " ")
            for device in devices {
                guard let udid = device["udid"] as? String, let name = device["name"] as? String else { continue }
                let available = device["isAvailable"] as? Bool ?? true
                let size = (device["dataPath"] as? String).map { FS.size(of: $0) } ?? 0
                group.items.append(ToolItem(id: "simulator-\(udid)", title: name,
                                            detail: runtimeName + (available ? "" : " · runtime no longer installed"),
                                            size: size, selected: !available,
                                            removal: ["/usr/bin/xcrun", "simctl", "delete", udid]))
            }
        }
        group.items.sort { $0.size > $1.size }
        if !group.items.isEmpty { result.groups.append(group) }
    }
}

@MainActor
final class ContainersModel: ObservableObject {
    @Published private(set) var groups: [ToolGroup] = []
    @Published private(set) var notes: [String] = []
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var lastOutcome: Remover.Outcome?

    var selected: [ToolItem] { groups.flatMap(\.items).filter(\.selected) }
    var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }

    func scan() {
        guard state != .scanning, state != .cleaning else { return }
        state = .scanning
        lastOutcome = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { ContainerScanner.scan() }.value
            groups = result.groups
            notes = result.notes
            state = .ready
        }
    }

    func setSelected(_ selected: Bool, item id: String) {
        for g in groups.indices {
            if let i = groups[g].items.firstIndex(where: { $0.id == id }) { groups[g].items[i].selected = selected }
        }
    }

    func removeSelected() async {
        let items = selected
        guard state == .ready, !items.isEmpty else { return }
        state = .cleaning
        let outcome = await Task.detached(priority: .userInitiated) { () -> Remover.Outcome in
            var outcome = Remover.Outcome()
            var removed: [Remover.Target] = []
            for item in items {
                let result = Shell.run(item.removal[0], Array(item.removal.dropFirst()), timeout: 300)
                if result.ok {
                    outcome.removed += 1
                    outcome.freed += item.size
                    removed.append(Remover.Target(path: item.title, size: item.size))
                } else {
                    outcome.failures.append("\(item.title): \(result.text.split(separator: "\n").last.map(String.init) ?? "failed")")
                }
            }
            History.shared.recordCleanup(section: "Containers & Simulators", targets: removed, outcome: outcome)
            return outcome
        }.value
        state = .ready
        scan()
        lastOutcome = outcome
    }
}

// MARK: - Updater

struct UpdateItem: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case formula = "Homebrew Formulae", cask = "Homebrew Apps", appStore = "App Store"
    }

    var id: String { kind.rawValue + "/" + identifier }
    let identifier: String
    let name: String
    let installed: String
    let latest: String
    let kind: Kind
    var selected = true
}

enum UpdateCatalog {
    struct Result: Sendable {
        var items: [UpdateItem] = []
        var notes: [String] = []
    }

    static func check() -> Result {
        var result = Result()
        if let brew = Shell.which("brew") {
            Shell.run(brew, ["update", "--quiet"], timeout: 180)
            let output = Shell.run(brew, ["outdated", "--json=v2"], timeout: 120, mergeErrors: false)
            if let data = output.text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result.items += parse(root["formulae"], kind: .formula)
                result.items += parse(root["casks"], kind: .cask)
            } else {
                result.notes.append("Homebrew did not return a list of outdated packages.")
            }
        } else {
            result.notes.append("Homebrew is not installed, so command-line tools and Homebrew apps are not checked.")
        }

        if let mas = Shell.which("mas") {
            // Lines look like: 497799835 Xcode (15.0 -> 15.1)
            for line in Shell.run(mas, ["outdated"], timeout: 120, mergeErrors: false).text.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, Int(parts[0]) != nil, let open = parts[1].lastIndex(of: "(") else { continue }
                let versions = parts[1][open...].trimmingCharacters(in: CharacterSet(charactersIn: "()")).components(separatedBy: " -> ")
                result.items.append(UpdateItem(identifier: parts[0], name: parts[1][..<open].trimmingCharacters(in: .whitespaces),
                                               installed: versions.first ?? "", latest: versions.last ?? "", kind: .appStore))
            }
        } else {
            result.notes.append("App Store apps are updated by the App Store itself. Install the “mas” tool with Homebrew to update them from here.")
        }
        return result
    }

    private static func parse(_ value: Any?, kind: UpdateItem.Kind) -> [UpdateItem] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let installed = (entry["installed_versions"] as? [String])?.last ?? (entry["installed_versions"] as? String) ?? ""
            return UpdateItem(identifier: name, name: name, installed: installed,
                              latest: entry["current_version"] as? String ?? "", kind: kind,
                              selected: !(entry["pinned"] as? Bool ?? false))
        }
    }

    /// Upgrades the given items and returns the combined tool output.
    static func upgrade(_ items: [UpdateItem]) -> Shell.Output {
        var log: [String] = []
        var failed = false
        func run(_ tool: String, _ arguments: [String]) {
            let output = Shell.run(tool, arguments, timeout: 1_800)
            log.append(output.text)
            if !output.ok { failed = true }
        }
        let formulae = items.filter { $0.kind == .formula }.map(\.identifier)
        let casks = items.filter { $0.kind == .cask }.map(\.identifier)
        let store = items.filter { $0.kind == .appStore }.map(\.identifier)
        if let brew = Shell.which("brew") {
            if !formulae.isEmpty { run(brew, ["upgrade", "--formula"] + formulae) }
            if !casks.isEmpty { run(brew, ["upgrade", "--cask"] + casks) }
        }
        if let mas = Shell.which("mas"), !store.isEmpty { run(mas, ["upgrade"] + store) }
        return Shell.Output(status: failed ? 1 : 0, text: log.joined(separator: "\n"))
    }
}

@MainActor
final class UpdaterModel: ObservableObject {
    enum Phase { case idle, checking, ready, updating }

    @Published private(set) var items: [UpdateItem] = []
    @Published private(set) var notes: [String] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: String?
    @Published private(set) var lastSucceeded: Bool?

    var selected: [UpdateItem] { items.filter(\.selected) }

    func check() {
        guard phase != .checking, phase != .updating else { return }
        phase = .checking
        Task {
            let result = await Task.detached(priority: .userInitiated) { UpdateCatalog.check() }.value
            items = result.items
            notes = result.notes
            phase = .ready
        }
    }

    func setSelected(_ selected: Bool, item id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].selected = selected }
    }

    func updateSelected() {
        let chosen = selected
        guard phase == .ready, !chosen.isEmpty else { return }
        phase = .updating
        log = nil
        Task {
            let output = await Task.detached(priority: .userInitiated) { UpdateCatalog.upgrade(chosen) }.value
            log = output.text
            lastSucceeded = output.ok
            phase = .ready
            check()
        }
    }
}
