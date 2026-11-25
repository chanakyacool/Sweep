import AppKit
import Foundation
import IOKit
import IOKit.ps
import SwiftUI

// MARK: - Live system statistics

@MainActor
final class SystemStats: ObservableObject {
    struct Memory {
        var total: UInt64 = ProcessInfo.processInfo.physicalMemory
        var app: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
        var cached: UInt64 = 0
        var swapUsed: UInt64 = 0
        /// 1 normal, 2 warning, 4 critical (kernel memory-pressure level).
        var pressureLevel = 1

        var used: UInt64 { app + wired + compressed }
        var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
        var pressureName: String { pressureLevel >= 4 ? "Critical" : pressureLevel == 2 ? "Elevated" : "Normal" }
    }

    struct Disk {
        var total: Int64 = 0
        var free: Int64 = 0
        var used: Int64 { max(0, total - free) }
        var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    }

    struct Battery {
        var present = false
        var percent = 0
        var charging = false
        var onAC = false
        var cycles: Int?
        var healthPercent: Int?
        /// Power flowing into (positive) or out of (negative) the battery, in watts.
        var watts: Double?
        var minutesRemaining: Int?
    }

    struct AppLoad: Identifiable {
        var id: String { name }
        let name: String
        let cpu: Double
        let memory: Int64
    }

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var memory = Memory()
    @Published private(set) var memoryHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var disk = Disk()
    @Published private(set) var battery = Battery()
    @Published private(set) var download: Double = 0
    @Published private(set) var upload: Double = 0
    @Published private(set) var downloadHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var thermal = ProcessInfo.ThermalState.nominal
    @Published private(set) var gpu: SystemProbes.GPU?
    @Published private(set) var gpuHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var cores: [Double] = []
    @Published private(set) var loadAverage: [Double] = []
    @Published private(set) var diskRead: Double = 0
    @Published private(set) var diskWrite: Double = 0
    @Published private(set) var diskHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var localAddress: (address: String, interface: String)?
    @Published private(set) var topApps: [AppLoad] = []
    /// Set while the dashboard is on screen; the per-application ranking is only sampled then.
    var wantsTopApps = false { didSet { if wantsTopApps { sampleTopApps() } } }

