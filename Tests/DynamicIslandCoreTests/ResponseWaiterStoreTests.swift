import XCTest
@testable import DynamicIslandCore

final class ResponseWaiterStoreTests: XCTestCase {
    func testResponseBeforePollIsDeliveredOnce() async {
        let store = ResponseWaiterStore<String>()
        let eventID = UUID()

        await store.resolve("allow", eventID: eventID)
        let pendingBeforePoll = await store.pendingCount
        XCTAssertEqual(pendingBeforePoll, 1)

        let result = await store.wait(
            eventID: eventID,
            timeoutValue: "timeout",
            timeoutNanoseconds: 1_000_000
        )
        XCTAssertEqual(result, "allow")
        let pendingAfterPoll = await store.pendingCount
        let waitersAfterPoll = await store.waiterCount
        XCTAssertEqual(pendingAfterPoll, 0)
        XCTAssertEqual(waitersAfterPoll, 0)
    }

    func testResponseDuringPollResolvesAndRemovesWaiter() async {
        let store = ResponseWaiterStore<String>()
        let eventID = UUID()

        let poll = Task {
            await store.wait(
                eventID: eventID,
                timeoutValue: "timeout",
                timeoutNanoseconds: 1_000_000_000
            )
        }
        await waitForWaiters(store, count: 1)

        await store.resolve("deny", eventID: eventID)
        let result = await poll.value

        XCTAssertEqual(result, "deny")
        let pending = await store.pendingCount
        let waiters = await store.waiterCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(waiters, 0)
    }

    func testTimeoutResolvesAndRemovesWaiter() async {
        let store = ResponseWaiterStore<String>()
        let eventID = UUID()

        let result = await store.wait(
            eventID: eventID,
            timeoutValue: "timeout",
            timeoutNanoseconds: 1_000_000
        )

        XCTAssertEqual(result, "timeout")
        let pending = await store.pendingCount
        let waiters = await store.waiterCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(waiters, 0)
    }

    func testLateResponseAfterTimeoutIsDropped() async {
        let store = ResponseWaiterStore<String>()
        let eventID = UUID()

        let result = await store.wait(
            eventID: eventID,
            timeoutValue: "timeout",
            timeoutNanoseconds: 1_000_000
        )
        XCTAssertEqual(result, "timeout")

        await store.resolve("allow", eventID: eventID)
        let pending = await store.pendingCount
        let waiters = await store.waiterCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(waiters, 0)

        let second = await store.wait(
            eventID: eventID,
            timeoutValue: "timeout",
            timeoutNanoseconds: 1_000_000
        )
        XCTAssertEqual(second, "timeout")
    }

    func testDuplicateResponseAfterResolveIsDropped() async {
        let store = ResponseWaiterStore<String>()
        let eventID = UUID()

        let poll = Task {
            await store.wait(
                eventID: eventID,
                timeoutValue: "timeout",
                timeoutNanoseconds: 1_000_000_000
            )
        }
        await waitForWaiters(store, count: 1)

        await store.resolve("allow", eventID: eventID)
        let result = await poll.value
        XCTAssertEqual(result, "allow")

        await store.resolve("allow", eventID: eventID)
        let pending = await store.pendingCount
        let waiters = await store.waiterCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(waiters, 0)
    }

    func testDuplicateResponseBeforePollKeepsFirstChoice() async {
        let store = ResponseWaiterStore<String>()
        let eventID = UUID()

        await store.resolve("allow", eventID: eventID)
        await store.resolve("deny", eventID: eventID)

        let result = await store.wait(
            eventID: eventID,
            timeoutValue: "timeout",
            timeoutNanoseconds: 1_000_000
        )
        XCTAssertEqual(result, "allow")
        let pending = await store.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testEventIDIsolation() async {
        let store = ResponseWaiterStore<String>()
        let eventA = UUID()
        let eventB = UUID()

        let pollB = Task {
            await store.wait(
                eventID: eventB,
                timeoutValue: "timeout",
                timeoutNanoseconds: 1_000_000_000
            )
        }
        await waitForWaiters(store, count: 1)

        await store.resolve("allow", eventID: eventA)
        let pendingAfterA = await store.pendingCount
        XCTAssertEqual(pendingAfterA, 1)

        let resultB = await pollB.value
        XCTAssertEqual(resultB, "timeout")
        let waiters = await store.waiterCount
        XCTAssertEqual(waiters, 0)

        let resultA = await store.wait(
            eventID: eventA,
            timeoutValue: "timeout",
            timeoutNanoseconds: 1_000_000
        )
        XCTAssertEqual(resultA, "allow")
        let pendingAfterConsume = await store.pendingCount
        XCTAssertEqual(pendingAfterConsume, 0)
    }

    private func waitForWaiters(
        _ store: ResponseWaiterStore<String>,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await store.waiterCount == count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(count) waiter(s)", file: file, line: line)
    }
}
