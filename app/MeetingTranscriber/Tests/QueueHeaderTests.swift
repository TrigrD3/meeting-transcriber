@testable import MeetingTranscriber
import XCTest

final class QueueHeaderTests: XCTestCase {
    func testAnyWorkInFlightIsProcessing() {
        for state in [JobState.waiting, .transcribing, .diarizing, .generatingProtocol] {
            XCTAssertEqual(QueueHeader.compute(jobStates: [.done, state], isProcessing: false), .processing, "\(state)")
        }
    }

    func testTheQueueRunningMakesItProcessingEvenBetweenJobs() {
        XCTAssertEqual(QueueHeader.compute(jobStates: [.done], isProcessing: true), .processing)
    }

    func testWorkInFlightWinsOverAJobWaitingForNames() {
        let header = QueueHeader.compute(jobStates: [.speakerNamingPending, .transcribing], isProcessing: false)
        XCTAssertEqual(header, .processing)
    }

    func testAJobWaitingForNamesNeedsAttention() {
        XCTAssertEqual(QueueHeader.compute(jobStates: [.done, .speakerNamingPending], isProcessing: false), .needsAttention)
    }

    func testNeedsAttentionWinsOverAFailedJob() {
        XCTAssertEqual(QueueHeader.compute(jobStates: [.error, .speakerNamingPending], isProcessing: false), .needsAttention)
    }

    func testOnlyFinishedJobsAreCompleted() {
        XCTAssertEqual(QueueHeader.compute(jobStates: [.done, .done], isProcessing: false), .completed)
    }

    func testAFailedJobKeepsTheListFromBeingCalledCompleted() {
        XCTAssertEqual(QueueHeader.compute(jobStates: [.done, .error], isProcessing: false), .queue)
        XCTAssertEqual(QueueHeader.compute(jobStates: [.error], isProcessing: false), .queue)
    }

    func testAnEmptyListIsNotCompleted() {
        XCTAssertEqual(QueueHeader.compute(jobStates: [], isProcessing: false), .queue)
    }

    func testEveryHeaderHasItsOwnTitleAndIcon() {
        let all = QueueHeader.all
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(Set(all.map(\.title)).count, all.count)
        XCTAssertEqual(Set(all.map(\.systemImage)).count, all.count)
    }
}
