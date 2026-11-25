import SwiftUI

@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var totals = HistoryTotals()
    @Published private(set) var cleanups: [CleanupRecord] = []
    @Published private(set) var freedPerDay: [(day: Date, freed: Int64)] = []
    @Published private(set) var diskSamples: [DiskSample] = []
    @Published private(set) var latestScans: [ScanRecord] = []
    @Published private(set) var removedItems: [Int64: [RemovedItem]] = [:]
    @Published var expanded: Int64?

    func reload() {
        Task {
            let store = History.shared
            let loaded = await Task.detached {
                (store.totals(), store.cleanups(), store.freedPerDay(days: 30), store.diskSamples(days: 30), store.latestScans())
            }.value
            totals = loaded.0
            cleanups = loaded.1
            freedPerDay = loaded.2
            diskSamples = loaded.3
            latestScans = loaded.4
        }
    }

    func toggle(_ record: CleanupRecord) {
        expanded = expanded == record.id ? nil : record.id
        guard expanded == record.id, removedItems[record.id] == nil else { return }
        Task { removedItems[record.id] = await Task.detached { History.shared.removedItems(cleanup: record.id) }.value }
    }

    @Published private(set) var message: String?

    /// Restores everything from this cleanup that is still in the Trash.
    func putBack(_ record: CleanupRecord) {
        Task {
            let result = await Task.detached { History.shared.putBack(cleanup: record.id) }.value
            message = result.restored == 0 && result.failed == 0
                ? "Nothing from this cleanup is left in the Trash."
                : "Put back \(result.restored) item\(result.restored == 1 ? "" : "s")"
                    + (result.failed > 0 ? "; \(result.failed) could not be moved (Full Disk Access may be needed)." : ".")
            removedItems[record.id] = await Task.detached { History.shared.removedItems(cleanup: record.id) }.value
        }
    }

    func clear() {
        History.shared.clear()
        removedItems = [:]
        expanded = nil
        reload()
    }

    /// Average change in used space per day across the sampled period; nil until a day of data exists.
    var dailyGrowth: Double? {
        guard let first = diskSamples.first, let last = diskSamples.last else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        return days >= 1 ? Double(last.used - first.used) / days : nil
    }

    /// Days until the disk is full at the current growth rate, when it is actually growing.
    var daysUntilFull: Int? {
        guard let growth = dailyGrowth, growth > 50_000_000, let last = diskSamples.last else { return nil }
        return Int(Double(last.total - last.used) / growth)
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @State private var confirmingClear = false
    @Environment(\.sectionStyle) private var style

    var body: some View {
        Page(title: "History", subtitle: "What Sweep has cleaned and how your storage is changing. Stored only on this Mac.") {
            Button("Clear History") { confirmingClear = true }.disabled(model.cleanups.isEmpty && model.diskSamples.isEmpty)
        } content: {
            ScrollView {
                VStack(spacing: 16) {
                    if let message = model.message {
                        NoticeBanner(icon: "arrow.uturn.backward.circle.fill", text: message, tint: Theme.info).padding(.horizontal, -20).padding(.top, -12)
                    }
                    HStack(spacing: 16) {
                        stat("Freed in total", Fmt.bytes(model.totals.freed), "\(model.totals.items.formatted()) items removed")
                        stat("Last 30 days", Fmt.bytes(model.totals.freedLast30Days), "\(model.totals.cleanups) cleanups overall")
                        stat("Storage trend", trendValue, trendCaption)
                    }
                    HStack(spacing: 16) {
                        freedChart
                        diskChart
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if !model.latestScans.isEmpty { scans }
                    log
                }
                .padding(28)
            }
        }
        .onAppear { model.reload() }
        .alert("Clear all history?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The record of past cleanups and the storage trend are erased. No files are affected.")
        }
    }

    // MARK: Summary

    private var trendValue: String {
        guard let growth = model.dailyGrowth else { return "—" }
        return (growth >= 0 ? "+" : "−") + Fmt.bytes(Int64(abs(growth))) + "/day"
    }

    private var trendCaption: String {
        guard model.dailyGrowth != nil else { return "Needs a day of data" }
        if let days = model.daysUntilFull { return days > 730 ? "Over 2 years until full" : "Full in about \(days) days" }
        return "Usage is stable or shrinking"
    }

    private func stat(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.42))
            Text(value).font(Theme.display(26).monospacedDigit()).foregroundStyle(style.accent.gradient).lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 20)
    }

    // MARK: Charts

    private var freedChart: some View {
        let peak = max(model.freedPerDay.map(\.freed).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 14) {
            header("Space freed", "Per day, last 30 days")
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(model.freedPerDay, id: \.day) { entry in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(entry.freed > 0 ? AnyShapeStyle(style.accent.gradient) : AnyShapeStyle(Theme.track))
                        .frame(height: entry.freed > 0 ? max(5, 96 * CGFloat(entry.freed) / CGFloat(peak)) : 3)
                        .frame(maxWidth: .infinity)
                        .help("\(Fmt.date(entry.day)) — \(Fmt.bytes(entry.freed))")
                }
            }
            .frame(height: 96, alignment: .bottom)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 20)
    }

    private var diskChart: some View {
        let used = model.diskSamples.map { Double($0.used) }
        let low = used.min() ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            header("Storage used", "Hourly samples, last 30 days")
            if used.count >= 2 {
                // Plotted relative to the lowest reading so small changes are visible.
                Sparkline(values: used.map { $0 - low }, accent: Section.spaceLens.accent).frame(height: 96)
                HStack(spacing: 22) {
                    Metric(label: "Lowest", value: Fmt.bytes(Int64(low)))
                    Metric(label: "Highest", value: Fmt.bytes(Int64(used.max() ?? 0)))
                    Metric(label: "Now", value: Fmt.bytes(Int64(used.last ?? 0)))
                }
            } else {
                Text("Sweep records disk usage once an hour while it is running. The trend appears after a few samples.")
                    .font(.callout).foregroundStyle(.white.opacity(0.5)).frame(height: 96, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 20)
    }

    private func header(_ title: String, _ caption: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer()
            Text(caption).font(.caption).foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: Lists

    private var scans: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Latest scan results", "What each scan last found")
            ForEach(model.latestScans, id: \.section) { scan in
                HStack {
                    Text(scan.section)
                    Text("· \(scan.items.formatted()) items · \(Fmt.ago(scan.date))").font(.caption).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    SizeLabel(bytes: scan.bytes)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 20)
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Cleanup log", "Select an entry to see exactly what was removed").padding(20)
            if model.cleanups.isEmpty {
                Text("Nothing has been cleaned yet. Every cleanup you run will be listed here.")
                    .font(.callout).foregroundStyle(.white.opacity(0.5)).padding([.horizontal, .bottom], 20)
            }
            ForEach(model.cleanups) { record in
                Hairline()
                Button { model.toggle(record) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: model.expanded == record.id ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.section)
                            Text(record.date.formatted(date: .abbreviated, time: .shortened)
                                 + " · \(record.items) item\(record.items == 1 ? "" : "s")"
                                 + (record.failures > 0 ? " · \(record.failures) failed" : ""))
                                .font(.caption).foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        SizeLabel(bytes: record.freed)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.expanded == record.id {
                    VStack(alignment: .leading, spacing: 6) {
                        let items = model.removedItems[record.id] ?? []
                        let restorable = items.filter(\.restorable).count
                        HStack {
                            Text(restorable > 0 ? "\(restorable) of \(items.count) still in the Trash" : "Nothing left in the Trash to put back")
                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            Button("Put Back") { model.putBack(record) }.buttonStyle(.glass).disabled(restorable == 0)
                        }
                        .padding(.bottom, 4)
                        ForEach(items) { item in
                            HStack {
                                Image(systemName: item.restorable ? "arrow.uturn.backward.circle" : "circle.dotted")
                                    .font(.caption).foregroundStyle(item.restorable ? Theme.positive : .white.opacity(0.25))
                                    .help(item.restorable ? "Still in the Trash" : "No longer in the Trash, or already restored")
                                Text(Fmt.tilde(item.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer()
                                Text(Fmt.bytes(item.size)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.leading, 44).padding(.trailing, 20).padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0)
    }
}
