import Foundation

/// Shared, dependency-free process runner used by the context enricher and the repo→ticket
/// miner. Reads the pipe concurrently (so large output like `git log` can't deadlock the
/// buffer) and kills a hung process via a watchdog. Launchd apps have a minimal PATH, so we
/// always resolve absolute tool paths.
enum Shell {
    /// Run a command with a hard timeout; returns trimmed stdout, or nil on failure/empty.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 4) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // returns at EOF (exit or kill)
        proc.waitUntilExit()
        watchdog.cancel()
        let s = String(data: data, encoding: .utf8)
        return (s?.isEmpty == false) ? s : nil
    }

    /// Resolve a tool name against the common Homebrew/system bin dirs.
    static func locate(_ name: String) -> String? {
        for base in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let p = "\(base)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Convenience: run git (always at /usr/bin/git) against a repo, longer default timeout
    /// since history walks can be slower than a `branch --show-current`.
    static func git(_ args: [String], timeout: TimeInterval = 8) -> String? {
        run("/usr/bin/git", args, timeout: timeout)
    }
}
