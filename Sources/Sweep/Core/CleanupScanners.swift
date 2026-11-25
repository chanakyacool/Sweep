import AppKit
import Foundation

// MARK: - Shared model

/// One removable file or folder found by a scanner.
struct CleanItem: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    var detail: String = ""
    var size: Int64 = 0
    var selected: Bool
    var date: Date? = nil
}

/// A group of related removable items, e.g. "User Caches".
struct CleanCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let icon: String
    let detail: String
    /// Items are deleted outright instead of being moved to the Trash (used for the Trash itself).
    var deletesPermanently = false
    var warning: String? = nil
    var items: [CleanItem] = []

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.reduce(0) { $0 + ($1.selected ? $1.size : 0) } }
    var selectedCount: Int { items.reduce(0) { $0 + ($1.selected ? 1 : 0) } }
}

typealias ProgressReport = @Sendable (String) -> Void

/// Builds categories from candidate paths, measuring each and dropping empty or excluded ones.
private struct CategoryBuilder {
    let report: ProgressReport
    let cancel: CancelFlag
    private(set) var categories: [CleanCategory] = []

    init(report: @escaping ProgressReport, cancel: CancelFlag) {
        self.report = report
        self.cancel = cancel
    }

    struct Candidate {
        let path: String
        var selected = true
        var name: String? = nil
        var detail: String? = nil
    }

    mutating func add(_ category: CleanCategory, _ candidates: [Candidate]) {
        guard !cancel.isCancelled else { return }
        report(category.title)
        var result = category
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.path).inserted {
            if cancel.isCancelled { return }
            guard FS.exists(candidate.path), !Prefs.isExcluded(candidate.path) else { continue }
            let size = FS.size(of: candidate.path, cancel: cancel)
            guard size > 0 else { continue }
            result.items.append(CleanItem(
                path: candidate.path,
                name: candidate.name ?? (candidate.path as NSString).lastPathComponent,
                detail: candidate.detail ?? Fmt.tilde((candidate.path as NSString).deletingLastPathComponent),
                size: size,
                selected: candidate.selected,
                date: FS.modified(candidate.path)))
        }
        result.items.sort { $0.size > $1.size }
        if !result.items.isEmpty { categories.append(result) }
    }
}

private typealias Candidate = CategoryBuilder.Candidate

private func childCandidates(_ directory: String, selected: (String) -> Bool = { _ in true }) -> [Candidate] {
    FS.children(of: directory).map { Candidate(path: $0, selected: selected(($0 as NSString).lastPathComponent)) }
}

// MARK: - System junk

