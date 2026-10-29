import XCTest
@testable import Kaddo

final class CodexTypedVoiceReplyTests: XCTestCase {
    func testComputerStopSuppressesLateStartAnswerWithoutReleasingAnActiveTurnEarly() {
        var reply = CodexTypedVoiceReply()
        reply.begin(); reply.bind("old")
        reply.discardOutput()
        reply.receiveItem(["turnId": "old", "item": ["type": "agentMessage", "phase": "final_answer", "text": "The computer task started"]])
        XCTAssertTrue(reply.waiting)
        XCTAssertNil(reply.finish(["id": "old", "status": "completed", "items": [["type": "agentMessage", "text": "The computer task started"]]]))
        XCTAssertFalse(reply.waiting)
        reply.begin(); reply.bind("new")
        XCTAssertEqual(reply.finish(["id": "new", "status": "completed", "items": [["type": "agentMessage", "text": "Fresh answer"]]]), "Fresh answer")
    }
    func testFinalItemsSurviveAnEmptyCompletionPayloadAndIgnorePrivateReasoning() {
        var reply = CodexTypedVoiceReply(); reply.begin(); reply.bind("qa")
        reply.receiveItem(["turnId":"other", "item":["type":"agentMessage","text":"Wrong turn"]])
        reply.receiveItem(["turnId":"qa", "item":["type":"reasoning","text":"Private"]])
        reply.receiveItem(["turnId":"qa", "item":["type":"agentMessage","phase":"commentary","text":"Working"]])
        reply.receiveItem(["turnId":"qa", "item":["type":"agentMessage","phase":"final_answer","text":"Orange triangle; purple circle."]])
        XCTAssertEqual(reply.finish(["id":"qa","status":"completed","items":[]]), "Orange triangle; purple circle.")
        XCTAssertFalse(reply.waiting)
        XCTAssertNil(reply.finish(["id":"qa","status":"completed","items":[]]))
    }
    func testCompletionUsesLastFinalAnswerAndDoesNotEndOnAnotherTurn() {
        var reply = CodexTypedVoiceReply(); reply.begin(); reply.bind("qa")
        XCTAssertNil(reply.finish(["id":"other","status":"completed","items":[]]))
        XCTAssertTrue(reply.waiting)
        XCTAssertEqual(reply.finish(["id":"qa","status":"completed","items":[["type":"agentMessage","text":"Legacy final"],["type":"agentMessage","phase":"final_answer","text":"Final"],["type":"agentMessage","phase":"partial_answer","text":"Partial"]]]), "Final")
    }
    func testFailureResetsAndStaleCallbacksCannotReviveStoppedReply() {
        var reply = CodexTypedVoiceReply(); reply.begin()
        XCTAssertNil(reply.finish(["status":"failed"]))
        reply.bind("late")
        XCTAssertFalse(reply.waiting)
        reply.receiveItem(["item":["type":"agentMessage","text":"Late"]])
        XCTAssertNil(reply.finish(["status":"completed"]))
    }
}
