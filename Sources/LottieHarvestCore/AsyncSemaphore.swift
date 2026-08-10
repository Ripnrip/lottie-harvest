import Foundation

/// Minimal actor-based async semaphore for bounding concurrent downloads.
///
/// `wait()` reserves a permit (or suspends until one is available); `signal()`
/// releases one. `withPermit(_:)` guarantees release even on throw, and only
/// accepts `@Sendable` closures so Swift 6 concurrency stays honest.
public actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(permits: Int) {
        self.permits = max(1, permits)
    }

    public func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    public func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }

    /// Run `body` while holding one permit. The permit is always released,
    /// even if `body` throws (same-isolation `signal()` needs no `await`).
    public func withPermit<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        await wait()
        do {
            let result = try await body()
            signal()
            return result
        } catch {
            signal()
            throw error
        }
    }
}