enum JunkScanner {
    static func scan(report: @escaping ProgressReport, cancel: CancelFlag) -> [CleanCategory] {
        let home = FS.home
        let library = home + "/Library"
        var builder = CategoryBuilder(report: report, cancel: cancel)

        // Apple's own caches are listed but left unselected: they regenerate, yet clearing them buys little.
        builder.add(
            CleanCategory(id: "caches", title: "User Caches", icon: "internaldrive",
                          detail: "Temporary data apps keep to launch and load faster. Apps rebuild it as needed."),
            childCandidates(library + "/Caches") { !$0.hasPrefix("com.apple.") && $0 != "CloudKit" && $0 != "FamilyCircle" })

        builder.add(
            CleanCategory(id: "logs", title: "Logs & Reports", icon: "doc.text",
                          detail: "Diagnostic logs and crash reports written by apps and the system."),
            childCandidates(library + "/Logs"))

        builder.add(
            CleanCategory(id: "xcode", title: "Xcode", icon: "hammer",
                          detail: "Build products, device support files and simulator caches. Xcode recreates what it needs."),
            childCandidates(library + "/Developer/Xcode/DerivedData")
                + childCandidates(library + "/Developer/Xcode/iOS DeviceSupport")
                + childCandidates(library + "/Developer/Xcode/watchOS DeviceSupport")
                + [Candidate(path: library + "/Developer/CoreSimulator/Caches")]
                + childCandidates(library + "/Developer/Xcode/Archives") { _ in false })

        builder.add(
            CleanCategory(id: "packages", title: "Package Caches", icon: "shippingbox",
                          detail: "Downloaded packages cached by npm, Yarn, pnpm, Gradle, Cargo, Go, CocoaPods and others."),
            [
                Candidate(path: home + "/.npm/_cacache", name: "npm cache"),
                Candidate(path: home + "/.npm/_npx", name: "npx cache"),
                Candidate(path: home + "/.yarn/cache", name: "Yarn cache"),
                Candidate(path: library + "/pnpm/store", name: "pnpm store"),
                Candidate(path: home + "/.bun/install/cache", name: "Bun cache"),
                Candidate(path: home + "/.gradle/caches", name: "Gradle caches"),
                Candidate(path: home + "/.cargo/registry/cache", name: "Cargo registry cache"),
                Candidate(path: home + "/.cocoapods/repos", name: "CocoaPods specs"),
                Candidate(path: home + "/.pub-cache", selected: false, name: "Dart pub cache"),
                Candidate(path: home + "/.m2/repository", selected: false, name: "Maven repository"),
                Candidate(path: home + "/go/pkg/mod", selected: false, name: "Go module cache"),
                Candidate(path: home + "/.terraform.d/plugin-cache", name: "Terraform plugin cache"),
                Candidate(path: home + "/.kube/cache", name: "kubectl cache"),
                Candidate(path: home + "/.kube/http-cache", name: "kubectl HTTP cache"),
            ] + childCandidates(home + "/.cache"))

        builder.add(
            CleanCategory(id: "downloads", title: "Installers & Downloads", icon: "arrow.down.circle",
                          detail: "Disk images, packages and unfinished downloads left in Downloads and on the Desktop."),
            (FS.children(of: home + "/Downloads") + FS.children(of: home + "/Desktop")).compactMap { path in
                let ext = (path as NSString).pathExtension.lowercased()
                if ["crdownload", "download", "part", "partial"].contains(ext) { return Candidate(path: path) }
                if ["dmg", "pkg", "mpkg", "iso", "xip"].contains(ext) { return Candidate(path: path, selected: false) }
                return nil
            })

        // Screenshots and screen recordings older than a month, wherever macOS is set to save them.
        let screenshotFolder = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { ($0 as NSString).expandingTildeInPath } ?? home + "/Desktop"
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        builder.add(
            CleanCategory(id: "screenshots", title: "Old Screenshots", icon: "camera.viewfinder",
                          detail: "Screenshots and screen recordings more than 30 days old. Nothing is selected for you."),
            Set([screenshotFolder, home + "/Desktop"]).flatMap { FS.children(of: $0) }.compactMap { path in
                let name = (path as NSString).lastPathComponent
                guard name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ") || name.hasPrefix("Screen Recording "),
                      let modified = FS.modified(path), modified < monthAgo else { return nil }
                return Candidate(path: path, selected: false, detail: "Taken " + Fmt.ago(modified))
            })

        builder.add(
            CleanCategory(id: "mail", title: "Mail Attachments", icon: "paperclip",
                          detail: "Local copies of attachments you opened in Mail. The originals stay in your mailbox."),
            childCandidates(library + "/Containers/com.apple.mail/Data/Library/Mail Downloads"))

        builder.add(
            CleanCategory(id: "backups", title: "iOS Device Backups", icon: "iphone",
                          detail: "Local iPhone and iPad backups. Remove only backups you no longer need."),
            childCandidates(library + "/Application Support/MobileSync/Backup") { _ in false })

        builder.add(
            CleanCategory(id: "trash", title: "Trash", icon: "trash",
                          detail: "Items already in the Trash. Emptying it deletes them permanently.",
                          deletesPermanently: true),
            childCandidates(home + "/.Trash"))

        return builder.categories
    }
}

// MARK: - Privacy

