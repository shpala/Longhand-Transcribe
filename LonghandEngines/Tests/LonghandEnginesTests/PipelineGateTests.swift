import Foundation
import Testing
@testable import LonghandEngines

/// One pipeline run at a time, and a job paused while it queues leaves the
/// queue at once instead of when its turn comes.
struct PipelineGateTests {

    @Test func aCancelledWaiterLeavesWhileTheGateIsStillHeld() async throws {
        let gate = PipelineGate()
        try await gate.acquire()

        let queued = Task { try await gate.acquire() }
        try await waitUntil(gate, hasWaiting: 1)
        queued.cancel()

        // Without the cancellation handler this would wait for a release that
        // the test never makes, and the test would hang.
        await #expect(throws: CancellationError.self) { try await queued.value }

        // The withdrawn waiter must not be handed the gate later: after one
        // release it is free, and the next caller gets it without waiting.
        await gate.release()
        try await gate.acquire()
        await gate.release()
    }

    @Test func waitersAreAdmittedInOrderOneAtATime() async throws {
        let gate = PipelineGate()
        try await gate.acquire()
        let order = Order()

        let first = Task {
            try await gate.acquire()
            await order.append(1)
        }
        try await waitUntil(gate, hasWaiting: 1)
        let second = Task {
            try await gate.acquire()
            await order.append(2)
        }
        try await waitUntil(gate, hasWaiting: 2)
        #expect(await order.values.isEmpty)

        await gate.release()
        try await first.value
        // The second is still queued, so it cannot have run.
        #expect(await gate.waitingCount == 1)
        #expect(await order.values == [1], "the second waiter must wait for the first to release")

        await gate.release()
        try await second.value
        #expect(await order.values == [1, 2])
        await gate.release()
    }

    @Test func aTaskCancelledBeforeItQueuesNeverWaits() async throws {
        let gate = PipelineGate()
        try await gate.acquire()
        let queued = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquire()
        }
        await #expect(throws: CancellationError.self) { try await queued.value }
        await gate.release()
    }

    /// Polls rather than sleeping a fixed time, which a loaded CI runner
    /// can outlast.
    private func waitUntil(_ gate: PipelineGate, hasWaiting count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await gate.waitingCount < count {
            guard ContinuousClock.now < deadline else {
                Issue.record("only \(await gate.waitingCount) of \(count) tasks joined the queue")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private actor Order {
        var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }
}
