import Foundation
import Darwin

/// Runs a local helper without blocking Swift's cooperative pool or letting stderr fill a pipe.
public enum LocalProcess {
    public struct Result: Sendable {
        public let status: Int32
        public let timedOut: Bool
        public let stderr: String
    }

    public static func run(executable: URL, arguments: [String], timeout: Duration) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        // Drain continuously, keeping only the useful tail. Reading only after exit can deadlock
        // a verbose helper as soon as the operating system's pipe buffer fills.
        let drain = Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var tail = Data()
                    while true {
                        let data = errors.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        tail.append(data)
                        tail = Data(tail.suffix(4096))
                    }
                    continuation.resume(returning: String(decoding: tail, as: UTF8.self))
                }
            }
        }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return false }
            guard process.isRunning else { return false }
            process.terminate()
            // Some helpers ignore SIGTERM. Give them a brief grace period, then enforce the bound.
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return true
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        timer.cancel()
        let timedOut = await timer.value
        // Close the parent's write end as well so the reader always reaches EOF.
        try? errors.fileHandleForWriting.close()
        let stderr = await drain.value
        try? errors.fileHandleForReading.close()
        return Result(status: process.terminationStatus, timedOut: timedOut, stderr: stderr)
    }
}
