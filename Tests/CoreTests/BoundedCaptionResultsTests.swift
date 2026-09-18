import XCTest
@testable import LarmindonKit

@MainActor
final class BoundedCaptionResultsTests: XCTestCase {
    func testDelayedConsumerReceivesEveryFinalWithinCapacity() async {
        let delivery = BoundedCaptionResults()
        var expected: [CaptionResult] = []
        for index in 0..<32 {
            let final = CaptionResult.finalized("Sentence \(index).")
            expected.append(final)
            XCTAssertTrue(delivery.yield(final))
            XCTAssertTrue(delivery.yield(.volatile("Next \(index)")))
        }
        delivery.finish()
        var finals: [CaptionResult] = []
        for await result in delivery.stream {
            if case .finalized = result { finals.append(result) }
            if case .failure = result { XCTFail("Unexpected loss within capacity") }
        }
        XCTAssertEqual(finals, expected)
    }

    func testPartialUpdatesCanBeReplacedWithoutFailure() async {
        let delivery = BoundedCaptionResults(capacity: 2)
        for index in 0..<100 { XCTAssertTrue(delivery.yield(.volatile("\(index)"))) }
        delivery.finish()
        var results: [CaptionResult] = []
        for await result in delivery.stream { results.append(result) }
        XCTAssertEqual(results, [.volatile("98"), .volatile("99")])
    }

    func testFinalizedOverflowIsExplicitAndCannotBeOverwrittenByLaterResults() async {
        for final in [CaptionResult.finalized("Spoken words."), .finalizedSegments([CaptionSegment(text: "Words.")])] {
            let delivery = BoundedCaptionResults(capacity: 2)
            XCTAssertTrue(delivery.yield(final))
            XCTAssertTrue(delivery.yield(.volatile("Preview")))
            XCTAssertFalse(delivery.yield(.volatileSegments([])))
            XCTAssertFalse(delivery.yield(.finalized("Too late")))
            XCTAssertFalse(delivery.yield(.failure("Too late an error")))
            var results: [CaptionResult] = []
            for await result in delivery.stream { results.append(result) }
            XCTAssertEqual(results.last, .failure(BoundedCaptionResults.overflowMessage))
            XCTAssertEqual(results.count, 2)
        }
    }
    func testCancelledConsumerIsNotAProviderFailure() async {
        let delivery = BoundedCaptionResults()
        let consumer = Task { for await _ in delivery.stream {} }
        consumer.cancel()
        await consumer.value
        XCTAssertFalse(delivery.yield(.finalized("Late final during shutdown")))
        XCTAssertFalse(delivery.didFail)
    }

}
