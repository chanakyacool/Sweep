import SwiftUI

// MARK: - Startup items

struct StartupView: View {
    @ObservedObject var model: StartupModel
    @State private var pendingRemoval: StartupItem?
    @Environment(\.sectionStyle) private var style

    var body: some View {
        Page(title: "Startup Items", subtitle: "Background helpers that launch automatically. Disable the ones you do not need.") {
            Button("Login Items Settings") { Finder.openSettings("com.apple.LoginItems-Settings.extension") }
            Button("Refresh") { model.load() }
        } content: {
            VStack(spacing: 0) {
                if let message = model.message { NoticeBanner(icon: "info.circle", text: message, tint: Theme.info) }
                if model.items.isEmpty {
                    if model.loading { ProgressView().frame(maxHeight: .infinity) }
                    else { EmptyState(icon: "bolt.slash", title: "No startup items", message: "No launch agents or daemons are installed.") { EmptyView() } }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            section(.userAgent)
                            section(.globalAgent)
                            section(.daemon)
                        }
                        .padding(24)
                    }
                }
            }
        }
        .onAppear { model.load() }
        .alert("Remove \(pendingRemoval?.label ?? "")?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Move to Trash", role: .destructive) { if let item = pendingRemoval { model.remove(item) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The launch agent is unloaded and its property list is moved to the Trash.")
        }
    }

    @ViewBuilder private func section(_ scope: StartupItem.Scope) -> some View {
        let items = model.items.filter { $0.scope == scope }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(scope.rawValue.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.45))
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                        if item.id != items.last?.id { Divider() }
                    }
                }
                .card(padding: 0)
            }
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(item.disabled ? Color.white.opacity(0.2) : item.running ? Theme.positive : style.accent.start)
                .frame(width: 8, height: 8)
                .shadow(color: item.disabled ? .clear : (item.running ? Theme.positive : style.accent.start).opacity(0.8), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).lineLimit(1).truncationMode(.middle)
                Text(item.program.isEmpty ? Fmt.tilde(item.path) : Fmt.tilde(item.program))
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(item.disabled ? "Disabled" : item.running ? "Running" : scope(item) ? "Enabled" : "Loaded on demand")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
            Toggle("", isOn: Binding(get: { !item.disabled }, set: { model.setEnabled($0, item) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(style.accent.start)
            Menu {
                Button("Reveal in Finder") { Finder.reveal([item.path]) }
                if item.scope == .userAgent {
                    Divider()
                    Button("Remove…") { pendingRemoval = item }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func scope(_ item: StartupItem) -> Bool { item.scope == .daemon || item.runsAtLoad }
}

// MARK: - Processes

struct ProcessesView: View {
    @ObservedObject var model: ProcessModel
    @Environment(\.sectionStyle) private var style

    var body: some View {
        Page(title: "Processes", subtitle: model.showingTrends
             ? "Which applications are consistently heavy, averaged over time."
             : "What is using memory and processor time right now.") {
            Picker("", selection: $model.showingTrends) {
                Text("Live").tag(false)
                Text("Trends").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if model.showingTrends {
                Picker("", selection: $model.trendHours) {
                    Text("Last 24 hours").tag(24)
                    Text("Last 7 days").tag(168)
                }
                .labelsHidden().fixedSize()
            } else {
                HStack(spacing: 7) {
                    CheckMark(isOn: model.onlyMine) { model.onlyMine = $0 }
                    Text("My processes only").font(.callout)
                }
                Button("Quit") { model.terminateSelected(force: false) }.disabled(model.selection.isEmpty)
                Button("Force Quit") { model.terminateSelected(force: true) }.disabled(model.selection.isEmpty)
            }
        } content: {
            if model.showingTrends { trends } else { live }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.showingTrends) { _, showing in if showing { model.loadTrends() } }
    }

    private var trends: some View {
        let heaviest = max(model.trends.map(\.averageMemory).max() ?? 1, 1)
        return ScrollView {
            LazyVStack(spacing: 0) {
                if model.trends.isEmpty {
                    Text("Sweep samples running applications once a minute while it is open. Trends appear here after a few minutes.")
                        .font(.callout).foregroundStyle(.white.opacity(0.5)).padding(24)
                }
                ForEach(model.trends) { trend in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(trend.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                            UsageBar(fraction: Double(trend.averageMemory) / Double(heaviest), accent: style.accent, height: 5)
                        }
                        Spacer(minLength: 12)
                        Metric(label: "Avg memory", value: Fmt.memory(UInt64(trend.averageMemory))).frame(width: 96, alignment: .leading)
                        Metric(label: "Peak", value: Fmt.memory(UInt64(trend.peakMemory))).frame(width: 96, alignment: .leading)
                        Metric(label: "Avg CPU", value: String(format: "%.1f%%", trend.averageCPU)).frame(width: 76, alignment: .leading)
                        Metric(label: "Samples", value: trend.samples.formatted()).frame(width: 70, alignment: .leading)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    Hairline()
                }
            }
        }
    }

    private var live: some View {
            VStack(spacing: 0) {
                if let message = model.message { NoticeBanner(icon: "exclamationmark.triangle.fill", text: message) }
                HStack {
                    SearchField(prompt: "Filter by name", text: $model.search).frame(maxWidth: 260)
                    Spacer()
                    Text("\(model.visible.count) processes · \(Fmt.memory(UInt64(model.visible.reduce(0) { $0 + $1.memory })))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                Table(model.visible, selection: $model.selection, sortOrder: $model.sortOrder) {
                    TableColumn("Name", value: \.name) { row in
                        Text(row.name).lineLimit(1).truncationMode(.middle).help(row.executable)
                    }
                    TableColumn("Memory", value: \.memory) { row in
                        Text(Fmt.memory(UInt64(row.memory))).monospacedDigit()
                    }
                    .width(100)
                    TableColumn("CPU", value: \.cpu) { row in
                        Text(String(format: "%.1f%%", row.cpu)).monospacedDigit()
                            .foregroundStyle(row.cpu >= 80 ? Theme.critical : .primary)
                    }
                    .width(80)
                    TableColumn("PID", value: \.pid) { row in
                        Text(String(row.pid)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                    }
                    .width(70)
                    TableColumn("User", value: \.user) { row in
                        Text(row.user).foregroundStyle(.white.opacity(0.5))
                    }
                    .width(110)
                }
                .scrollContentBackground(.hidden)
            }
    }
}

// MARK: - Maintenance

struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel
    @Environment(\.sectionStyle) private var style

    var body: some View {
        Page(title: "Maintenance", subtitle: "Routine upkeep tasks. Each one runs a standard macOS command — nothing is installed.") {
            EmptyView()
        } content: {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(MaintenanceCatalog.tasks) { task in
                        row(task)
                    }
                }
                .padding(24)
            }
        }
    }

    private func row(_ task: MaintenanceTask) -> some View {
        let result = model.results[task.id]
        let isRunning = model.running.contains(task.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: task.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(style.accent.gradient)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                        if task.needsAdmin {
                            Text("Admin").font(.caption2.weight(.medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.track, in: Capsule()).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Text(task.detail).font(.callout).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 12)
                if isRunning {
                    ProgressView().controlSize(.small)
                } else if let result {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? Theme.positive : Theme.critical)
                }
                Button("Run") { model.run(task) }.disabled(isRunning)
            }
            if let result, !isRunning {
                Text(result.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.5))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.track, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .card(padding: 16)
        .help(task.command)
    }
}
