import XCTest
@testable import ExerciseAnalyserCore

final class EvaluationCompletionTests: XCTestCase {
    @MainActor
    func testDeadlineCanReleaseAllWaitersWithoutFrameworkCompletion() async {
        let completion = EvaluationCompletion()
        var released = 0
        let observers = (0..<10).map { _ in
            Task { @MainActor in
                await completion.wait()
                released += 1
            }
        }
        await Task.yield()
        // A deadline can release observers without awaiting the work they originally shared.
        completion.finish()
        for observer in observers { await observer.value }
        XCTAssertEqual(released, 10)
        // A delayed framework callback must not resume continuations twice.
        completion.finish()
        await completion.wait()
        XCTAssertEqual(released, 10)
    }

    @MainActor
    func testOldCompletionCannotReleaseReplacementEvaluation() async {
        let old = EvaluationCompletion()
        let replacement = EvaluationCompletion()
        var released = false
        let waiter = Task { @MainActor in
            await replacement.wait()
            released = true
        }
        old.finish()
        await Task.yield()
        XCTAssertFalse(released)
        replacement.finish()
        await waiter.value
        XCTAssertTrue(released)
    }
}
