# Sweep

A native, lightweight macOS cleanup and maintenance app built with SwiftUI and SQLite. It finds junk, large and duplicate files, leftover app data and developer build output, and lets you review everything before anything is removed. No dependencies, no cloud, no account.

## Build & run

```bash
./build.sh              # builds build/Sweep.app
./build.sh --install    # installs it to /Applications (the only copy kept) and launches it
```

Requires macOS 14+ and Xcode or the Command Line Tools (`xcode-select --install`).

### Stable signing (recommended)

An ad-hoc signature changes with every build, so macOS forgets permissions such as Full Disk Access after each rebuild. Run this once to create a local self-signed identity that `build.sh` uses automatically:

```bash
scripts/make_signing_identity.sh
```

### Permissions

- **Full Disk Access** (optional): needed to see browser data, Mail and other protected folders. Grant it in System Settings → Privacy & Security → Full Disk Access.
- **Automation (Finder)**: used only to move protected items, such as App Store apps, to the Trash when you uninstall them.
- **Notifications** (optional): scheduled-scan results and low-disk warnings.

## Features

| Section | What it does |
|---|---|
| **Smart Scan** | One pass over the most common ways to free space and speed up your Mac (`⌘R`) |
| **Dashboard** | Live CPU, memory, disk and system details for this Mac |
| **History** | What Sweep has cleaned and how your storage is changing, with **put back** for items moved to the Trash |
| **System Junk** | Caches, logs, Xcode and package-manager data, unfinished downloads and the Trash |
| **Large & Old Files** | Big files in your home folder, so you can decide what is still worth keeping |
| **Duplicates** | Byte-for-byte identical files stored more than once (hard links are ignored) |
| **Similar Photos** | Resized or re-saved copies, edits and burst shots |
| **Developer** | `node_modules`, virtual environments, `.terraform` folders and build output across your projects |
| **Containers** | Docker images, containers, volumes and build cache, plus Xcode simulator devices |
| **Uninstaller** | Removes apps together with the support files they leave behind |
| **Updater** | Outdated Homebrew packages and apps, and App Store apps when `mas` is installed |
| **Space Lens** | A map of what is using your disk; click a folder to look inside |
| **Startup Items** | Background helpers that launch automatically; disable the ones you don't need |
| **Processes** | What is using CPU and memory now, with trends over time |
| **Maintenance** | Routine upkeep tasks, each running a standard macOS command |
| **Privacy** | Browser history, cookies and caches, recent-item lists and shell history (nothing selected by default) |

Sections `1`–`9` are reachable with `⌘1`…`⌘9`.

### Automation

In Settings you can schedule a recurring Smart Scan and set a low-disk warning threshold. With either enabled, closing the window keeps Sweep running in the Dock so they keep working.

## Safety

- Nothing is removed until you review and confirm it. Items go to the **Trash** by default and can be put back from History.
- A deletion guard refuses system locations, your top-level home folders, `~/Library`, keychains and relative or `..` paths.
- Cleanup history is stored only on this Mac, in a local SQLite database.

## Development

```bash
swift build
.build/debug/Sweep --selftest     # runs engine checks against a throwaway directory
```

`--snapshot <dir>` renders every section to a PNG for reviewing the interface without clicking through it.

## License

[MIT](LICENSE)
