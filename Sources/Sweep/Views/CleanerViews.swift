import SwiftUI

/// The shared two-pane checklist used by System Junk, Developer and Privacy.
struct CategoryCleanerView: View {
    @ObservedObject var model: CategoryModel
    let title: String
    let subtitle: String
    let icon: String
    let intro: String
    var showsAgeSelection = false

    @State private var selectedCategory: String?
    @State private var confirming = false
    @State private var hasFullDiskAccess = Permissions.hasFullDiskAccess
    @Environment(\.sectionStyle) private var style

    var body: some View {
        Page(title: title, subtitle: subtitle) {
            if model.hasScanned {
                Button("Rescan") { model.scan() }.disabled(model.state == .cleaning)
                Button(action: { confirming = true }) {
                    Text(model.selectedCount == 0 ? "Clean" : "Clean \(Fmt.bytes(model.selectedSize))")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.primary)
                .disabled(model.selectedCount == 0 || model.state == .cleaning)
            }
        } content: {
            VStack(spacing: 0) {
                if !hasFullDiskAccess {
                    NoticeBanner(icon: "lock.shield",
                                 text: "Grant Full Disk Access so Sweep can see the Trash, Mail and Safari data.",
                                 tint: Theme.info, actionTitle: "Open Settings", action: Finder.openFullDiskAccessSettings)
                }
                if let outcome = model.lastOutcome { OutcomeBanner(outcome: outcome) }
                switch model.state {
                case .idle:
                    EmptyState(icon: icon, title: title, message: intro) {
                        Button("Scan") { model.scan() }.buttonStyle(.primary).controlSize(.large)
                    }
                case .scanning:
                    ScanningState(title: "Scanning…", progress: model.progress, cancel: model.cancel)
                case .ready, .cleaning:
                    if model.categories.isEmpty {
                        EmptyState(icon: "checkmark.seal", title: "Nothing to clean",
                                   message: "Sweep found nothing removable here.") {
                            Button("Scan Again") { model.scan() }
                        }
                    } else {
                        results
                    }
                }
            }
        }
        .removalConfirmation(isPresented: $confirming, size: model.selectedSize, count: model.selectedCount) {
            Task { await model.clean() }
        }
        .onAppear { hasFullDiskAccess = Permissions.hasFullDiskAccess }
    }

    private var activeCategory: CleanCategory? {
        model.categories.first { $0.id == selectedCategory } ?? model.categories.first
    }