enum PrivacyScanner {
    private struct Browser {
        let name: String
        let bundleID: String
        let profileRoot: String?   // Chromium "User Data" directory
        let cacheRoot: String?
    }

    static func scan(report: @escaping ProgressReport, cancel: CancelFlag) -> [CleanCategory] {
        let home = FS.home
        let library = home + "/Library"
        let support = library + "/Application Support"
        var builder = CategoryBuilder(report: report, cancel: cancel)

        func runningWarning(_ name: String, _ bundleID: String) -> String? {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
                ? nil : "\(name) is running. Quit it before cleaning so the data is not rewritten."
        }

        // Safari
        let safariData = library + "/Containers/com.apple.Safari/Data/Library"
        builder.add(
            CleanCategory(id: "safari", title: "Safari", icon: "safari",
                          detail: "Browsing history, cookies, cache and session data. Requires Full Disk Access.",
                          warning: runningWarning("Safari", "com.apple.Safari")),
            [
                Candidate(path: library + "/Safari/History.db", selected: false, name: "History"),
                Candidate(path: library + "/Safari/History.db-wal", selected: false, name: "History (journal)"),
                Candidate(path: library + "/Safari/Downloads.plist", selected: false, name: "Download list"),
                Candidate(path: library + "/Safari/LastSession.plist", selected: false, name: "Last session"),
                Candidate(path: safariData + "/Cookies/Cookies.binarycookies", selected: false, name: "Cookies"),
                Candidate(path: safariData + "/Caches", selected: false, name: "Cache"),
                Candidate(path: library + "/Caches/com.apple.Safari", selected: false, name: "Cache (legacy)"),
            ])

        // Chromium family
        let chromium = [
            Browser(name: "Google Chrome", bundleID: "com.google.Chrome", profileRoot: support + "/Google/Chrome", cacheRoot: library + "/Caches/Google/Chrome"),
            Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", profileRoot: support + "/Microsoft Edge", cacheRoot: library + "/Caches/Microsoft Edge"),
            Browser(name: "Brave", bundleID: "com.brave.Browser", profileRoot: support + "/BraveSoftware/Brave-Browser", cacheRoot: library + "/Caches/BraveSoftware/Brave-Browser"),
            Browser(name: "Arc", bundleID: "company.thebrowser.Browser", profileRoot: support + "/Arc/User Data", cacheRoot: library + "/Caches/Arc/User Data"),
            Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", profileRoot: support + "/Vivaldi", cacheRoot: library + "/Caches/Vivaldi"),
        ]
        for browser in chromium {
            guard let root = browser.profileRoot, FS.isDirectory(root) else { continue }
            var candidates: [Candidate] = []
            let profiles = FS.children(of: root).filter {
                let name = ($0 as NSString).lastPathComponent
                return name == "Default" || name.hasPrefix("Profile ")
            }
            for profile in profiles {
                let label = (profile as NSString).lastPathComponent
                let files: [(String, String)] = [
                    ("History", "History"), ("History-journal", "History (journal)"),
                    ("Cookies", "Cookies"), ("Network/Cookies", "Cookies"),
                    ("Top Sites", "Top sites"), ("Visited Links", "Visited links"),
                    ("Sessions", "Open tabs & sessions"),
                    ("Code Cache", "Code cache"), ("GPUCache", "GPU cache"),
                    ("Service Worker/CacheStorage", "Site storage cache"),
                ]
                for (relative, title) in files {
                    candidates.append(Candidate(path: "\(profile)/\(relative)", selected: false,
                                                name: title, detail: "Profile: \(label)"))
                }
                if let cacheRoot = browser.cacheRoot {
                    candidates.append(Candidate(path: "\(cacheRoot)/\(label)", selected: false,
                                                name: "Cache", detail: "Profile: \(label)"))
                }
            }
            builder.add(
                CleanCategory(id: browser.bundleID, title: browser.name, icon: "globe",
                              detail: "Browsing history, cookies, sessions and caches for each profile.",
                              warning: runningWarning(browser.name, browser.bundleID)),
                candidates)
        }

        // Firefox: places.sqlite also holds bookmarks, so history is deliberately not offered.
        var firefox: [Candidate] = []
        for profile in FS.children(of: support + "/Firefox/Profiles") {
            let label = (profile as NSString).lastPathComponent
            firefox.append(Candidate(path: profile + "/cookies.sqlite", selected: false, name: "Cookies", detail: "Profile: \(label)"))
            firefox.append(Candidate(path: profile + "/sessionstore-backups", selected: false, name: "Session backups", detail: "Profile: \(label)"))
            firefox.append(Candidate(path: library + "/Caches/Firefox/Profiles/\(label)", selected: false, name: "Cache", detail: "Profile: \(label)"))
        }
        builder.add(
            CleanCategory(id: "firefox", title: "Firefox", icon: "globe",
                          detail: "Cookies, session backups and caches. History is kept because it shares a file with bookmarks.",
                          warning: runningWarning("Firefox", "org.mozilla.firefox")),
            firefox)

        builder.add(
            CleanCategory(id: "recents", title: "Recent Items", icon: "clock.arrow.circlepath",
                          detail: "Lists of recently opened documents, apps and servers shown in menus and the Dock."),
            childCandidates(support + "/com.apple.sharedfilelist") { _ in false })

        builder.add(
            CleanCategory(id: "shell", title: "Terminal History", icon: "terminal",
                          detail: "Command history kept by your shells. It can contain pasted secrets."),
            [
                Candidate(path: home + "/.zsh_history", selected: false, name: "zsh history", detail: "~"),
                Candidate(path: home + "/.bash_history", selected: false, name: "bash history", detail: "~"),
                Candidate(path: home + "/.zsh_sessions", selected: false, name: "zsh session files", detail: "~"),
                Candidate(path: home + "/.python_history", selected: false, name: "Python history", detail: "~"),
                Candidate(path: home + "/.node_repl_history", selected: false, name: "Node REPL history", detail: "~"),
                Candidate(path: home + "/.psql_history", selected: false, name: "psql history", detail: "~"),
                Candidate(path: home + "/.mysql_history", selected: false, name: "MySQL history", detail: "~"),
                Candidate(path: home + "/.lesshst", selected: false, name: "less history", detail: "~"),
            ])

        builder.add(
            CleanCategory(id: "quicklook", title: "Quick Look Thumbnails", icon: "eye",
                          detail: "Cached previews, which can reveal the contents of files you have since deleted."),
            [Candidate(path: library + "/Caches/com.apple.QuickLook.thumbnailcache", selected: false, name: "Thumbnail cache")])

        return builder.categories
    }
}

