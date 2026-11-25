// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sweep",
            path: "Sources/Sweep",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
