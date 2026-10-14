import Foundation

// Releases every observer/refresh waiter even if a cancelled framework operation never calls back.
@MainActor
final class EvaluationCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
