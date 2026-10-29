import XCTest
@testable import Kaddo

final class AgentActivityTests: XCTestCase {
    func testNativeWebActionsPublishResearchProgress() {
        var parser = AgentActivityParser()
        let input = """
        {"type":"item.started","item":{"type":"web_search","action":{"type":"search","queries":["Swift documentation","Swift concurrency"]}}}
        {"type":"item.completed","item":{"type":"web_search","action":{"type":"open_page","url":"https://swift.org"}}}
        {"type":"item.completed","item":{"type":"web_search","action":{"type":"find_in_page","pattern":"concurrency"}}}
        """
        XCTAssertEqual(parser.append(Data(input.utf8), final: true).map(\.text), ["Searching: Swift documentation; Swift concurrency", "Read: https://swift.org", "Found in page: concurrency"])
    }
    func testPartialLinesAndPublicEvents() throws {
        var parser = AgentActivityParser()
        let first = Data(#"{"type":"item.started","item":{"type":"command_execution","command":"pwd"}}"#.utf8)
        XCTAssertTrue(parser.append(first.prefix(17)).isEmpty)
        let started = parser.append(first.dropFirst(17) + Data([10]))
        XCTAssertEqual(started.first?.kind, "command_execution")
        XCTAssertEqual(started.first?.text, "Running: pwd")
        let lines = """
        {"type":"item.completed","item":{"type":"command_execution","command":"pwd","exit_code":0,"aggregated_output":"/workspace"}}
        {"type":"item.completed","item":{"type":"file_change","changes":[{"kind":"add","path":"output/result.md"}]}}
        {"type":"item.completed","item":{"type":"web_search","query":"Swift documentation"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"Verified result."}}
        """
        let events = parser.append(Data(lines.utf8), final: true)
        XCTAssertEqual(events.map(\.kind), ["command_execution", "file_change", "web_search", "agent_message"])
        XCTAssertTrue(events[0].text.contains("Exit status: 0"))
        XCTAssertEqual(events[1].text, "add: output/result.md")
        XCTAssertEqual(events[3].text, "Verified result.")
        XCTAssertEqual(try JSONDecoder().decode(AgentActivity.self, from: JSONEncoder().encode(events[0])), events[0])
    }

    func testReasoningAndUnknownEventsAreNeverPublished() {
        var parser = AgentActivityParser()
        let input = """
        {"type":"item.completed","item":{"type":"reasoning","text":"private reasoning"}}
        {"type":"item.completed","item":{"type":"unknown","text":"hidden"}}
        {"type":"thread.updated","thread_id":"secret"}
        stderr that is not JSON
        {"type":"item.started","item":{"type":"agent_message","text":"partial"}}
        """
        XCTAssertTrue(parser.append(Data(input.utf8), final: true).isEmpty)
    }

    func testBoundsAndRecoveryAfterOversizedLine() {
        var parser = AgentActivityParser(maximumEvents: 1, maximumLineBytes: 256)
        let good = #"{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}"# + "\n"
        let events = parser.append(Data((String(repeating: "x", count: 300) + "\n" + good + good).utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.text, "hello")
        XCTAssertTrue(parser.append(Data(good.utf8)).isEmpty)
    }

    func testTextIsBoundedAndUnicodeSurvivesChunkBoundary() {
        var parser = AgentActivityParser()
        let input = Data((#"{"type":"item.completed","item":{"type":"agent_message","text":""# + String(repeating: "🟢", count: 2200) + #""}}"# + "\n").utf8)
        XCTAssertTrue(parser.append(input.prefix(101)).isEmpty)
        let result = parser.append(input.dropFirst(101))
        XCTAssertEqual(result.first?.text.count, 2000)
    }

    func testVerifierVerdictsAreVisibleWithoutLoggingToolArguments() throws {
        var parser = AgentActivityParser()
        let row: [String: Any] = ["type": "item.completed", "item": ["type": "mcp_tool_call", "server": "kaddo_verifier", "tool": "verify_task", "arguments": ["private": "not logged"], "result": ["content": [["type": "text", "text": "{\"action\":\"accept\",\"verdict\":\"completed\"}"]]]]]
        let events = parser.append(try JSONSerialization.data(withJSONObject: row), final: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].text.contains("accept"))
        XCTAssertFalse(events[0].text.contains("not logged"))
        XCTAssertEqual(events[0].kind, "mcp_tool_call")
    }

    func testLaunchEnablesPublicJSONForChatAndAgents() {
        let url = URL(fileURLWithPath: "/tmp/kaddo")
        XCTAssertTrue(CodexLaunchPolicy.arguments(workspace: url, output: url, background: true).contains("--json"))
        XCTAssertTrue(CodexLaunchPolicy.arguments(workspace: url, output: url, background: false).contains("--json"))
    }

    func testRealStartupEventsPublishReadyOnceWithoutIdentifiers() {
        var parser = AgentActivityParser()
        let lines = """
        {"type":"thread.started","thread_id":"private-id"}
        {"type":"turn.started","payload":"not public"}
        {"type":"turn.started"}
        {"type":"item.started","item":{"type":"command_execution","command":"pwd"}}
        """
        let events = parser.append(Data(lines.utf8), final: true)
        XCTAssertEqual(events.map(\.status), [.ready, .working])
        XCTAssertEqual(events.first?.kind, "status")
        XCTAssertFalse(events.map(\.text).joined().contains("private-id"))
        XCTAssertFalse(events.map(\.text).joined().contains("not public"))
    }

    func testTurnStartedCanEstablishReadinessAndStartupRespectsEventBound() {
        var parser = AgentActivityParser(maximumEvents: 1)
        let lines = "{\"type\":\"turn.started\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"hello\"}}\n"
        let events = parser.append(Data(lines.utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.status, .ready)
    }

    func testPresentationDistinguishesProcessLaunchFromFirstActivity() {
        XCTAssertEqual(AgentExecutionPresentation.status(for: []), .preparing)
        let processLaunched = AgentActivity(kind: "status", text: "Starting agent", status: .connecting)
        XCTAssertEqual(AgentExecutionPresentation.status(for: [processLaunched]), .connecting)
        let ready = AgentActivity(kind: "status", text: "Connected", status: .ready)
        XCTAssertEqual(AgentExecutionPresentation.status(for: [processLaunched, ready]), .ready)
        let command = AgentActivity(kind: "command_execution", text: "Running: pwd", status: .working)
        XCTAssertEqual(AgentExecutionPresentation.status(for: [processLaunched, ready, command]), .working)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(AgentExecutionPresentation.elapsed(since: start, now: start.addingTimeInterval(65)), "1m 5s")
        XCTAssertEqual(AgentExecutionPresentation.elapsed(since: start, now: start.addingTimeInterval(-5)), "0s")
    }
}
