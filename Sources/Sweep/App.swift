import AppKit
import SwiftUI
import UserNotifications

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        SweepApp.main()
    }
}

struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Sweep", id: "main") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1_100, minHeight: 820)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_240, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Run Smart Scan") {
                    state.section = .smartScan
                    Task { await state.smartScan() }
                }
                .keyboardShortcut("r")
                Divider()
                ForEach(Array(Section.allCases.prefix(9).enumerated()), id: \.element.id) { index, section in
                    Button(section.title) { state.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let directory = arguments[index + 1]
            Task { @MainActor in await Snapshot.capture(into: directory, scan: arguments.contains("--with-scan")) }
            return
        }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        Task { @MainActor in Scheduler.shared.start(state: AppState.shared) }
    }

    /// With scheduled scans or disk warnings on, closing the window leaves Sweep running in the Dock so they keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Prefs.scheduleDays == 0 && Prefs.lowDiskGB == 0
    }

    /// Clicking a notification opens the section it refers to.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let name = response.notification.request.content.userInfo["section"] as? String
        Task { @MainActor in
            if let section = name.flatMap(Section.init(rawValue:)) { AppState.shared.section = section }
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Development aids

/// `--snapshot <dir>` renders every section to a PNG, used to review the interface without manual clicking.
@MainActor
enum Snapshot {
    static func capture(into directory: String, scan: Bool) async {
        let state = AppState.shared
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if scan {
            await state.junk.scanAndWait()
            state.uninstaller.load()
            state.containers.scan()
            for _ in 0..<70 where state.containers.state == .scanning { try? await Task.sleep(nanoseconds: 500_000_000) }
            state.processes.showingTrends = true
            state.spaceLens.scan("/Applications")
            for _ in 0..<120 where state.spaceLens.state == .scanning {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        let only = CommandLine.arguments.firstIndex(of: "--only").flatMap { CommandLine.arguments.dropFirst($0 + 1).first }
        for section in Section.allCases where only == nil || only == section.rawValue {
            state.section = section
            // A single-section capture waits longer so live charts have data to draw.
            try? await Task.sleep(nanoseconds: only == nil ? 1_200_000_000 : 9_000_000_000)
            guard let window = NSApp.windows.first(where: { $0.title == "Sweep" || $0.identifier?.rawValue.contains("main") == true }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(directory)/\(section.rawValue).png"))
        }
        NSApp.terminate(nil)
    }
}

/// `--selftest` exercises the engines against a throwaway directory and read-only system queries.
enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL")  \(name)")
            if !condition { failures += 1 }
        }
        let quiet: ProgressReport = { _ in }
        let home = FS.home

        // Deletion guard
        for path in ["/", "/System/Library", "/usr/bin/ls", home, home + "/Documents", home + "/Library",
                     home + "/Library/Caches", home + "/.Trash", "/Applications", home + "/Library/Keychains/login.keychain-db",
                     "relative/path", home + "/Documents/../Documents"] {
            check("refuses to remove \(path)", !Remover.isSafeToRemove(path))
        }
        for path in [home + "/Library/Caches/com.example.app", home + "/.Trash/old.zip", home + "/Projects/demo/node_modules", "/Applications/Example.app"] {
            check("allows removing \(path)", Remover.isSafeToRemove(path))
        }

        // Scratch tree
        let root = NSTemporaryDirectory() + "sweep-selftest-\(getpid())"
        let manager = FileManager.default
        try? manager.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
        try? manager.createDirectory(atPath: root + "/proj/node_modules/x", withIntermediateDirectories: true)
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var different = payload
        different[150_000] ^= 0xFF
        manager.createFile(atPath: root + "/one.bin", contents: payload)
        manager.createFile(atPath: root + "/a/two.bin", contents: payload)
        manager.createFile(atPath: root + "/a/b/three.bin", contents: payload)
        manager.createFile(atPath: root + "/a/same-size-different.bin", contents: different)
        manager.createFile(atPath: root + "/proj/node_modules/x/index.js", contents: Data(repeating: 1, count: 2_000_000))
        try? manager.linkItem(atPath: root + "/one.bin", toPath: root + "/hardlink.bin")

        let measured = FS.size(of: root)
        check("measures tree size (\(Fmt.bytes(measured)))", measured >= 3_100_000 && measured < 3_600_000)

        let groups = DuplicateScanner.scan(roots: [root], minimum: 100_000, report: quiet, cancel: CancelFlag())
        check("finds exactly one duplicate group", groups.count == 1)
        check("group holds the three identical copies, not the hard link or the altered file", groups.first?.files.count == 3)

        let tree = DiskMapper.map(root, report: quiet, cancel: CancelFlag())
        check("disk map total matches measured size", tree?.size == measured)
        check("disk map sorts largest first", tree?.children.first?.name == "proj")

        let outcome = Remover.remove([Remover.Target(path: root + "/a/two.bin", size: 300_000)], permanently: true)
        check("removes a file", outcome.removed == 1 && !FS.exists(root + "/a/two.bin"))

        // Trash round trip: the file must leave its folder; the copy in the Trash is then discarded.
        let trashName = "sweep-selftest-\(getpid()).tmp"
        manager.createFile(atPath: root + "/" + trashName, contents: Data("x".utf8))
        let trashed = Remover.remove([Remover.Target(path: root + "/" + trashName, size: 1)], permanently: false)
        check("moves a file to the Trash", trashed.removed == 1 && !FS.exists(root + "/" + trashName))
        check("remembers where the trashed file went", trashed.trashed[root + "/" + trashName] != nil)
        let undoStore = History(path: NSTemporaryDirectory() + "sweep-undo-\(getpid()).sqlite")
        undoStore.recordCleanup(section: "Undo", targets: [Remover.Target(path: root + "/" + trashName, size: 1)], outcome: trashed)
        let undoID = undoStore.cleanups().first?.id ?? -1
        check("history marks the trashed file as restorable", undoStore.removedItems(cleanup: undoID).first?.restorable == true)
        let restored = undoStore.putBack(cleanup: undoID)
        check("puts the file back where it was", restored.restored == 1 && restored.failed == 0 && FS.exists(root + "/" + trashName))
        check("a restored file is no longer offered for put back", undoStore.removedItems(cleanup: undoID).isEmpty == false
              && undoStore.removedItems(cleanup: undoID).first?.restorable == false)
        for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: NSTemporaryDirectory() + "sweep-undo-\(getpid()).sqlite" + suffix) }
        try? manager.removeItem(atPath: home + "/.Trash/" + trashName)

        try? manager.removeItem(atPath: root)
        check("cleans up scratch tree", !FS.exists(root))

        // History store, against a throwaway database
        let historyPath = NSTemporaryDirectory() + "sweep-history-\(getpid()).sqlite"
        let store = History(path: historyPath)
        manager.createFile(atPath: root + "-kept.tmp", contents: Data("x".utf8))
        store.recordCleanup(section: "Test",
                            targets: [Remover.Target(path: "/nonexistent/sweep-a", size: 700), Remover.Target(path: root + "-kept.tmp", size: 5)],
                            outcome: Remover.Outcome(freed: 700, removed: 1, failures: ["kept"]))
        store.recordScan(section: "Test", bytes: 1_234, items: 3)
        store.sampleDisk(used: 100, total: 1_000)
        store.sampleDisk(used: 200, total: 1_000)
        let logged = store.cleanups()
        check("history records a cleanup with its totals", logged.count == 1 && logged.first?.freed == 700 && logged.first?.failures == 1)
        check("history lists only paths that are really gone", store.removedItems(cleanup: logged.first?.id ?? -1).map(\.path) == ["/nonexistent/sweep-a"])
        check("history totals and daily buckets agree", store.totals().freed == 700 && store.freedPerDay(days: 30).last?.freed == 700)
        check("history keeps one disk sample per hour", store.diskSamples(days: 1).count == 1)
        check("history returns the latest scan", store.latestScans().first?.bytes == 1_234)
        store.recordProcesses([("Browser", 12.5, 900), ("Editor", 1.0, 300)])
        store.recordProcesses([("Browser", 7.5, 1_100)])
        let trends = store.processTrends(hours: 1)
        check("process trends average and peak per application",
              trends.first?.name == "Browser" && trends.first?.averageCPU == 10 && trends.first?.peakMemory == 1_100 && trends.first?.samples == 2)
        store.clear()
        check("history can be cleared", store.cleanups().isEmpty && store.diskSamples(days: 1).isEmpty)
        for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: historyPath + suffix) }
        try? manager.removeItem(atPath: root + "-kept.tmp")

        // Pure helpers behind the newer sections
        check("parses Docker sizes", ContainerScanner.parseSize("1.5GB") == 1_500_000_000 && ContainerScanner.parseSize("0B (virtual 187MB)") == 0
              && ContainerScanner.parseSize("12.4kB") == 12_400)
        let grouped = Scheduler.aggregate([
            ProcessRow(pid: 1, name: "a", cpu: 2, memory: 100, user: "u", executable: "/Applications/Web.app/Contents/MacOS/Web"),
            ProcessRow(pid: 2, name: "b", cpu: 3, memory: 50, user: "u", executable: "/Applications/Web.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            ProcessRow(pid: 3, name: "c", cpu: 1, memory: 10, user: "u", executable: "/usr/sbin/daemon"),
        ])
        check("folds helper processes into their application", grouped.first?.name == "Web" && grouped.first?.cpu == 5 && grouped.first?.memory == 150)

        // Similar pictures: a resized copy must match, an unrelated picture must not
        let pictures = root + "-pictures"
        try? manager.createDirectory(atPath: pictures, withIntermediateDirectories: true)
        SelfTest.writeTestImage(pictures + "/original.png", side: 400, seed: 3)
        SelfTest.writeTestImage(pictures + "/smaller-copy.png", side: 200, seed: 3)
        SelfTest.writeTestImage(pictures + "/different.png", side: 400, seed: 11)
        let similar = SimilarImageScanner.scan(roots: [pictures], minimumFileSize: 1_000, report: quiet, cancel: CancelFlag())
        let similarNames = similar.first?.files.map { ($0.path as NSString).lastPathComponent } ?? []
        check("groups a resized copy with its original, best first", similar.count == 1 && similarNames == ["original.png", "smaller-copy.png"])
        try? manager.removeItem(atPath: pictures)

        // Hardware probes behind the dashboard
        let gpu = SystemProbes.gpu()
        print("INFO  GPU: \(gpu?.name ?? "none") \(Fmt.percent(gpu?.utilization ?? 0)), \(Fmt.memory(UInt64(gpu?.memoryInUse ?? 0))) in use")
        check("reads GPU load", gpu != nil && (0...1).contains(gpu?.utilization ?? -1))
        let cores = SystemProbes.coreTicks()
        check("reads every logical core", cores.count == ProcessInfo.processInfo.activeProcessorCount)
        check("core tiers add up to the core count", SystemProbes.coreTiers.reduce(0) { $0 + $1.count } == cores.count)
        let disk = SystemProbes.diskBytes()
        check("reads disk activity counters", disk.read > 0 && disk.written > 0)
        check("reads load average", SystemProbes.loadAverage().count == 3)
        print("INFO  address: \(SystemProbes.localAddress().map { "\($0.address) on \($0.interface)" } ?? "none")")

        // Read-only system queries
        let junk = JunkScanner.scan(report: quiet, cancel: CancelFlag())
        print("INFO  junk: " + junk.map { "\($0.title) \(Fmt.bytes($0.size)) (\($0.items.count))" }.joined(separator: ", "))
        check("junk scan returns categories", !junk.isEmpty)
        check("junk scan never selects Apple caches", junk.first { $0.id == "caches" }?.items.contains { $0.selected && $0.name.hasPrefix("com.apple.") } == false)

        let apps = AppCatalog.installedApps()
        print("INFO  \(apps.count) applications")
        check("lists installed applications", !apps.isEmpty)

        let startup = StartupCatalog.load()
        print("INFO  \(startup.count) startup items, \(startup.filter(\.running).count) running, \(startup.filter(\.disabled).count) disabled")

        let processes = ProcessCatalog.snapshot()
        print("INFO  \(processes.count) processes")
        check("lists processes", processes.count > 20)

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0
    }

    /// Draws a deterministic pattern of grey blocks with enough detail to fingerprint and to exceed the size floor.
    static func writeTestImage(_ path: String, side: Int, seed: UInt64) {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat((state >> 33) % 1_000) / 1_000
        }
        // Coarse 8x8 blocks define the look; fine noise on top makes the PNG large enough to be scanned.
        let block = CGFloat(side) / 8
        for row in 0..<8 {
            for column in 0..<8 {
                NSColor(white: next(), alpha: 1).setFill()
                NSRect(x: CGFloat(column) * block, y: CGFloat(row) * block, width: block, height: block).fill()
            }
        }
        let cell = CGFloat(side) / 100
        for row in 0..<100 {
            for column in 0..<100 {
                NSColor(white: next(), alpha: 0.12).setFill()
                NSRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill(using: .sourceOver)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