    let bootTime: Date = {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &value, &size, nil, 0)
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec))
    }()

    let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    private var timer: Timer?
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var previousNetwork: (rx: UInt64, tx: UInt64, at: Date)?
    private var previousCores: [(busy: UInt32, idle: UInt32)] = []
    private var previousDisk: (read: UInt64, written: UInt64, at: Date)?
    private var tick = 0

    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func refreshDisk() { disk = Self.readDisk() }

    private func sample() {
        sampleCPU()
        memory = Self.readMemory()
        push(&memoryHistory, memory.fraction)
        sampleNetwork()
        sampleCores()
        sampleDiskActivity()
        gpu = SystemProbes.gpu()
        push(&gpuHistory, gpu?.utilization ?? 0)
        if wantsTopApps, tick % 3 == 0 { sampleTopApps() }
        if tick % 5 == 0 {
            loadAverage = SystemProbes.loadAverage()
            localAddress = SystemProbes.localAddress()
            disk = Self.readDisk()
            History.shared.sampleDisk(used: disk.used, total: disk.total)
            battery = Self.readBattery()
            thermal = ProcessInfo.processInfo.thermalState
        }
        tick += 1
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.removeFirst()
        history.append(value)
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let now = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        if let last = previousTicks {
            let busy = Double((now.user &- last.user) &+ (now.system &- last.system) &+ (now.nice &- last.nice))
            let idle = Double(now.idle &- last.idle)
            if busy + idle > 0 { cpu = busy / (busy + idle) }
        }
        previousTicks = now
        push(&cpuHistory, cpu)
    }

    private func sampleCores() {
        let now = SystemProbes.coreTicks()
        if now.count == previousCores.count {
            cores = zip(now, previousCores).map { current, last in
                let busy = Double(current.busy &- last.busy), idle = Double(current.idle &- last.idle)
                return busy + idle > 0 ? busy / (busy + idle) : 0
            }
        }
        previousCores = now
    }

    private func sampleDiskActivity() {
        let bytes = SystemProbes.diskBytes()
        let now = Date()
        if let last = previousDisk, bytes.read >= last.read, bytes.written >= last.written {
            let elapsed = max(now.timeIntervalSince(last.at), 0.001)
            diskRead = Double(bytes.read - last.read) / elapsed
            diskWrite = Double(bytes.written - last.written) / elapsed
        }
        previousDisk = (bytes.read, bytes.written, now)
        push(&diskHistory, diskRead + diskWrite)
    }

    private func sampleTopApps() {
        Task {
            let rows = await Task.detached(priority: .utility) { Scheduler.aggregate(ProcessCatalog.snapshot()) }.value
            topApps = rows.map { AppLoad(name: $0.name, cpu: $0.cpu, memory: $0.memory) }
        }
    }

    private func sampleNetwork() {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return }
        defer { freeifaddrs(list) }
        var cursor = list
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: interface.pointee.ifa_name).hasPrefix("en"),
                  let raw = interface.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(data.ifi_ibytes)
            tx += UInt64(data.ifi_obytes)
        }
        let now = Date()
        if let last = previousNetwork, rx >= last.rx, tx >= last.tx {
            let elapsed = max(now.timeIntervalSince(last.at), 0.001)
            download = Double(rx - last.rx) / elapsed
            upload = Double(tx - last.tx) / elapsed
        }
        previousNetwork = (rx, tx, now)
        push(&downloadHistory, download)
    }

    private static func readMemory() -> Memory {
        var memory = Memory()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let purgeable = UInt64(stats.purgeable_count)
            let anonymous = UInt64(stats.internal_page_count)
            memory.app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
            memory.wired = UInt64(stats.wire_count) * page
            memory.compressed = UInt64(stats.compressor_page_count) * page
            memory.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { memory.swapUsed = swap.xsu_used }
        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 { memory.pressureLevel = Int(level) }
        return memory
    }

    private static func readDisk() -> Disk {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return Disk(total: Int64(values?.volumeTotalCapacity ?? 0),
                    free: values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private static func readBattery() -> Battery {
        var battery = Battery()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return battery }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            battery.present = true
            battery.percent = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            battery.charging = info[kIOPSIsChargingKey] as? Bool ?? false
            battery.onAC = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            battery.cycles = property("CycleCount")
            // Apple silicon nests the raw capacities under "BatteryData"; Intel exposes them at the top level.
            let nested = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            let maximum = property("AppleRawMaxCapacity") ?? nested?["AppleRawMaxCapacity"] as? Int
            let design = property("DesignCapacity") ?? nested?["DesignCapacity"] as? Int
            if let maximum, let design, design > 0 {
                battery.healthPercent = min(100, Int((Double(maximum) / Double(design) * 100).rounded()))
            }
            // These are reported as unsigned 64-bit values; reading them as Int64 restores the sign of the current.
            func signed(_ key: String) -> Int64? {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.int64Value
            }
            if let millivolts = signed("Voltage"), let milliamps = signed("Amperage") {
                battery.watts = Double(millivolts) * Double(milliamps) / 1_000_000
            }
            if let minutes = signed("TimeRemaining"), minutes > 0, minutes < 6_000 { battery.minutesRemaining = Int(minutes) }
        }
        return battery
    }
}

// MARK: - Startup items

struct StartupItem: Identifiable, Sendable {
    enum Scope: String, Sendable {
        case userAgent = "Your Launch Agents"
        case globalAgent = "Launch Agents for All Users"
        case daemon = "System Daemons"
    }

    var id: String { path }
    let path: String
    let label: String
    let program: String
    let scope: Scope
    let runsAtLoad: Bool
    var disabled: Bool
    var running: Bool

    var vendor: String {
        let parts = label.split(separator: ".")
        return parts.count >= 2 ? String(parts[1]).capitalized : label
    }
}

