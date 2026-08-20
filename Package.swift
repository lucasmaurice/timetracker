// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "timetracker",
    platforms: [.macOS(.v14)],
    dependencies: [
        // swift-testing as a PACKAGE dependency, not the toolchain's bundled copy. This machine
        // has Command Line Tools only (no Xcode), which ships neither XCTest nor the built-in
        // Testing module — `import XCTest` and `import Testing` both fail to resolve. Building it
        // from source is what makes `swift test` work here at all. The compiler will warn that it
        // is redundant on a full Xcode toolchain; removing it breaks CLT-only machines, so keep it
        // until the project decides Xcode is a hard prerequisite.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "timetracker",
            path: "Sources/timetracker",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "timetrackerTests",
            dependencies: ["timetracker", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/timetrackerTests"
        )
    ]
)
