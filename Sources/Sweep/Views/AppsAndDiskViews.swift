import SwiftUI

// MARK: - Uninstaller

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @State private var confirmingUninstall = false
    @State private var confirmingReset = false
    @Environment(\.sectionStyle) private var style

    var body: some View {
        Page(title: "Uninstaller", subtitle: "Remove applications together with the support files they leave behind.") {
            Picker("Sort", selection: $model.sort) {
                ForEach(AppSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
        } content: {
            VStack(spacing: 0) {
                if let outcome = model.lastOutcome { OutcomeBanner(outcome: outcome) }
                HStack(spacing: 0) {
                    appList.frame(width: 320)
                    Divider()
                    detail
                }
            }
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
        .alert("Uninstall \(model.selectedApp?.name ?? "")?", isPresented: $confirmingUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.remove(keepApp: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The application and \(model.leftovers.filter(\.selected).count) selected support item(s) will be \(Prefs.permanentDelete ? "permanently deleted" : "moved to the Trash"). If it is running, it will be quit first.")
        }
        .alert("Reset \(model.selectedApp?.name ?? "")?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { Task { await model.remove(keepApp: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected support files are removed but the application stays installed. It will start as if newly installed, without its settings or saved data.")
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "Search applications", text: $model.search).padding(12)
            Divider()
            if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleApps, selection: $model.selectedID) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: Finder.icon(app.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).lineLimit(1)
                            Text(app.lastUsed.map { "Used \(Fmt.ago($0))" } ?? "Never opened")
                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer(minLength: 6)
                        if app.size > 0 { SizeLabel(bytes: app.size) } else { ProgressView().controlSize(.mini) }
                    }
                    .padding(.vertical, 2)
                    .tag(app.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.black.opacity(0.18))
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selectedApp {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(nsImage: Finder.icon(app.path)).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(Theme.display(20))
                        Text([app.version.isEmpty ? nil : "Version \(app.version)", app.bundleID.isEmpty ? nil : app.bundleID]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.white.opacity(0.5)).textSelection(.enabled)
                        Text(Fmt.tilde(app.path)).font(.caption).foregroundStyle(.white.opacity(0.3))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Total").font(.caption).foregroundStyle(.white.opacity(0.5))
                        Text(Fmt.bytes(app.size + model.selectedLeftoverSize)).font(Theme.display(22).monospacedDigit())
                            .foregroundStyle(style.accent.gradient)
                    }
                }
                .padding(16)
                Divider()
                HStack {
                    Text("Support files").font(.headline)
                    Spacer()
                    if model.leftoversLoading { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        CheckRow(isOn: true, toggle: { _ in }, title: (app.path as NSString).lastPathComponent,
                                 subtitle: "Application", icon: Finder.icon(app.path)) { SizeLabel(bytes: app.size) }
                            .disabled(true)
                        ForEach(model.leftovers) { item in
                            CheckRow(isOn: item.selected, toggle: { model.setLeftover(item.id, selected: $0) },
                                     title: (item.path as NSString).lastPathComponent,
                                     subtitle: Fmt.tilde((item.path as NSString).deletingLastPathComponent)
                                        + (item.isSystemLevel ? " · needs administrator approval" : "")) {
                                SizeLabel(bytes: item.size)
                            }
                            .contextMenu { Button("Reveal in Finder") { Finder.reveal([item.path]) } }
                        }
                        if !model.leftoversLoading && model.leftovers.isEmpty {
                            Text("No support files found for this application.")
                                .font(.callout).foregroundStyle(.white.opacity(0.5)).padding(20)
                        }
                    }
                    .padding(8)
                }
                Divider()
                HStack {
                    Button("Reveal in Finder") { Finder.reveal([app.path]) }
                    Spacer()
                    if model.working { ProgressView().controlSize(.small) }
                    Button("Reset App Data…") { confirmingReset = true }
                        .disabled(model.working || model.leftovers.allSatisfy { !$0.selected })
                    Button("Uninstall…") { confirmingUninstall = true }
                        .buttonStyle(.primary).disabled(model.working)
                }
                .padding(12)
            }
        } else {
            EmptyState(icon: "square.grid.2x2", title: "Select an application",
                       message: "Sweep shows everything that belongs to it — preferences, caches, containers and launch agents — before anything is removed.") { EmptyView() }
        }
    }
}

// MARK: - Space Lens

struct SpaceLensView: View {
    @ObservedObject var model: SpaceLensModel
    @State private var pendingRemoval: DiskNode?
    @Environment(\.sectionStyle) private var style