enum StartupCatalog {
    static func load() -> [StartupItem] {
        let uid = getuid()
        let loaded = Shell.run("/bin/launchctl", ["list"]).text
        var runningLabels = Set<String>()
        for line in loaded.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            if columns.count == 3, columns[0] != "-" { runningLabels.insert(String(columns[2])) }
        }
        let disabledUser = disabledLabels(Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).text)
        let disabledSystem = disabledLabels(Shell.run("/bin/launchctl", ["print-disabled", "system"]).text)

        let sources: [(String, StartupItem.Scope)] = [
            (FS.home + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .daemon),
        ]
        var items: [StartupItem] = []
        for (directory, scope) in sources {
            for path in FS.children(of: directory) where path.hasSuffix(".plist") {
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let program = plist["Program"] as? String
                    ?? (plist["ProgramArguments"] as? [String])?.first
                    ?? plist["BundleProgram"] as? String
                    ?? (plist["AssociatedBundleIdentifiers"] as? [String])?.first
                    ?? (plist["AssociatedBundleIdentifiers"] as? String)
                    ?? ""
                let disabledSet = scope == .daemon ? disabledSystem : disabledUser
                items.append(StartupItem(
                    path: path, label: label, program: program, scope: scope,
                    runsAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                    disabled: disabledSet.contains(label) || (plist["Disabled"] as? Bool ?? false),
                    running: runningLabels.contains(label)))
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Parses `launchctl print-disabled`, whose lines look like `"label" => disabled`.
    private static func disabledLabels(_ text: String) -> Set<String> {
        var labels = Set<String>()
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard state == "disabled" || state == "true" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" \t")))
        }
        return labels
    }

    /// Enables or disables an item. Daemons live in the system domain and need administrator rights.
    static func setEnabled(_ enabled: Bool, _ item: StartupItem) -> Shell.Output {
        let label = Shell.quote(item.label)
        let path = Shell.quote(item.path)
        if item.scope == .daemon {
            return Shell.admin(enabled
                ? "/bin/launchctl enable system/\(label); /bin/launchctl bootstrap system \(path) 2>/dev/null; true"
                : "/bin/launchctl disable system/\(label); /bin/launchctl bootout system/\(label) 2>/dev/null; true")
        }
        let domain = "gui/\(getuid())"
        return Shell.sh(enabled
            ? "/bin/launchctl enable \(domain)/\(label); /bin/launchctl bootstrap \(domain) \(path) 2>/dev/null; true"
            : "/bin/launchctl disable \(domain)/\(label); /bin/launchctl bootout \(domain)/\(label) 2>/dev/null; true")
    }
}

@MainActor
final class StartupModel: ObservableObject {
    @Published private(set) var items: [StartupItem] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?

    func load() {
        guard !loading else { return }
        loading = true
        Task {
            items = await Task.detached { StartupCatalog.load() }.value
            loading = false
        }
    }

    func setEnabled(_ enabled: Bool, _ item: StartupItem) {
        Task {
            let output = await Task.detached { StartupCatalog.setEnabled(enabled, item) }.value
            message = output.ok ? "\(item.label) \(enabled ? "enabled" : "disabled")." : "Could not change \(item.label): \(output.text)"
            load()
        }
    }

    /// Unloads a user launch agent and moves its property list to the Trash.
    func remove(_ item: StartupItem) {
        guard item.scope == .userAgent else { return }
        Task {
            let outcome = await Task.detached { () -> Remover.Outcome in
                Shell.sh("/bin/launchctl bootout gui/\(getuid())/\(Shell.quote(item.label)) 2>/dev/null; true")
                return Remover.remove([Remover.Target(path: item.path, size: 0)], permanently: false)
            }.value
            message = outcome.removed == 1 ? "\(item.label) removed." : (outcome.failures.first ?? "Could not remove \(item.label).")
            load()
        }
    }
}

// MARK: - Processes

struct ProcessRow: Identifiable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: Int64
    let user: String
    let executable: String
}

enum ProcessCatalog {
    static func snapshot() -> [ProcessRow] {
        let output = Shell.run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,user=,comm="]).text
        var rows: [ProcessRow] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int32(fields[0]), let cpu = Double(fields[1]), let rss = Int64(fields[2]) else { continue }
            let executable = String(fields[4]).trimmingCharacters(in: .whitespaces)
            rows.append(ProcessRow(pid: pid, name: displayName(executable), cpu: cpu, memory: rss * 1_024,
                                   user: String(fields[3]), executable: executable))
        }
        return rows
    }

    /// Prefers the enclosing application's name over the raw executable name.
    private static func displayName(_ executable: String) -> String {
        let leaf = (executable as NSString).lastPathComponent
        guard let range = executable.range(of: ".app/", options: .backwards) else { return leaf }
        let app = ((String(executable[..<range.lowerBound]) as NSString).lastPathComponent)
        return leaf == app || leaf.isEmpty ? app : "\(leaf) (\(app))"
    }
}

@MainActor
final class ProcessModel: ObservableObject {
    @Published private(set) var rows: [ProcessRow] = []
    @Published var selection = Set<Int32>()
    @Published var sortOrder = [KeyPathComparator(\ProcessRow.memory, order: .reverse)]
    @Published var onlyMine = true
    @Published var showingTrends = false
    @Published var trendHours = 24 { didSet { loadTrends() } }
    @Published private(set) var trends: [ProcessTrend] = []
    @Published var search = ""
    @Published private(set) var message: String?

    private var timer: Timer?
    private let currentUser = NSUserName()

    var visible: [ProcessRow] {
        let needle = search.lowercased()
        return rows.filter { row in
            (!onlyMine || row.user == currentUser) && (needle.isEmpty || row.name.lowercased().contains(needle))
        }.sorted(using: sortOrder)
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task { rows = await Task.detached { ProcessCatalog.snapshot() }.value }
    }

