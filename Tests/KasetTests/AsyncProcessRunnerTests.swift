import Foundation
import Testing
@testable import KasetPlus

@Suite("AsyncProcessRunner & StreamExtractionLimiter", .serialized, .tags(.service))
struct AsyncProcessRunnerTests {
    @Test("Drains >128 KB stdout without pipe-buffer deadlock")
    func drainsLargeOutputWithoutDeadlock() async {
        let output = await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' 'a'"],
            timeoutSeconds: 5.0
        )

        #expect(output != nil)
        #expect(output?.terminationStatus == 0)
        #expect(output?.stdout.count == 204_800)
    }

    @Test("Terminates process cleanly when timeout expires")
    func terminatesOnTimeout() async {
        let output = await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeoutSeconds: 0.1
        )

        #expect(output == nil || output?.terminationStatus != 0)
    }

    @Test("Terminates process cleanly when parent Task is cancelled")
    func terminatesOnCancellation() async {
        let task = Task {
            await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeoutSeconds: 10.0
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let output = await task.value

        #expect(output == nil || output?.terminationStatus != 0)
    }

    @Test("StreamExtractionLimiter bounds concurrent executions")
    func limiterBoundsConcurrency() async throws {
        let limiter = StreamExtractionLimiter(maxConcurrent: 2)
        let counter = ConcurrencyCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 6 {
                group.addTask {
                    try await limiter.withPermit {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        await counter.exit()
                    }
                }
            }
            try await group.waitForAll()
        }

        let maxObserved = await counter.maxActive
        #expect(maxObserved <= 2)
        #expect(maxObserved >= 1)
    }
}

private actor ConcurrencyCounter {
    private var active = 0
    private(set) var maxActive = 0

    func enter() {
        self.active += 1
        if self.active > self.maxActive {
            self.maxActive = self.active
        }
    }

    func exit() {
        self.active = max(0, self.active - 1)
    }
}