    var body: some View {
        Page(title: "Space Lens", subtitle: "A map of what is using your disk. Click a folder to look inside.") {
            if model.state == .ready {
                Button("Choose Another Folder") { model.reset() }
            }
        } content: {
            switch model.state {
            case .idle, .cleaning:
                EmptyState(icon: "square.split.2x2", title: "Map your storage",
                           message: "Pick a location to measure. Large folders can take a minute the first time.") {
                    HStack(spacing: 10) {
                        Button("Home Folder") { model.scan(FS.home) }.buttonStyle(.primary)
                        Button("Applications") { model.scan("/Applications") }
                        Button("Entire Disk") { model.scan("/System/Volumes/Data") }
                        Button("Choose…") { if let path = Finder.chooseFolders(multiple: false).first { model.scan(path) } }
                    }
                    .controlSize(.large)
                }
            case .scanning:
                ScanningState(title: "Measuring…", progress: model.progress, cancel: model.cancel)
            case .ready:
                if let node = model.current { map(node) }
            }
        }
        .alert("Remove “\(pendingRemoval?.name ?? "")”?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button(Prefs.permanentDelete ? "Delete" : "Move to Trash", role: .destructive) {
                if let node = pendingRemoval { Task { await model.remove(node) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Fmt.bytes(pendingRemoval?.size ?? 0)) at \(Fmt.tilde(pendingRemoval?.path ?? ""))")
        }
    }

    private func map(_ node: DiskNode) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(node.ancestors) { ancestor in
                    if ancestor !== node.ancestors.first { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.white.opacity(0.3)) }
                    Button(ancestor.name) { model.current = ancestor }
                        .buttonStyle(.plain)
                        .foregroundStyle(ancestor === node ? .primary : .secondary)
                        .fontWeight(ancestor === node ? .semibold : .regular)
                }
                Spacer()
                Text(Fmt.bytes(node.size)).font(Theme.display(18).monospacedDigit()).foregroundStyle(style.accent.gradient)
            }
            .lineLimit(1)
            .padding(.horizontal, 22).padding(.vertical, 12)
            if let message = model.message {
                NoticeBanner(icon: "info.circle", text: message, tint: Theme.info)
            }
            Divider()
            HStack(spacing: 0) {
                List(node.children) { child in
                    row(child, in: node)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if child.isDirectory { model.current = child } }
                        .contextMenu {
                            if child.isDirectory { Button("Look Inside") { model.current = child } }
                            Button("Reveal in Finder") { Finder.reveal([child.path]) }
                            if !child.isAggregate {
                                Divider()
                                Button(Prefs.permanentDelete ? "Delete…" : "Move to Trash…") { pendingRemoval = child }
                            }
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(width: 380)
                .background(Color.black.opacity(0.18))
                Divider()
                Treemap(node: node) { model.current = $0 }
                    .padding(12)
            }
        }
    }

    private func row(_ child: DiskNode, in parent: DiskNode) -> some View {
        let fraction = parent.size > 0 ? Double(child.size) / Double(parent.size) : 0
        return HStack(spacing: 10) {
            Image(systemName: child.isAggregate ? "doc.on.doc" : child.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(child.isDirectory ? AnyShapeStyle(style.accent.gradient) : AnyShapeStyle(Color.white.opacity(0.45)))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(child.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Fmt.bytes(child.size)).font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                }
                UsageBar(fraction: fraction, accent: style.accent, height: 4)
            }
            if child.isDirectory {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.vertical, 3)
    }
}

/// A squarified treemap of a folder's children; area is proportional to size on disk.
struct Treemap: View {
    let node: DiskNode
    let open: (DiskNode) -> Void
    @State private var hovered: ObjectIdentifier?

    var body: some View {
        GeometryReader { geometry in
            let tiles = layout(in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles, id: \.node.id) { tile in
                    let isHovered = hovered == tile.node.id
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [tile.color, tile.color.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(isHovered ? 0.7 : 0.14), lineWidth: 1))
                        .brightness(isHovered ? 0.08 : 0)
                        .overlay(alignment: .topLeading) {
                            if tile.rect.width > 70, tile.rect.height > 34 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tile.node.name).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(Fmt.bytes(tile.node.size)).font(.caption2.monospacedDigit()).opacity(0.85)
                                }
                                .foregroundStyle(.white)
                                .padding(6)
                            }
                        }
                        .frame(width: max(0, tile.rect.width - 4), height: max(0, tile.rect.height - 4))
                        .offset(x: tile.rect.minX + 2, y: tile.rect.minY + 2)
                        .onHover { inside in hovered = inside ? tile.node.id : (hovered == tile.node.id ? nil : hovered) }
                        .onTapGesture { if tile.node.isDirectory { open(tile.node) } }
                        .help("\(tile.node.name) — \(Fmt.bytes(tile.node.size))")
                }
            }
        }
    }

    private struct Tile {
        let node: DiskNode
        let rect: CGRect
        let color: Color
    }

    private func layout(in bounds: CGRect) -> [Tile] {
        let visible = Array(node.children.prefix(80)).filter { $0.size > 0 }
        let total = visible.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0, bounds.width > 4, bounds.height > 4 else { return [] }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = visible.map { Double($0.size) * scale }

        var rects = [CGRect](repeating: .zero, count: areas.count)
        var remaining = bounds
        var row: [Int] = []

        func worstRatio(_ indices: [Int], side: Double) -> Double {
            let sum = indices.reduce(0.0) { $0 + areas[$1] }
            guard sum > 0, side > 0 else { return .infinity }
            let largest = indices.map { areas[$0] }.max() ?? 0
            let smallest = indices.map { areas[$0] }.min() ?? 0
            return max(side * side * largest / (sum * sum), sum * sum / (side * side * max(smallest, 1e-9)))
        }

        func place(_ indices: [Int]) {
            let sum = indices.reduce(0.0) { $0 + areas[$1] }
            if remaining.width >= remaining.height {
                let width = CGFloat(sum) / max(remaining.height, 0.001)
                var y = remaining.minY
                for index in indices {
                    let height = CGFloat(areas[index]) / max(width, 0.001)
                    rects[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = CGFloat(sum) / max(remaining.width, 0.001)
                var x = remaining.minX
                for index in indices {
                    let width = CGFloat(areas[index]) / max(height, 0.001)
                    rects[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
        }

        var next = 0
        while next < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worstRatio(row + [next], side: side) <= worstRatio(row, side: side) {
                row.append(next)
                next += 1
            } else {
                place(row)
                row = []
            }
        }
        if !row.isEmpty { place(row) }

        return visible.enumerated().map { index, child in
            let base = child.isAggregate ? Color(white: 0.38) : Theme.palette[index % Theme.palette.count]
            return Tile(node: child, rect: rects[index], color: base)
        }
    }
}