// MARK: - Developer project artifacts

enum DevJunkScanner {
    private struct Rule {
        let category: String
        /// Returns true when `name` inside `parent` is a regenerable artifact directory.
        let matches: (_ name: String, _ parent: String) -> Bool
    }

    private static func has(_ parent: String, _ files: String...) -> Bool {
        files.contains { FS.exists("\(parent)/\($0)") }
    }

    private static let rules: [Rule] = [
        Rule(category: "node") { name, _ in name == "node_modules" },
        Rule(category: "python") { name, parent in
            (name == ".venv" || name == "venv" || name == "env") && FS.exists("\(parent)/\(name)/pyvenv.cfg")
        },
        Rule(category: "python") { name, _ in name == ".tox" || name == ".mypy_cache" || name == ".pytest_cache" || name == ".ruff_cache" },
        Rule(category: "terraform") { name, _ in name == ".terraform" || name == ".terragrunt-cache" },
        Rule(category: "build") { name, parent in name == "target" && has(parent, "Cargo.toml", "pom.xml") },
        Rule(category: "build") { name, parent in name == "build" && has(parent, "build.gradle", "build.gradle.kts", "pubspec.yaml", "CMakeLists.txt") },
        Rule(category: "build") { name, parent in name == ".build" && has(parent, "Package.swift") },
        Rule(category: "build") { name, parent in name == "Pods" && has(parent, "Podfile") },
        Rule(category: "build") { name, _ in name == "DerivedData" || name == ".gradle" || name == ".dart_tool" },
        Rule(category: "web") { name, parent in
            [".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular"].contains(name) && has(parent, "package.json")
        },
    ]

