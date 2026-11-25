import SwiftUI

// MARK: - Similar photos

struct SimilarPhotosView: View {
    @ObservedObject var model: SimilarPhotosModel
    @State private var confirming = false

    var body: some View {
        Page(title: "Similar Photos", subtitle: "Pictures that look alike: resized or re-saved copies, edits and burst shots.") {
            if model.state == .ready || model.state == .cleaning {
                Button("New Scan") { model.reset() }
                Button("Auto Select") { model.autoSelect() }.help("Selects everything except the highest-resolution copy in each group")
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
                    ScanningState(title: "Looking at your pictures…", progress: model.progress, cancel: model.cancel)
                case .ready, .cleaning:
                    if model.groups.isEmpty {
                        EmptyState(icon: "checkmark.seal.fill", title: "No look-alikes found",
                                   message: "None of the pictures in the scanned folders resemble each other closely.") {
                            Button("Choose Other Folders") { model.reset() }
                        }
                    } else {
                        results
                    }
                }
            }
        }
        .removalConfirmation(isPresented: $confirming, size: model.selectedSize, count: model.selection.count,
                             extra: model.fullySelectedGroups > 0
                                ? "Warning: in \(model.fullySelectedGroups) group\(model.fullySelectedGroups == 1 ? "" : "s") every picture is selected, so none will remain."
                                : "") {
            Task { await model.removeSelected() }
        }
    }

    private var setup: some View {
        EmptyState(icon: "photo.on.rectangle.angled", title: "Find similar photos",
                   message: "Sweep compares what pictures look like, not their names or exact bytes. Your Photos library is not touched, and nothing is selected for you.") {
            VStack(spacing: 12) {
                FolderList(folders: $model.roots)
                Button("Scan for Similar Photos") { model.scan() }
                    .buttonStyle(.primary).controlSize(.large).disabled(model.roots.isEmpty)
            }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.groups.count) groups").font(.callout).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(Fmt.bytes(model.reclaimable)) could be reclaimed").font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("\(group.files.count) similar pictures").font(.system(size: 13, weight: .semibold, design: .rounded))
                                Spacer()
                                SizeLabel(bytes: group.reclaimable)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                                        PhotoTile(file: file, isBest: index == 0, selected: model.selection.contains(file.id)) {
                                            model.toggle(file.id)
                                        }
                                    }
                                }
                            }
                        }
                        .card(padding: 16)
                    }
                }
                .padding(22)
            }
        }
        .disabled(model.state == .cleaning)
    }
}

private struct PhotoTile: View {
    let file: ImageHit
    let isBest: Bool
    let selected: Bool
    let toggle: () -> Void
    @State private var image: NSImage?
    @Environment(\.sectionStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05))
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 168, height: 126).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack {
                    CheckMark(isOn: selected) { _ in toggle() }
                    Spacer()
                    if isBest {
                        Text("BEST").font(.system(size: 9, weight: .heavy)).tracking(0.6)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.positive, in: Capsule()).foregroundStyle(.black.opacity(0.8))
                    }
                }
                .padding(7)
            }
            .frame(width: 168, height: 126)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(style.accent.gradient) : AnyShapeStyle(Color.white.opacity(0.1)), lineWidth: selected ? 2 : 1))
            .onTapGesture(perform: toggle)
            Text((file.path as NSString).lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Text("\(file.width)×\(file.height) · \(Fmt.bytes(file.size))").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.45))
        }
        .frame(width: 168)
        .contextMenu {
            Button("Reveal in Finder") { Finder.reveal([file.path]) }
            Button("Open") { Finder.open(file.path) }
        }
        .help(Fmt.tilde(file.path))
        .task(id: file.path) {
            let path = file.path
            image = await Task.detached(priority: .utility) { SimilarImageScanner.thumbnail(path) }.value
        }
    }
}

/// An editable list of folders to scan.
struct FolderList: View {
    @Binding var folders: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(folders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.white.opacity(0.45))
                    Text(Fmt.tilde(folder))
                    Spacer()
                    Button { folders.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.vertical, 8).padding(.horizontal, 14)
                Hairline()
            }
            Button("Add Folder…") {
                for path in Finder.chooseFolders() where !folders.contains(path) { folders.append(path) }
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).padding(12)
        }
        .frame(width: 420)
        .card(padding: 0)
    }
}

// MARK: - Containers & simulators

struct ContainersView: View {
    @ObservedObject var model: ContainersModel
    @State private var confirming = false

