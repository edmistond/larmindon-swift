import XCTest
@testable import LarmindonKit

@MainActor
final class TranscriptionFailureReporterTests: XCTestCase {
    private enum Failure: LocalizedError {
        case runtime
        var errorDescription: String? { "Recognition stopped" }
    }

    func testRuntimeErrorsAreTerminalFailuresAndOnlyReportedOnce() async {
        for context in ["Speech transcriber error", "SpeechAnalyzer error"] {
            let (stream, continuation) = AsyncStream<CaptionResult>.makeStream()
            let reporter = TranscriptionFailureReporter(continuation: continuation)
            reporter.report(Failure.runtime, context: context)
            reporter.report(Failure.runtime, context: "Late second error")
            continuation.yield(.volatile("Late words"))
            var results: [CaptionResult] = []
            for await result in stream { results.append(result) }
            XCTAssertEqual(results, [.failure("\(context): Recognition stopped")])
        }
    }

    func testIntentionalStopSuppressesLateFrameworkError() async {
        let (stream, continuation) = AsyncStream<CaptionResult>.makeStream()
        let reporter = TranscriptionFailureReporter(continuation: continuation)
        reporter.stop()
        reporter.report(Failure.runtime, context: "SpeechAnalyzer error")
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        XCTAssertNil(result)
    }

    func testCancellationOfRecognitionTaskDoesNotBecomeFailure() async {
        let (stream, continuation) = AsyncStream<CaptionResult>.makeStream()
        let reporter = TranscriptionFailureReporter(continuation: continuation)
        let task = Task {
            // MainActor cannot enter this task until the caller has cancelled it.
            reporter.report(CancellationError(), context: "SpeechAnalyzer error")
        }
        task.cancel()
        await task.value
        reporter.stop()
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        XCTAssertNil(result)
    }
}
