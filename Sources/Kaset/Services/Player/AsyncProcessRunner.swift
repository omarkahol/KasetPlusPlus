import Foundation

// MARK: - StreamExtractionLimiter

/// Bounds concurrent `yt-dlp` subprocess extractions so hover prefetching and
/// queue preloading cannot spawn unbounded child processes.
actor StreamExtractionLimiter {
    static let shared = StreamExtractionLimiter(maxConcurrent: 2)

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let maxConcurrent: Int
    private var runningCount = 0
    private var waiters: [Waiter] = []

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await self.acquire()
        defer { self.release() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if self.runningCount < self.maxConcurrent {
            self.runningCount += 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if self.runningCount < self.maxConcurrent {
                    self.runningCount += 1
                    continuation.resume()
                    return
                }
                self.waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = self.waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while !self.waiters.isEmpty {
            let next = self.waiters.removeFirst()
            next.continuation.resume()
            return
        }
        self.runningCount = max(0, self.runningCount - 1)
    }
}

// MARK: - AsyncProcessRunner

/// Non-blocking `Foundation.Process` runner for Swift Concurrency.
///
/// Drains `stdout` and `stderr` asynchronously via `FileHandle.readabilityHandler`
/// and resumes on `process.terminationHandler` instead of calling
/// `process.waitUntilExit()`, avoiding cooperative thread-pool starvation and
/// 64 KB pipe-buffer deadlocks.
enum AsyncProcessRunner {
    struct Output: Sendable {
        let terminationStatus: Int32
        let stdout: Data
        let stderr: Data
    }

    private final class ExecutionState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()
        private var didResume = false
        private var continuation: CheckedContinuation<Output?, Never>?
        private let maxOutputBytes: Int

        init(maxOutputBytes: Int) {
            self.maxOutputBytes = maxOutputBytes
        }

        func setContinuation(_ continuation: CheckedContinuation<Output?, Never>) {
            self.lock.withLock {
                self.continuation = continuation
            }
        }

        func appendStdout(_ chunk: Data) {
            self.lock.withLock {
                Self.appendBounded(&self.stdoutData, chunk: chunk, limit: self.maxOutputBytes)
            }
        }

        func appendStderr(_ chunk: Data) {
            self.lock.withLock {
                Self.appendBounded(&self.stderrData, chunk: chunk, limit: self.maxOutputBytes)
            }
        }

        func finish(status: Int32?, remainingStdout: Data, remainingStderr: Data) {
            let resumed: (CheckedContinuation<Output?, Never>?, Output?) = self.lock.withLock {
                guard !self.didResume else { return (nil, nil) }
                self.didResume = true
                Self.appendBounded(&self.stdoutData, chunk: remainingStdout, limit: self.maxOutputBytes)
                Self.appendBounded(&self.stderrData, chunk: remainingStderr, limit: self.maxOutputBytes)
                let cont = self.continuation
                self.continuation = nil
                guard let status else { return (cont, nil) }
                return (cont, Output(terminationStatus: status, stdout: self.stdoutData, stderr: self.stderrData))
            }
            resumed.0?.resume(returning: resumed.1)
        }

        private static func appendBounded(_ target: inout Data, chunk: Data, limit: Int) {
            guard !chunk.isEmpty, target.count < limit else { return }
            let remaining = limit - target.count
            target.append(chunk.prefix(remaining))
        }
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int = 1_048_576
    ) async -> Output? {
        guard !Task.isCancelled else { return nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let state = ExecutionState(maxOutputBytes: maxOutputBytes)

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                state.appendStdout(data)
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                state.appendStderr(data)
            }
        }

        let timeoutTask = Task {
            let clampedTimeout = max(0.05, timeoutSeconds)
            try? await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
                state.setContinuation(continuation)

                process.terminationHandler = { terminatedProcess in
                    timeoutTask.cancel()
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    let remainingStdout = stdoutHandle.readDataToEndOfFile()
                    let remainingStderr = stderrHandle.readDataToEndOfFile()
                    state.finish(
                        status: terminatedProcess.terminationStatus,
                        remainingStdout: remainingStdout,
                        remainingStderr: remainingStderr
                    )
                }

                do {
                    try process.run()
                    if Task.isCancelled, process.isRunning {
                        process.terminate()
                    }
                } catch {
                    timeoutTask.cancel()
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    state.finish(status: nil, remainingStdout: Data(), remainingStderr: Data())
                }
            }
        } onCancel: {
            timeoutTask.cancel()
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
