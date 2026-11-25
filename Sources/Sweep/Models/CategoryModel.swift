import Foundation
import SwiftUI

enum ScanState: Equatable {
    case idle, scanning, ready, cleaning
}

/// Drives any category-based cleaner (System Junk, Privacy, Developer) from a scanner function.
@MainActor
final class CategoryModel: ObservableObject {
    typealias Scanner = @Sendable (@escaping ProgressReport, CancelFlag) -> [CleanCategory]

    @Published private(set) var categories: [CleanCategory] = []
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var progress = ""
    @Published private(set) var lastOutcome: Remover.Outcome?

    /// The section name under which scans and cleanups appear in the history.
    let name: String
    private let scanner: Scanner
    private var cancelFlag = CancelFlag()

    init(name: String, scanner: @escaping Scanner) {
        self.name = name
        self.scanner = scanner
    }

    var totalSize: Int64 { categories.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { categories.reduce(0) { $0 + $1.selectedSize } }
    var selectedCount: Int { categories.reduce(0) { $0 + $1.selectedCount } }
    var itemCount: Int { categories.reduce(0) { $0 + $1.items.count } }
    var hasScanned: Bool { state == .ready || state == .cleaning }

    // MARK: Scanning

    func scan() {
        Task { await scanAndWait() }
    }

    func scanAndWait() async {
        guard state != .scanning, state != .cleaning else { return }
        state = .scanning
        progress = "Preparing…"
        lastOutcome = nil
        let flag = CancelFlag()
        cancelFlag = flag
        let scanner = self.scanner
        let report: ProgressReport = { [weak self] text in Task { @MainActor in self?.progress = text } }
        let found = await Task.detached(priority: .userInitiated) { scanner(report, flag) }.value
        categories = flag.isCancelled ? [] : found
        state = flag.isCancelled ? .idle : .ready
        if !flag.isCancelled { History.shared.recordScan(section: name, bytes: totalSize, items: itemCount) }
    }

    func cancel() {
        cancelFlag.cancel()
    }

    // MARK: Selection

    func setSelected(_ selected: Bool, item itemID: String, in categoryID: String) {
        guard let c = categories.firstIndex(where: { $0.id == categoryID }),
              let i = categories[c].items.firstIndex(where: { $0.id == itemID }) else { return }
        categories[c].items[i].selected = selected
    }

    func setSelected(_ selected: Bool, category categoryID: String) {
        guard let c = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        for i in categories[c].items.indices { categories[c].items[i].selected = selected }
    }

    func setAllSelected(_ selected: Bool) {
        for c in categories.indices {
            for i in categories[c].items.indices { categories[c].items[i].selected = selected }
        }
    }

    /// Selects only the items whose date is older than the given number of days.
    func selectOlder(thanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for c in categories.indices {
            for i in categories[c].items.indices {
                categories[c].items[i].selected = (categories[c].items[i].date ?? Date()) < cutoff
            }
        }
    }

    // MARK: Cleaning

    func clean() async {
        guard state == .ready, selectedCount > 0 else { return }
        state = .cleaning
        let permanentPreference = Prefs.permanentDelete
        let batches: [(targets: [Remover.Target], permanent: Bool)] = categories.map { category in
            (category.items.filter(\.selected).map { Remover.Target(path: $0.path, size: $0.size) },
             category.deletesPermanently || permanentPreference)
        }
        let name = self.name
        let outcome = await Task.detached(priority: .userInitiated) {
            let total = batches.reduce(Remover.Outcome()) { $0 + Remover.remove($1.targets, permanently: $1.permanent) }
            History.shared.recordCleanup(section: name, targets: batches.flatMap(\.targets), outcome: total)
            return total
        }.value

        // Keep whatever could not be removed so the user can see and retry it.
        for c in categories.indices {
            categories[c].items.removeAll { $0.selected && !FS.exists($0.path) }
        }
        categories.removeAll { $0.items.isEmpty }
        lastOutcome = outcome
        state = .ready
    }
}