    private var results: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.categories) { category in
                            categoryRow(category)
                        }
                    }
                    .padding(12)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FOUND").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.42))
                        Text(Fmt.bytes(model.totalSize)).font(Theme.display(22).monospacedDigit())
                            .foregroundStyle(style.accent.gradient)
                    }
                    Spacer()
                    Menu("Select") {
                        Button("All") { model.setAllSelected(true) }
                        Button("None") { model.setAllSelected(false) }
                        if showsAgeSelection {
                            Divider()
                            Button("Projects untouched for 30 days") { model.selectOlder(thanDays: 30) }
                            Button("Projects untouched for 90 days") { model.selectOlder(thanDays: 90) }
                            Button("Projects untouched for 1 year") { model.selectOlder(thanDays: 365) }
                        }
                    }
                    .fixedSize()
                }
                .padding(16)
            }
            .frame(width: 320)
            .background(Color.black.opacity(0.18))

            Divider()

            if let category = activeCategory {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.title).font(Theme.display(17, .semibold))
                        Text(category.detail).font(.callout).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    if let warning = category.warning {
                        NoticeBanner(icon: "exclamationmark.triangle.fill", text: warning)
                    }
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(category.items) { item in
                                CheckRow(isOn: item.selected,
                                         toggle: { model.setSelected($0, item: item.id, in: category.id) },
                                         title: item.name, subtitle: item.detail) {
                                    SizeLabel(bytes: item.size)
                                }
                                .contextMenu {
                                    Button("Reveal in Finder") { Finder.reveal([item.path]) }
                                    Button("Copy Path") { copy(item.path) }
                                    Button("Always Ignore This Item") { Prefs.exclusions.append(item.path); model.scan() }
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
        }
        .disabled(model.state == .cleaning)
        .overlay {
            if model.state == .cleaning {
                ProgressView("Cleaning…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func categoryRow(_ category: CleanCategory) -> some View {
        let isActive = category.id == activeCategory?.id
        let allSelected = category.selectedCount == category.items.count
        return HStack(spacing: 11) {
            CheckMark(isOn: allSelected, isMixed: category.selectedCount > 0 && !allSelected) { _ in
                model.setSelected(!allSelected, category: category.id)
            }
            Image(systemName: category.icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22)
                .foregroundStyle(isActive ? AnyShapeStyle(style.accent.gradient) : AnyShapeStyle(Color.white.opacity(0.5)))
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).lineLimit(1)
                Text(category.selectedCount == 0 ? "\(category.items.count) items"
                     : "\(category.selectedCount) of \(category.items.count) selected")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            SizeLabel(bytes: category.size)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(isActive ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isActive ? AnyShapeStyle(style.accent.gradient.opacity(0.7)) : AnyShapeStyle(Color.clear), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { selectedCategory = category.id }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Large & old files

struct LargeFilesView: View {
    @ObservedObject var model: LargeFilesModel
    @State private var confirming = false

    var body: some View {
        Page(title: "Large & Old Files", subtitle: "Big files in your home folder, so you can decide what is still worth keeping.") {
            if model.state == .ready || model.state == .cleaning {
                Button("Rescan") { model.scan() }
                Button(action: { confirming = true }) {
                    Text(model.selection.isEmpty ? "Remove" : "Remove \(Fmt.bytes(model.selectedSize))").frame(minWidth: 96)
                }
                .buttonStyle(.primary)
                .disabled(model.selection.isEmpty || model.state == .cleaning)
            }
        } content: {
            VStack(spacing: 0) {
                if let outcome = model.lastOutcome { OutcomeBanner(outcome: outcome) }
                switch model.state {
                case .idle:
                    EmptyState(icon: "doc.badge.clock", title: "Find large files",
                               message: "Sweep lists files of \(Fmt.bytes(Prefs.largeMinBytes)) or more. App data, packages and cloud-only files are left out. Nothing is selected for you.") {
                        Button("Scan") { model.scan() }.buttonStyle(.primary).controlSize(.large)
                    }
                case .scanning:
                    ScanningState(title: "Looking for large files…", progress: model.progress, cancel: model.cancel)
                case .ready, .cleaning:
                    filters
                    Divider()
                    table
                }
            }
        }
        .removalConfirmation(isPresented: $confirming, size: model.selectedSize, count: model.selection.count) {
            Task { await model.removeSelected() }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: $model.kindFilter) {
                Text("All kinds").tag("All")
                ForEach(FileKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .labelsHidden().fixedSize()
            Picker("Age", selection: $model.ageFilter) {
                ForEach(AgeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            SearchField(prompt: "Filter by name or folder", text: $model.search).frame(maxWidth: 260)
            Spacer()
            Text("\(model.filtered.count) files · \(Fmt.bytes(model.filtered.reduce(0) { $0 + $1.size }))")
                .font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var table: some View {
        Table(model.filtered, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { hit in
                HStack(spacing: 8) {
                    Image(nsImage: Finder.icon(hit.path)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(hit.name).lineLimit(1).truncationMode(.middle)
                        Text(hit.folder).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            TableColumn("Size", value: \.size) { hit in
                Text(Fmt.bytes(hit.size)).monospacedDigit()
            }
            .width(90)
            TableColumn("Modified", value: \.modified) { hit in
                Text(Fmt.date(hit.modified)).foregroundStyle(.white.opacity(0.5))
            }
            .width(110)
            TableColumn("Kind", value: \.kindName) { hit in
                Text(hit.kindName).foregroundStyle(.white.opacity(0.5))
            }
            .width(90)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Reveal in Finder") { Finder.reveal(Array(ids)) }
            Button("Open") { ids.forEach(Finder.open) }
        } primaryAction: { ids in
            Finder.reveal(Array(ids))
        }
        .disabled(model.state == .cleaning)
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel
    @State private var confirming = false

    var body: some View {
        Page(title: "Duplicates", subtitle: "Byte-for-byte identical files that are stored more than once.") {
            if model.state == .ready || model.state == .cleaning {
                Button("New Scan") { model.reset() }
                Button("Auto Select") { model.autoSelect() }
                    .help("Selects every copy except the oldest in each group")
                Button(action: { confirming = true }) {
                    Text(model.selection.isEmpty ? "Remove" : "Remove \(Fmt.bytes(model.selectedSize))").frame(minWidth: 96)
                }
                .buttonStyle(.primary)
                .disabled(model.selection.isEmpty || model.state == .cleaning)
            }
        } content: {
            VStack(spacing: 0) {
                if let outcome = model.lastOutcome { OutcomeBanner(outcome: outcome) }
                switch model.state {
                case .idle:
                    setup
                case .scanning:
                    ScanningState(title: "Comparing files…", progress: model.progress, cancel: model.cancel)
                case .ready, .cleaning:
                    if model.groups.isEmpty {
                        EmptyState(icon: "checkmark.seal", title: "No duplicates found",
                                   message: "Every file in the scanned folders is unique.") {
                            Button("Choose Other Folders") { model.reset() }
                        }
                    } else {
                        groups
                    }
                }
            }
        }
        .removalConfirmation(isPresented: $confirming, size: model.selectedSize, count: model.selection.count,
                             extra: model.fullySelectedGroups > 0
                                ? "Warning: in \(model.fullySelectedGroups) group\(model.fullySelectedGroups == 1 ? "" : "s") every copy is selected, so no copy will remain."
                                : "") {
            Task { await model.removeSelected() }
        }
    }

    private var setup: some View {
        VStack(spacing: 18) {
            EmptyState(icon: "doc.on.doc", title: "Find duplicate files",
                       message: "Files of \(Fmt.bytes(Prefs.duplicateMinBytes)) or more are compared by content, not by name. Nothing is selected for you.") {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.roots, id: \.self) { root in
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.white.opacity(0.5))
                                Text(Fmt.tilde(root))
                                Spacer()
                                Button { model.roots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 12)
                            Divider()
                        }
                        Button("Add Folder…") {
                            for path in Finder.chooseFolders() where !model.roots.contains(path) { model.roots.append(path) }
                        }
                        .buttonStyle(.borderless).padding(10)
                    }
                    .frame(width: 420)
                    .card(padding: 0)
                    Button("Scan for Duplicates") { model.scan() }
                        .buttonStyle(.primary).controlSize(.large)
                        .disabled(model.roots.isEmpty)
                }
            }
        }
    }

    private var groups: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.groups.count) groups").font(.callout).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(Fmt.bytes(model.wasted)) could be reclaimed").font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                if let first = group.files.first {
                                    Image(nsImage: Finder.icon(first.path)).resizable().frame(width: 20, height: 20)
                                }
                                Text(group.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(group.files.count) copies · \(Fmt.bytes(group.size)) each")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(Color.white.opacity(0.04))
                            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                                CheckRow(isOn: model.selection.contains(file.id),
                                         toggle: { on in if on { model.selection.insert(file.id) } else { model.selection.remove(file.id) } },
                                         title: Fmt.tilde(file.path),
                                         subtitle: "Modified \(Fmt.date(file.modified))" + (index == 0 ? " · oldest copy" : "")) {
                                    Button { Finder.reveal([file.path]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless).help("Reveal in Finder")
                                }
                            }
                        }
                        .card(padding: 0)
                    }
                }
                .padding(16)
            }
        }
        .disabled(model.state == .cleaning)
    }
}