    func loadTrends() {
        let hours = trendHours
        Task { trends = await Task.detached { History.shared.processTrends(hours: hours) }.value }
    }

    func terminateSelected(force: Bool) {
        let ownPID = getpid()
        var failed = 0
        for pid in selection where pid != ownPID && pid > 1 {
            if kill(pid, force ? SIGKILL : SIGTERM) != 0 { failed += 1 }
        }
        message = failed == 0 ? nil : "\(failed) process\(failed == 1 ? "" : "es") could not be stopped (owned by the system or another user)."
        selection = []
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            refresh()
        }
    }
}

// MARK: - Maintenance

struct MaintenanceTask: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let command: String
    let needsAdmin: Bool
}

enum MaintenanceCatalog {
    static let tasks: [MaintenanceTask] = {
        var list = [
            MaintenanceTask(id: "ram", title: "Free Up Inactive Memory",
                            detail: "Asks macOS to release cached file data and purgeable memory.",
                            icon: "memorychip", command: "/usr/sbin/purge", needsAdmin: true),
            MaintenanceTask(id: "dns", title: "Flush DNS Cache",
                            detail: "Clears cached name lookups. Helps when a site moved or will not resolve.",
                            icon: "network", command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder", needsAdmin: true),
            MaintenanceTask(id: "spotlight", title: "Rebuild Spotlight Index",
                            detail: "Erases and rebuilds the search index. Search is slower until indexing finishes.",
                            icon: "magnifyingglass", command: "/usr/bin/mdutil -E /", needsAdmin: true),
            MaintenanceTask(id: "snapshots", title: "Thin Time Machine Snapshots",
                            detail: "Removes local Time Machine snapshots to reclaim purgeable disk space.",
                            icon: "clock.arrow.2.circlepath", command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4", needsAdmin: true),
            MaintenanceTask(id: "launchservices", title: "Rebuild Launch Services Database",
                            detail: "Fixes duplicate or wrong entries in the “Open With” menu.",
                            icon: "arrow.triangle.2.circlepath",
                            command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user",
                            needsAdmin: false),
            MaintenanceTask(id: "quicklook", title: "Reset Quick Look",
                            detail: "Clears the preview cache and reloads Quick Look generators.",
                            icon: "eye", command: "/usr/bin/qlmanage -r cache; /usr/bin/qlmanage -r", needsAdmin: false),
            MaintenanceTask(id: "fonts", title: "Clear Font Caches",
                            detail: "Removes your font caches. Fixes garbled text; takes effect after you log out.",
                            icon: "textformat", command: "/usr/bin/atsutil databases -removeUser", needsAdmin: false),
            MaintenanceTask(id: "finder", title: "Restart Finder and Dock",
                            detail: "Relaunches Finder and the Dock to clear visual glitches.",
                            icon: "macwindow", command: "/usr/bin/killall Finder; /usr/bin/killall Dock", needsAdmin: false),
            MaintenanceTask(id: "verify", title: "Verify Startup Disk",
                            detail: "Checks the startup volume's file system for errors. Read-only; can take a minute.",
                            icon: "stethoscope", command: "/usr/sbin/diskutil verifyVolume /", needsAdmin: false),
        ]
        if let docker = Shell.which("docker") {
            list.append(MaintenanceTask(id: "docker", title: "Prune Docker",
                                        detail: "Removes stopped containers, unused networks, dangling images and build cache. Volumes are kept.",
                                        icon: "shippingbox", command: "\(Shell.quote(docker)) system prune -f", needsAdmin: false))
        }
        if let brew = Shell.which("brew") {
            list.append(MaintenanceTask(id: "brew", title: "Clean Up Homebrew",
                                        detail: "Removes old versions of installed formulae and stale downloads.",
                                        icon: "mug", command: "\(Shell.quote(brew)) cleanup --prune=all", needsAdmin: false))
        }
        return list
    }()
}

@MainActor
final class MaintenanceModel: ObservableObject {
    struct Result {
        let ok: Bool
        let text: String
        let finished: Date
    }

    @Published private(set) var running = Set<String>()
    @Published private(set) var results: [String: Result] = [:]

    func run(_ task: MaintenanceTask) {
        guard !running.contains(task.id) else { return }
        running.insert(task.id)
        Task {
            let output = await Task.detached { task.needsAdmin ? Shell.admin(task.command) : Shell.sh(task.command, timeout: 900) }.value
            running.remove(task.id)
            let cancelled = output.text.contains("User canceled") || output.text.contains("(-128)")
            results[task.id] = Result(ok: output.ok,
                                      text: cancelled ? "Cancelled." : (output.text.isEmpty ? "Completed." : output.text),
                                      finished: Date())
        }
    }
}
