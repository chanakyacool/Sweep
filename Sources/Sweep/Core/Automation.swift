import AppKit
import Foundation
import UserNotifications

/// Thin wrapper over the system notification centre.
enum Notifier {
    /// Notifications need a real app bundle; the bare executable used for self-tests has none.
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a notification. Clicking it opens Sweep on the given section.
    static func send(id: String, title: String, body: String, section: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["section": section]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Background duties that run while Sweep is open (including when only its menu bar item is showing):
/// scheduled junk scans, low-disk warnings and per-application resource sampling.
@MainActor
final class Scheduler {
    static let shared = Scheduler()

    private var timer: Timer?
    private weak var state: AppState?

    func start(state: AppState) {
        self.state = state
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Give the app a moment to settle before the first pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.tick() }
    }

    private func tick() {
        sampleProcesses()
        checkDiskSpace()
        runScheduledScanIfDue()
    }

    // MARK: Process sampling

    private func sampleProcesses() {
        Task.detached(priority: .utility) {
            History.shared.recordProcesses(Scheduler.aggregate(ProcessCatalog.snapshot()))
        }
    }

    /// Folds helper processes into their owning application and keeps the significant consumers.
    nonisolated static func aggregate(_ rows: [ProcessRow]) -> [(name: String, cpu: Double, memory: Int64)] {
        var totals: [String: (cpu: Double, memory: Int64)] = [:]
        for row in rows {
            let name: String
            if let range = row.executable.range(of: ".app/") {
                name = (String(row.executable[..<range.lowerBound]) as NSString).lastPathComponent
            } else {
                name = (row.executable as NSString).lastPathComponent
            }
            guard !name.isEmpty else { continue }
            totals[name, default: (0, 0)].cpu += row.cpu
            totals[name, default: (0, 0)].memory += row.memory
        }
        let ranked = totals.sorted { $0.value.memory > $1.value.memory }
        let heavy = ranked.prefix(30).map(\.key)
        let busy = ranked.filter { $0.value.cpu >= 5 }.map(\.key)
        let keep = Set(heavy + busy)
        return ranked.filter { keep.contains($0.key) }.map { ($0.key, $0.value.cpu, $0.value.memory) }
    }

    // MARK: Low disk space

    private func checkDiskSpace() {
        guard let state, Prefs.lowDiskGB > 0, state.stats.disk.total > 0 else { return }
        let free = state.stats.disk.free
        guard free < Int64(Prefs.lowDiskGB) * 1_000_000_000,
              Date().timeIntervalSince(Prefs.lastLowDiskAlert) > 86_400 else { return }
        Prefs.lastLowDiskAlert = Date()
        Notifier.send(id: "low-disk", title: "Your disk is running low",
                      body: "Only \(Fmt.bytes(free)) is free. Open Sweep to see what can be removed.",
                      section: Section.smartScan.rawValue)
    }

    // MARK: Scheduled scan

    private func runScheduledScanIfDue() {
        guard let state, Prefs.scheduleDays > 0, !state.smartScanning, state.junk.state != .scanning, state.junk.state != .cleaning,
              Date().timeIntervalSince(Prefs.lastScheduledScan) >= Double(Prefs.scheduleDays) * 86_400 else { return }
        Prefs.lastScheduledScan = Date()
        Task {
            await state.junk.scanAndWait()
            let found = state.junk.selectedSize
            guard found >= Int64(Prefs.junkAlertGB) * 1_000_000_000 else { return }
            Notifier.send(id: "scheduled-scan", title: "\(Fmt.bytes(found)) of junk is ready to clean",
                          body: "Sweep's scheduled scan finished. Review the results and clean with one click.",
                          section: Section.junk.rawValue)
        }
    }
}