    private static let templates: [CleanCategory] = [
        CleanCategory(id: "node", title: "Node Modules", icon: "cube.box",
                      detail: "Installed dependencies. Restore them any time with npm, Yarn or pnpm install."),
        CleanCategory(id: "python", title: "Python Environments", icon: "chevron.left.forwardslash.chevron.right",
                      detail: "Virtual environments and tool caches. Recreate them from your requirements file."),
        CleanCategory(id: "terraform", title: "Terraform & Terragrunt", icon: "square.stack.3d.up",
                      detail: "Downloaded providers and modules. `terraform init` restores them."),
        CleanCategory(id: "build", title: "Build Output", icon: "hammer",
                      detail: "Compiled products from Swift, Rust, Gradle, Maven, Flutter and CocoaPods projects."),
        CleanCategory(id: "web", title: "Web Framework Caches", icon: "globe",
                      detail: "Build caches from Next.js, Nuxt, Turborepo, SvelteKit and similar tools."),
    ]

    static func scan(report: @escaping ProgressReport, cancel: CancelFlag) -> [CleanCategory] {
        var found: [String: [String]] = [:]
        let skippedTopLevel: Set<String> = ["Library", "Applications", "Pictures", "Music", "Movies", "Public"]
        var visited = 0

        FS.walk(FS.home) { kind, entry in
            guard kind == .directory, entry.level > 0 else { return .proceed }
            visited += 1
            if visited % 512 == 0 {
                if cancel.isCancelled { return .stop }
                report(Fmt.tilde(entry.path))
            }
            let name = entry.name
            if entry.level == 1, skippedTopLevel.contains(name) { return .skip }
            if entry.level > 9 || FS.isPackage(name) { return .skip }

            let path = entry.path
            let parent = (path as NSString).deletingLastPathComponent
            if let rule = rules.first(where: { $0.matches(name, parent) }) {
                if !Prefs.isExcluded(path) { found[rule.category, default: []].append(path) }
                return .skip
            }
            // Hidden directories hold tool state rather than projects; nothing below them is of interest.
            return name.hasPrefix(".") ? .skip : .proceed
        }

        var result: [CleanCategory] = []
        for template in templates {
            guard !cancel.isCancelled, let paths = found[template.id] else { continue }
            report(template.title)
            var category = template
            for path in paths {
                if cancel.isCancelled { break }
                let size = FS.size(of: path, cancel: cancel)
                guard size > 0 else { continue }
                let project = (path as NSString).deletingLastPathComponent
                let touched = projectLastTouched(project)
                category.items.append(CleanItem(
                    path: path,
                    name: (project as NSString).lastPathComponent + "/" + (path as NSString).lastPathComponent,
                    detail: Fmt.tilde(project) + " · project last changed " + Fmt.ago(touched),
                    size: size, selected: false, date: touched))
            }
            category.items.sort { $0.size > $1.size }
            if !category.items.isEmpty { result.append(category) }
        }
        return result
    }

    /// Newest modification time among a project's own top-level files, ignoring the artifacts themselves.
    private static func projectLastTouched(_ project: String) -> Date {
        let artifacts: Set<String> = ["node_modules", ".venv", "venv", "env", ".terraform", "target", "build", ".build", "Pods", ".next", ".gradle"]
        let dates = FS.children(of: project)
            .filter { !artifacts.contains(($0 as NSString).lastPathComponent) }
            .compactMap(FS.modified)
        return dates.max() ?? FS.modified(project) ?? Date()
    }
}
