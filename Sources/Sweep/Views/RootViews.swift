import ServiceManagement
import SwiftUI

// MARK: - Navigation

enum Section: String, CaseIterable, Identifiable {
    case smartScan, dashboard, history
    case junk, largeFiles, duplicates, similarPhotos, developer, containers
    case uninstaller, updater, spaceLens
    case startup, processes, maintenance
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: return "Smart Scan"
        case .dashboard: return "Dashboard"
        case .history: return "History"
        case .junk: return "System Junk"
        case .largeFiles: return "Large & Old Files"
        case .duplicates: return "Duplicates"
        case .similarPhotos: return "Similar Photos"
        case .developer: return "Developer"
        case .containers: return "Containers"
        case .updater: return "Updater"
        case .uninstaller: return "Uninstaller"
        case .spaceLens: return "Space Lens"
        case .startup: return "Startup Items"
        case .processes: return "Processes"
        case .maintenance: return "Maintenance"
        case .privacy: return "Privacy"
        }
    }

    var icon: String {
        switch self {
        case .smartScan: return "sparkles"
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .history: return "clock.arrow.circlepath"
        case .junk: return "trash.fill"
        case .largeFiles: return "doc.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .similarPhotos: return "photo.on.rectangle.angled"
        case .developer: return "hammer.fill"
        case .containers: return "shippingbox.fill"
        case .updater: return "arrow.down.circle.fill"
        case .uninstaller: return "square.grid.2x2.fill"
        case .spaceLens: return "square.split.2x2.fill"
        case .startup: return "bolt.fill"
        case .processes: return "waveform.path.ecg"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .privacy: return "hand.raised.fill"
        }
    }

    /// Each section owns a gradient; it colours the backdrop glow, icons, gauges and primary buttons.
    var accent: Accent {
        switch self {
        case .smartScan: return .brand
        case .dashboard: return Accent(start: Color(hex: 0x38C6FF), end: Color(hex: 0x4A7BFF))
        case .history: return Accent(start: Color(hex: 0x5CE0D2), end: Color(hex: 0x4A8CFF))
        case .junk: return Accent(start: Color(hex: 0xFF9A5A), end: Color(hex: 0xFF4F8B))
        case .largeFiles: return Accent(start: Color(hex: 0xFFC857), end: Color(hex: 0xFF7A45))
        case .duplicates: return Accent(start: Color(hex: 0x4FE3C1), end: Color(hex: 0x2FA8E8))
        case .similarPhotos: return Accent(start: Color(hex: 0xFF8FB1), end: Color(hex: 0xFF6A5C))
        case .developer: return Accent(start: Color(hex: 0x8EE05C), end: Color(hex: 0x14B8A0))
        case .containers: return Accent(start: Color(hex: 0x4FC3FF), end: Color(hex: 0x2F6BFF))
        case .updater: return Accent(start: Color(hex: 0x6EE7B7), end: Color(hex: 0x22B8CF))
        case .uninstaller: return Accent(start: Color(hex: 0xFF6FA5), end: Color(hex: 0xA95CFF))
        case .spaceLens: return Accent(start: Color(hex: 0x6F8CFF), end: Color(hex: 0xB45CFF))
        case .startup: return Accent(start: Color(hex: 0xFFD25C), end: Color(hex: 0xFF8F3F))
        case .processes: return Accent(start: Color(hex: 0x4DD4FF), end: Color(hex: 0x6A6CFF))
        case .maintenance: return Accent(start: Color(hex: 0x52E0A4), end: Color(hex: 0x2A9FD6))
        case .privacy: return Accent(start: Color(hex: 0xB892FF), end: Color(hex: 0x6957F5))
        }
    }

    var style: SectionStyle { SectionStyle(icon: icon, accent: accent) }

    static let groups: [(String, [Section])] = [
        ("Overview", [.smartScan, .dashboard, .history]),
        ("Cleanup", [.junk, .largeFiles, .duplicates, .similarPhotos, .developer, .containers]),
        ("Applications", [.uninstaller, .updater]),
        ("System", [.spaceLens, .startup, .processes, .maintenance]),
        ("Protection", [.privacy]),
    ]
}

