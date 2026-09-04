import Darwin
import Foundation

enum TimedProcessRunnerError: LocalizedError {
    case timedOut(command: String, timeout: TimeInterval)
    case failed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, timeout):
            return "\(command) did not finish within \(Int(timeout))s and was killed."
        case let .failed(command, status, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(command) exited with status \(status)." : trimmed
        }
    }
}

/// Runs a child process synchronously, draining its output off-thread (so a chatty child cannot
/// deadlock against the pipe) and enforcing an optional wall-clock timeout. On timeout the child gets
/// SIGTERM, then SIGKILL two seconds later, and the caller receives `.timedOut` instead of blocking
/// forever. Used for every helper the account switch shells out to.
enum TimedProcessRunner {
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputLock = NSLock()
        var collected = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            collected = data
            outputLock.unlock()
            readGroup.leave()
        }

        try process.run()

        let command = ([launchPath] + arguments).joined(separator: " ")
        if let timeout {
            if !waitForExit(process, within: timeout) {
                process.terminate()
                if !waitForExit(process, within: 2) {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                // A grandchild may still hold the pipe open; never block on it after a kill.
                if readGroup.wait(timeout: .now() + 1) == .timedOut {
                    try? pipe.fileHandleForReading.close()
                }
                throw TimedProcessRunnerError.timedOut(command: command, timeout: timeout)
            }
        } else {
            process.waitUntilExit()
        }

        if readGroup.wait(timeout: .now() + 2) == .timedOut {
            try? pipe.fileHandleForReading.close()
        }
        outputLock.lock()
        let output = String(data: collected, encoding: .utf8) ?? ""
        outputLock.unlock()

        if process.terminationStatus != 0 {
            throw TimedProcessRunnerError.failed(
                command: command,
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }

    private static func waitForExit(_ process: Process, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }
}

/// The managed local app-server daemon (`codex app-server daemon …`) exists for SSH/CLI-driven
/// setups. ChatGPT.app 26.9+ launches its own `codex app-server` child and never talks to the daemon,
/// so after an auth switch the daemon only needs a restart when it is actually running. Its control
/// socket is the liveness signal: when the socket is absent nothing is holding the old tokens, and the
/// daemon subcommands must not be called at all — with a stale pid file pointing at a zombie (seen with
/// the 0.153.x standalone `pid-update-loop`) each subcommand polls for ~60s before giving up, which left
/// the desktop app quit for minutes in the middle of a switch.
enum CodexAppServerDaemon {
    static let commandTimeout: TimeInterval = 15

    static func controlSocketURL(codexHome: URL) -> URL {
        codexHome
            .appendingPathComponent("app-server-control", isDirectory: true)
            .appendingPathComponent("app-server-control.sock")
    }

    static func isLikelyRunning(codexHome: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: controlSocketURL(codexHome: codexHome).path)
    }
}
