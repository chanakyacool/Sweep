import Foundation
import IOKit

/// Low-level hardware readings used by the dashboard. Each call is a cheap IORegistry or Mach query.
enum SystemProbes {
    struct GPU {
        var name = ""
        /// Fraction of the GPU in use, 0...1.
        var utilization = 0.0
        var memoryInUse: Int64 = 0
    }

    /// Reads GPU load from the graphics accelerator's performance statistics; nil when no GPU reports them.
    static func gpu() -> GPU? {
        var best: GPU?
        forEachService("IOAccelerator") { service in
            guard let stats = property(service, "PerformanceStatistics") as? [String: Any],
                  let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            let gpu = GPU(name: property(service, "model") as? String ?? "GPU",
                          utilization: min(1, percent / 100),
                          memoryInUse: (stats["In use system memory"] as? NSNumber)?.int64Value ?? 0)
            // With more than one GPU, report the busier one.
            if gpu.utilization >= (best?.utilization ?? -1) { best = gpu }
        }
        return best
    }

    /// Total bytes read from and written to all internal and external drives since boot.
    static func diskBytes() -> (read: UInt64, written: UInt64) {
        var read: UInt64 = 0, written: UInt64 = 0
        forEachService("IOBlockStorageDriver") { service in
            guard let stats = property(service, "Statistics") as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, written)
    }

    /// Cumulative (busy, idle) ticks for every logical core.
    static func coreTicks() -> [(busy: UInt32, idle: UInt32)] {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(coreCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            let idle = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            return (user &+ system &+ nice, idle)
        }
    }

    static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) == 3 ? values : []
    }

    /// The primary IPv4 address and the interface it belongs to, e.g. ("192.168.1.20", "en0").
    static func localAddress() -> (address: String, interface: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en"), let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return (String(cString: host), name)
            }
        }
        return nil
    }

    /// Core counts per performance tier, e.g. [("Performance", 12), ("Efficiency", 4)].
    static let coreTiers: [(name: String, count: Int)] = {
        var tiers: [(String, Int)] = []
        for level in 0..<3 {
            var count: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname("hw.perflevel\(level).logicalcpu", &count, &size, nil, 0) == 0, count > 0 else { break }
            var nameSize = 0
            sysctlbyname("hw.perflevel\(level).name", nil, &nameSize, nil, 0)
            var buffer = [CChar](repeating: 0, count: max(nameSize, 1))
            sysctlbyname("hw.perflevel\(level).name", &buffer, &nameSize, nil, 0)
            tiers.append((String(cString: buffer), Int(count)))
        }
        return tiers
    }()

    // MARK: IORegistry helpers

    private static func forEachService(_ className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