/// Owns every feature model so scan results survive navigating between sections.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var section: Section = .smartScan
    @Published private(set) var smartScanning = false
    @Published private(set) var smartScanFinished: Date?

    let stats = SystemStats()
    let history = HistoryModel()
    let junk = CategoryModel(name: "System Junk") { JunkScanner.scan(report: $0, cancel: $1) }
    let developer = CategoryModel(name: "Developer") { DevJunkScanner.scan(report: $0, cancel: $1) }
    let privacy = CategoryModel(name: "Privacy") { PrivacyScanner.scan(report: $0, cancel: $1) }
    let largeFiles = LargeFilesModel()
    let duplicates = DuplicatesModel()
    let similarPhotos = SimilarPhotosModel()
    let containers = ContainersModel()
    let updater = UpdaterModel()
    let uninstaller = UninstallerModel()
    let spaceLens = SpaceLensModel()
    let startup = StartupModel()
    let processes = ProcessModel()
    let maintenance = MaintenanceModel()

    /// Runs the junk, developer and large-file scans concurrently.
    func smartScan() async {
        guard !smartScanning else { return }
        smartScanning = true
        startup.load()
        async let a: Void = junk.scanAndWait()
        async let b: Void = developer.scanAndWait()
        async let c: Void = largeFiles.scanAndWait()
        _ = await (a, b, c)
        stats.refreshDisk()
        smartScanFinished = Date()
        smartScanning = false
    }

    func cancelSmartScan() {
        junk.cancel(); developer.cancel(); largeFiles.cancel()
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(state: state, stats: state.stats)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            detail
                .id(state.section)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Backdrop(accent: state.section.accent))
        .environment(\.sectionStyle, state.section.style)
        .tint(state.section.accent.start)
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.22), value: state.section)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var detail: some View {
        switch state.section {
        case .smartScan: SmartScanView(state: state, junk: state.junk, developer: state.developer, largeFiles: state.largeFiles, startup: state.startup, stats: state.stats)
        case .dashboard: DashboardView(stats: state.stats)
        case .history: HistoryView(model: state.history)
        case .junk:
            CategoryCleanerView(model: state.junk, title: "System Junk",
                                subtitle: "Caches, logs, leftovers from development tools and other files that are safe to regenerate.",
                                icon: "trash.fill",
                                intro: "Sweep looks through caches, logs, Xcode and package-manager data, unfinished downloads and the Trash. You review everything before it is removed.")
        case .developer:
            CategoryCleanerView(model: state.developer, title: "Developer",
                                subtitle: "Dependencies and build output inside your projects, all of which can be regenerated.",
                                icon: "hammer.fill",
                                intro: "Finds node_modules, virtual environments, .terraform folders and build output across your home folder. Nothing is selected until you choose — use Select to pick projects you have not touched in a while.",
                                showsAgeSelection: true)
        case .privacy:
            CategoryCleanerView(model: state.privacy, title: "Privacy",
                                subtitle: "Browsing traces, recent-item lists and shell history. Nothing is selected by default.",
                                icon: "hand.raised.fill",
                                intro: "Lists browser history, cookies and caches, recent-item lists and terminal history. Removing cookies signs you out of websites, so every item starts unselected.")
        case .largeFiles: LargeFilesView(model: state.largeFiles)
        case .duplicates: DuplicatesView(model: state.duplicates)
        case .similarPhotos: SimilarPhotosView(model: state.similarPhotos)
        case .containers: ContainersView(model: state.containers)
        case .updater: UpdaterView(model: state.updater)
        case .uninstaller: UninstallerView(model: state.uninstaller)
        case .spaceLens: SpaceLensView(model: state.spaceLens)
        case .startup: StartupView(model: state.startup)
        case .processes: ProcessesView(model: state.processes)
        case .maintenance: MaintenanceView(model: state.maintenance)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var state: AppState
    @ObservedObject var stats: SystemStats

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Accent.brand.gradient)
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                    .shadow(color: Accent.brand.start.opacity(0.7), radius: 8)
                Text("Sweep").font(Theme.display(20))
            }
            .padding(.leading, 20)
            .padding(.top, 46)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Section.groups, id: \.0) { group in
                        Text(group.0.uppercased())
                            .font(.system(size: 10, weight: .semibold)).tracking(1.1)
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.leading, 12).padding(.top, 7).padding(.bottom, 2)
                        ForEach(group.1) { section in
                            SidebarItem(section: section, selected: state.section == section) { state.section = section }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            HStack(spacing: 12) {
                Ring(fraction: stats.disk.fraction, accent: Theme.usage(stats.disk.fraction) ?? .brand, lineWidth: 5) {
                    Text(Fmt.percent(stats.disk.fraction)).font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Macintosh HD").font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("\(Fmt.bytes(stats.disk.free)) free").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .card(padding: 10, radius: 14)
            .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 6)
        }
        .frame(width: 236)
        .background(Color.black.opacity(0.28))
    }
}