    var body: some View {
        Page(title: "Containers", subtitle: "Docker images, containers, volumes and build cache, plus Xcode simulator devices.") {
            if model.state == .ready || model.state == .cleaning {
                Button("Rescan") { model.scan() }
                Button(action: { confirming = true }) {
                    Text(model.selected.isEmpty ? "Remove" : "Remove \(Fmt.bytes(model.selectedSize))").frame(minWidth: 96)
                }
                .buttonStyle(.primary)
                .disabled(model.selected.isEmpty || model.state == .cleaning)
            }
        } content: {
            VStack(spacing: 0) {
                if let outcome = model.lastOutcome { OutcomeBanner(outcome: outcome) }
                switch model.state {
                case .idle:
                    EmptyState(icon: "shippingbox.fill", title: "Docker and simulators",
                               message: "See each unused image, stopped container, volume and simulator device with its size, and remove exactly the ones you choose.") {
                        Button("Scan") { model.scan() }.buttonStyle(.primary).controlSize(.large)
                    }
                case .scanning:
                    ScanningState(title: "Asking Docker and Xcode…", progress: "This can take a few seconds", cancel: {})
                case .ready, .cleaning:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(model.notes, id: \.self) { note in
                                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.white.opacity(0.6))
                            }
                            ForEach(model.groups) { group in
                                ToolGroupCard(group: group) { model.setSelected($1, item: $0) }
                            }
                        }
                        .padding(26)
                    }
                    .disabled(model.state == .cleaning)
                    .overlay {
                        if model.state == .cleaning {
                            ProgressView("Removing…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
        .alert("Remove \(model.selected.count) item\(model.selected.count == 1 ? "" : "s")?", isPresented: $confirming) {
            Button("Remove", role: .destructive) { Task { await model.removeSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Docker and simulator items are deleted directly and cannot be put back from the Trash.")
        }
    }
}

private struct ToolGroupCard: View {
    let group: ToolGroup
    let setSelected: (String, Bool) -> Void
    @Environment(\.sectionStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: group.icon).font(.system(size: 15, weight: .medium)).foregroundStyle(style.accent.gradient)
                    .frame(width: 36, height: 36).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(group.detail).font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                SizeLabel(bytes: group.size)
            }
            .padding(16)
            Hairline()
            VStack(spacing: 0) {
                ForEach(group.items) { item in
                    CheckRow(isOn: item.selected, toggle: { setSelected(item.id, $0) }, title: item.title, subtitle: item.detail) {
                        SizeLabel(bytes: item.size)
                    }
                }
            }
            .padding(6)
        }
        .card(padding: 0)
    }
}

// MARK: - Updater

struct UpdaterView: View {
    @ObservedObject var model: UpdaterModel
    @Environment(\.sectionStyle) private var style

    var body: some View {
        Page(title: "Updater", subtitle: "Outdated Homebrew packages and apps, and App Store apps when the mas tool is installed.") {
            if model.phase == .ready || model.phase == .updating {
                Button("App Store") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }
                Button("Check Again") { model.check() }.disabled(model.phase == .updating)
                Button(action: model.updateSelected) {
                    Text(model.selected.isEmpty ? "Update" : "Update \(model.selected.count)").frame(minWidth: 90)
                }
                .buttonStyle(.primary)
                .disabled(model.selected.isEmpty || model.phase == .updating)
            }
        } content: {
            switch model.phase {
            case .idle:
                EmptyState(icon: "arrow.down.circle.fill", title: "Keep your software current",
                           message: "Sweep asks Homebrew what is out of date and upgrades the items you pick. Checking contacts Homebrew's servers.") {
                    HStack(spacing: 10) {
                        Button("Check for Updates") { model.check() }.buttonStyle(.primary).controlSize(.large)
                        Button("Open App Store Updates") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }.controlSize(.large)
                    }
                }
            case .checking:
                ScanningState(title: "Checking for updates…", progress: "Refreshing Homebrew's package list", cancel: {})
            case .ready, .updating:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.phase == .updating {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Updating… large apps can take several minutes.").font(.callout)
                            }
                        }
                        ForEach(model.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.white.opacity(0.6))
                        }
                        if model.items.isEmpty {
                            Label("Everything Sweep can check is up to date.", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.positive)
                                .frame(maxWidth: .infinity, alignment: .leading).card(padding: 20)
                        }
                        ForEach([UpdateItem.Kind.cask, .formula, .appStore], id: \.rawValue) { kind in
                            let items = model.items.filter { $0.kind == kind }
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(kind.rawValue.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
                                        .foregroundStyle(.white.opacity(0.45)).padding(16)
                                    Hairline()
                                    VStack(spacing: 0) {
                                        ForEach(items) { item in
                                            CheckRow(isOn: item.selected, toggle: { model.setSelected($0, item: item.id) },
                                                     title: item.name, subtitle: "Installed \(item.installed)") {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.white.opacity(0.4))
                                                    Text(item.latest).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                                                        .foregroundStyle(style.accent.gradient)
                                                }
                                            }
                                        }
                                    }
                                    .padding(6)
                                }
                                .card(padding: 0)
                            }
                        }
                        if let log = model.log, !log.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(model.lastSucceeded == true ? "Update finished" : "Update finished with errors",
                                      systemImage: model.lastSucceeded == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(model.lastSucceeded == true ? Theme.positive : Theme.caution)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                Text(log).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6)).textSelection(.enabled).lineLimit(40)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card(padding: 16)
                        }
                    }
                    .padding(26)
                }
                .disabled(model.phase == .updating)
            }
        }
    }
}
