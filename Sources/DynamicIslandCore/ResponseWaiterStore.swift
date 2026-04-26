import Foundation

/// Event-scoped response router for `/response` long-polls.
///
/// A UI click may arrive before the hook starts polling, so responses can be
/// parked by event id. Once a poll times out, that event id is marked expired:
/// a later click for the same stale UI must be dropped instead of parked for a
/// future, unrelated poll.
public actor ResponseWaiterStore<Value: Sendable> {
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Value, Never>
    }

    private var pending: [UUID: Value] = [:]
    private var waiters: [UUID: [Waiter]] = [:]
    private var closed: Set<UUID> = []
    private var closedOrder: [UUID] = []
    // Bounded tombstone cache for events that have already resolved or timed
    // out. 256 is deliberately generous for a UI affordance whose reply
    // window is 25-30 s: it covers several minutes of repeated prompts while
    // preventing an unbounded set if a local client keeps sending stale clicks.
    private let expiredLimit = 256

    public init() {}

    public var waiterCount: Int {
        waiters.values.reduce(0) { $0 + $1.count }
    }

    public var pendingCount: Int {
        pending.count
    }

    public func resolve(_ value: Value, eventID: UUID) {
        guard !closed.contains(eventID) else { return }

        if let parked = waiters.removeValue(forKey: eventID), !parked.isEmpty {
            markClosed(eventID)
            for waiter in parked {
                waiter.continuation.resume(returning: value)
            }
            return
        }

        // A second click before the hook starts polling should not overwrite
        // the first response the user chose.
        guard pending[eventID] == nil else { return }
        pending[eventID] = value
    }

    public func wait(
        eventID: UUID,
        timeoutValue: Value,
        timeoutNanoseconds: UInt64
    ) async -> Value {
        if let value = pending.removeValue(forKey: eventID) {
            markClosed(eventID)
            return value
        }
        if closed.contains(eventID) {
            return timeoutValue
        }

        let token = UUID()
        return await withCheckedContinuation { continuation in
            waiters[eventID, default: []].append(Waiter(
                token: token,
                continuation: continuation
            ))
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.timeout(eventID: eventID, token: token, value: timeoutValue)
            }
        }
    }

    private func timeout(eventID: UUID, token: UUID, value: Value) {
        guard var parked = waiters[eventID],
              let idx = parked.firstIndex(where: { $0.token == token }) else {
            return
        }

        let waiter = parked.remove(at: idx)
        if parked.isEmpty {
            waiters.removeValue(forKey: eventID)
        } else {
            waiters[eventID] = parked
        }
        markClosed(eventID)
        waiter.continuation.resume(returning: value)
    }

    private func markClosed(_ eventID: UUID) {
        if closed.insert(eventID).inserted {
            closedOrder.append(eventID)
        }
        while closedOrder.count > expiredLimit {
            let old = closedOrder.removeFirst()
            closed.remove(old)
        }
    }
}
