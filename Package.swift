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
            // Strict concurrency, TARGETED — checks every construct that actually uses Swift
            // concurrency (async/await, Task, @Sendable closures), which is precisely where this
            // app's real races live. Measured on this codebase: `targeted` = 1 warning site,
            // `complete` = 323. Complete is dominated by main-actor isolation bookkeeping in
            // main.swift (432 "cannot be mutated from a nonisolated context") rather than by
            // races, so it is a separate, larger piece of work — see the issue tracker.
            //
            // Why this matters here: #9 was a live data race (PeriodCompiler reading
            // Attribution.sprint off-main while main mutated it) that built perfectly clean under
            // Swift 5 mode. No test suite catches that class of bug — only the compiler does.
            //
            // The one remaining warning (main.swift's Task.detached in buildRepoBridgeAndBackfill)
            // is a GENUINE race, not noise: heavy git mining mutates Attribution off-main. Do NOT
            // silence it with @unchecked Sendable — that asserts a safety property the code does
            // not have. It needs the mining to return values applied on main, or an actor.
            swiftSettings: [.unsafeFlags(["-strict-concurrency=targeted"])],
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
