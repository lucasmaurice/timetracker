// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "timetracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "timetracker",
            path: "Sources/timetracker",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