private struct SidebarItem: View {
    let section: Section
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(section.accent.gradient) : AnyShapeStyle(Color.white.opacity(0.06)))
                    .frame(width: 25, height: 25)
                    .overlay(
                        Image(systemName: section.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(section.accent.gradient)))
                    .shadow(color: selected ? section.accent.start.opacity(0.6) : .clear, radius: 7, y: 2)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.72))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(selected ? 0.10 : hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(selected ? 0.12 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Smart Scan

struct SmartScanView: View {
    @ObservedObject var state: AppState
    @ObservedObject var junk: CategoryModel
    @ObservedObject var developer: CategoryModel
    @ObservedObject var largeFiles: LargeFilesModel
    @ObservedObject var startup: StartupModel
    @ObservedObject var stats: SystemStats
    @State private var confirming = false
    @Environment(\.sectionStyle) private var style

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        Page(title: "Smart Scan", subtitle: "One pass over the most common ways to free space and speed up your Mac.") {
            if state.smartScanFinished != nil, !state.smartScanning {
                Button("Scan Again") { Task { await state.smartScan() } }
            }
        } content: {
            if state.smartScanning {
                ScanningState(title: "Scanning your Mac…",
                              progress: [junk, developer].first { $0.state == .scanning }?.progress ?? largeFiles.progress,
                              cancel: state.cancelSmartScan)
            } else if state.smartScanFinished == nil {
                welcome
            } else {
                results
            }
        }
        .removalConfirmation(isPresented: $confirming, size: junk.selectedSize, count: junk.selectedCount) {
            Task { await junk.clean(); stats.refreshDisk() }
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Button { Task { await state.smartScan() } } label: { ScanOrb(size: 210) }
                .buttonStyle(.plain)
                .help("Run Smart Scan")
            Text("Welcome to Sweep").font(Theme.display(32))
            Text("Smart Scan checks for system junk, regenerable developer files, large files and startup items. Nothing is removed until you confirm.")
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 480)
            Button("Run Smart Scan") { Task { await state.smartScan() } }
                .buttonStyle(.primary).controlSize(.large).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let outcome = junk.lastOutcome { OutcomeBanner(outcome: outcome).padding(.horizontal, -20).padding(.top, -12) }
                HStack(spacing: 28) {
                    Ring(fraction: junk.totalSize > 0 ? Double(junk.selectedSize) / Double(junk.totalSize) : 0, accent: style.accent, lineWidth: 14) {
                        VStack(spacing: 0) {
                            Text(Fmt.bytes(junk.selectedSize)).font(Theme.display(25).monospacedDigit())
                                .minimumScaleFactor(0.6).lineLimit(1)
                            Text("to clean").font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 18)
                    }
                    .frame(width: 168, height: 168)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Mac is ready for a clean-up").font(Theme.display(24))
                        Text("\(Fmt.bytes(junk.selectedSize)) of safe-to-remove junk is selected out of \(Fmt.bytes(junk.totalSize)) found. \(Fmt.bytes(stats.disk.free)) is free right now.")
                            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6)).lineSpacing(3)
                        HStack(spacing: 10) {
                            Button("Clean Now") { confirming = true }
                                .buttonStyle(.primary).controlSize(.large)
                                .disabled(junk.selectedCount == 0 || junk.state != .ready)
                            Button("Review Items") { state.section = .junk }.controlSize(.large)
                        }
                        .padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                .card(padding: 26, radius: 22)

                LazyVGrid(columns: columns, spacing: 16) {
                    tile(.junk, value: Fmt.bytes(junk.totalSize),
                         detail: "\(junk.itemCount) items in \(junk.categories.count) categories")
                    tile(.developer, value: Fmt.bytes(developer.totalSize),
                         detail: "\(developer.itemCount) regenerable folders in your projects")
                    tile(.largeFiles, value: Fmt.bytes(largeFiles.totalSize),
                         detail: "\(largeFiles.results.count) files of \(Fmt.bytes(Prefs.largeMinBytes)) or more")
                    tile(.startup, value: "\(startup.items.filter { !$0.disabled }.count) enabled",
                         detail: "\(startup.items.count) launch agents and daemons")
                    tile(.spaceLens, value: Fmt.percent(stats.disk.fraction),
                         detail: "\(Fmt.bytes(stats.disk.used)) of \(Fmt.bytes(stats.disk.total)) in use")
                    tile(.dashboard, value: stats.memory.pressureName,
                         detail: "Memory pressure · \(Fmt.memory(stats.memory.used)) in use")
                }
            }
            .padding(28)
        }
    }

    private func tile(_ section: Section, value: String, detail: String) -> some View {
        HoverTile { state.section = section } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    IconBadge(icon: section.icon, accent: section.accent, size: 34)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.3))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    Text(value).font(Theme.display(22).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A card that lifts slightly under the pointer and acts as a button.
struct HoverTile<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .card()
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Color.white.opacity(hovering ? 0.04 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var stats: SystemStats

    private let gpuAccent = Accent(start: Color(hex: 0xFF9A5A), end: Color(hex: 0xFF4F8B))
    private let batteryAccent = Accent(start: Color(hex: 0x7BEA9B), end: Theme.positive)
    private let diskAccent = Accent(start: Color(hex: 0xFFC857), end: Color(hex: 0xFF7A45))

    var body: some View {
        Page(title: "Dashboard", subtitle: "\(stats.chip.isEmpty ? stats.model : stats.chip) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)") {
            EmptyView()
        } content: {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        gauge("Processor", "cpu.fill", Section.processes.accent, stats.cpu, Fmt.percent(stats.cpu),
                              caption: "\(ProcessInfo.processInfo.activeProcessorCount) cores")
                        if let gpu = stats.gpu {
                            gauge("Graphics", "display", gpuAccent, gpu.utilization, Fmt.percent(gpu.utilization),
                                  caption: "\(Fmt.memory(UInt64(gpu.memoryInUse))) in use")
                        }
                        gauge("Memory", "memorychip.fill", Section.privacy.accent, stats.memory.fraction, Fmt.percent(stats.memory.fraction),
                              caption: "\(Fmt.memory(stats.memory.used)) of \(Fmt.memory(stats.memory.total))")
                        gauge("Storage", "internaldrive.fill", Section.duplicates.accent, stats.disk.fraction, Fmt.percent(stats.disk.fraction),
                              caption: "\(Fmt.bytes(stats.disk.free)) free")
                        if stats.battery.present {
                            gauge("Battery", stats.battery.charging ? "battery.100.bolt" : "battery.75", batteryAccent,
                                  Double(stats.battery.percent) / 100, "\(stats.battery.percent)%",
                                  caption: stats.battery.charging ? "Charging" : stats.battery.onAC ? "On power" : "On battery", warnWhenHigh: false)
                        }
                    }
                    row {
                        chart("Processor", loadCaption, stats.cpuHistory, maximum: 1, accent: Section.processes.accent) {
                            coreBars
                        }
                        chart("Graphics", stats.gpu?.name ?? "No GPU statistics", stats.gpuHistory, maximum: 1, accent: gpuAccent) {
                            HStack(spacing: 22) {
                                Metric(label: "Load", value: Fmt.percent(stats.gpu?.utilization ?? 0))
                                Metric(label: "Memory in use", value: Fmt.memory(UInt64(stats.gpu?.memoryInUse ?? 0)))
                                Metric(label: "Thermal", value: thermalName)
                            }
                        }
                    }
                    row {
                        chart("Memory", "Pressure: \(stats.memory.pressureName)", stats.memoryHistory, maximum: 1, accent: Section.privacy.accent) {
                            HStack(spacing: 15) {
                                Metric(label: "Apps", value: Fmt.memory(stats.memory.app))
                                Metric(label: "Wired", value: Fmt.memory(stats.memory.wired))
                                Metric(label: "Compressed", value: Fmt.memory(stats.memory.compressed))
                                Metric(label: "Cached", value: Fmt.memory(stats.memory.cached))
                                Metric(label: "Swap", value: Fmt.memory(stats.memory.swapUsed))
                            }
                        }
                        chart("Disk activity", "Read + write", stats.diskHistory, maximum: nil, accent: diskAccent) {
                            HStack(spacing: 22) {
                                Metric(label: "Read", value: Fmt.rate(stats.diskRead))
                                Metric(label: "Write", value: Fmt.rate(stats.diskWrite))
                                Metric(label: "Free", value: Fmt.bytes(stats.disk.free))
                            }
                        }
                    }
                    row {
                        chart("Network", stats.localAddress.map { "\($0.address) · \($0.interface)" } ?? "Not connected",
                              stats.downloadHistory, maximum: nil, accent: Section.duplicates.accent) {
                            HStack(spacing: 22) {
                                Metric(label: "Download", value: Fmt.rate(stats.download))
                                Metric(label: "Upload", value: Fmt.rate(stats.upload))
                            }
                        }
                        topApps
                    }
                    row {
                        if stats.battery.present { battery }
                        details
                    }
                }
                .padding(28)
            }
        }
        .onAppear { stats.wantsTopApps = true }
        .onDisappear { stats.wantsTopApps = false }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 16) { content() }.fixedSize(horizontal: false, vertical: true)
    }

    private var loadCaption: String {
        stats.loadAverage.isEmpty ? "Last 2 minutes" : "Load " + stats.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }

    /// One bar per logical core.
    private var coreBars: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(stats.cores.enumerated()), id: \.offset) { _, load in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.track)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill((Theme.usage(load) ?? Section.processes.accent).gradient)
                            .frame(height: max(2, 30 * load))
                    }
                    .frame(height: 30)
                    .frame(maxWidth: 14)
                    .help(Fmt.percent(load))
                }
            }
            .animation(.easeOut(duration: 0.4), value: stats.cores)
            Text(SystemProbes.coreTiers.map { "\($0.count) \($0.name)" }.joined(separator: " · ") + " cores")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func gauge(_ title: String, _ icon: String, _ accent: Accent, _ fraction: Double, _ value: String,
                       caption: String, warnWhenHigh: Bool = true) -> some View {
        VStack(spacing: 12) {
            Ring(fraction: fraction, accent: warnWhenHigh ? (Theme.usage(fraction) ?? accent) : accent, lineWidth: 10) {
                VStack(spacing: 1) {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent.gradient)
                    Text(value).font(Theme.display(21).monospacedDigit())
                }
            }
            .frame(width: 104, height: 104)
            VStack(spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(caption).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 18)
    }

    private func chart<Footer: View>(_ title: String, _ caption: String, _ values: [Double], maximum: Double?, accent: Accent,
                                     @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title, caption)
            Sparkline(values: values, maximum: maximum, accent: accent).frame(height: 64)
            footer()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 20)
    }

    private func cardHeader(_ title: String, _ caption: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer()
            Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
    }

    private var topApps: some View {
        let heaviest = max(stats.topApps.map(\.memory).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            cardHeader("Top applications", "By memory, with CPU")
            if stats.topApps.isEmpty {
                Text("Measuring…").font(.callout).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(stats.topApps.prefix(5)) { app in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(app.name).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%% CPU", app.cpu)).font(.caption.monospacedDigit())
                            .foregroundStyle(app.cpu >= 80 ? Theme.critical : .white.opacity(0.5))
                        Text(Fmt.memory(UInt64(app.memory))).font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(width: 74, alignment: .trailing)
                    }
                    UsageBar(fraction: Double(app.memory) / Double(heaviest), accent: Section.processes.accent, height: 4)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 20)
    }

    private var battery: some View {
        let battery = stats.battery
        return VStack(alignment: .leading, spacing: 14) {
            cardHeader("Battery", battery.charging ? "Charging" : battery.onAC ? "On power" : "On battery")
            UsageBar(fraction: Double(battery.percent) / 100,
                     accent: battery.percent <= 20 ? Accent(start: Color(hex: 0xFF7A8F), end: Theme.critical) : batteryAccent, height: 8)
            VStack(spacing: 10) {
                detailRow("Charge", "\(battery.percent)%")
                if let minutes = battery.minutesRemaining {
                    detailRow(battery.charging ? "Until full" : "Time remaining", "\(minutes / 60)h \(minutes % 60)m")
                }
                if let watts = battery.watts {
                    detailRow(watts >= 0 ? "Charging at" : "Drawing", String(format: "%.1f W", abs(watts)))
                }
                if let cycles = battery.cycles { detailRow("Cycles", "\(cycles)") }
                if let health = battery.healthPercent { detailRow("Health", "\(health)%") }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 20)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("This Mac", "")
            VStack(spacing: 10) {
                detailRow("Model", stats.model)
                detailRow("Chip", stats.chip.isEmpty ? "—" : stats.chip)
                detailRow("Memory", Fmt.memory(stats.memory.total))
                detailRow("Storage", Fmt.bytes(stats.disk.total))
                detailRow("Uptime", Fmt.duration(Date().timeIntervalSince(stats.bootTime)))
                detailRow("Thermal state", thermalName)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 20)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
        }
    }

    private var thermalName: String {
        switch stats.thermal {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.Key.permanentDelete) private var permanentDelete = false
    @AppStorage(Prefs.Key.largeMinMB) private var largeMinMB = 100
    @AppStorage(Prefs.Key.duplicateMinKB) private var duplicateMinKB = 1_000
    @AppStorage(Prefs.Key.scheduleDays) private var scheduleDays = 0
    @AppStorage(Prefs.Key.junkAlertGB) private var junkAlertGB = 2
    @AppStorage(Prefs.Key.lowDiskGB) private var lowDiskGB = 0
    @State private var exclusions = Prefs.exclusions
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            SwiftUI.Section("Removal") {
                Picker("When cleaning", selection: $permanentDelete) {
                    Text("Move items to the Trash (recommended)").tag(false)
                    Text("Delete immediately").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            SwiftUI.Section("Scanning") {
                Picker("Large files start at", selection: $largeMinMB) {
                    ForEach([50, 100, 250, 500, 1_000], id: \.self) { Text(Fmt.bytes(Int64($0) * 1_000_000)).tag($0) }
                }
                Picker("Compare duplicates from", selection: $duplicateMinKB) {
                    ForEach([100, 1_000, 10_000, 100_000], id: \.self) { Text(Fmt.bytes(Int64($0) * 1_000)).tag($0) }
                }
            }
            SwiftUI.Section {
                Picker("Scan for junk automatically", selection: $scheduleDays) {
                    Text("Never").tag(0)
                    Text("Every day").tag(1)
                    Text("Every week").tag(7)
                }
                Picker("Notify when junk reaches", selection: $junkAlertGB) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) GB").tag($0) }
                }
                .disabled(scheduleDays == 0)
                Picker("Warn when free space drops below", selection: $lowDiskGB) {
                    Text("Never").tag(0)
                    ForEach([10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                }
            } header: {
                Text("Automation")
            } footer: {
                Text("Automation runs while Sweep is open. When it is on, closing the window leaves Sweep running in the Dock.")
            }
            .onChange(of: scheduleDays) { _, days in if days > 0 { Notifier.requestPermission() } }
            .onChange(of: lowDiskGB) { _, level in if level > 0 { Notifier.requestPermission() } }
            SwiftUI.Section("General") {
                Toggle("Open Sweep at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(Permissions.hasFullDiskAccess ? "Granted" : "Not granted").foregroundStyle(.secondary)
                        Button("Open Settings", action: Finder.openFullDiskAccessSettings)
                    }
                }
            }
            SwiftUI.Section("Ignored locations") {
                if exclusions.isEmpty {
                    Text("Sweep never scans or removes anything inside ignored folders.").foregroundStyle(.secondary)
                }
                ForEach(exclusions, id: \.self) { path in
                    HStack {
                        Text(Fmt.tilde(path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { exclusions.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    for path in Finder.chooseFolders() where !exclusions.contains(path) { exclusions.append(path) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 660)
        .tint(Accent.brand.start)
        .preferredColorScheme(.dark)
        .onChange(of: exclusions) { _, value in Prefs.exclusions = value }
    }
}
