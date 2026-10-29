import XCTest
@testable import Kaddo

@MainActor final class ComputerProtocolTests: XCTestCase {
    func testInstalledCodexCallsMediatedComputerTool() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_LIVE_COMPUTER"] == "1" else { throw XCTSkip("Set KADDO_LIVE_COMPUTER=1 for the installed-Codex protocol check.") }
        let bridge = CodexRealtimeBridge(requestTimeout: 30, isolatedConfiguration: true)
        defer { bridge.stop() }
        var called = false
        var reply = CodexTypedVoiceReply()
        var completed = false
        var answer: String?
        bridge.onServerRequest = { method, params in
            guard method == "item/tool/call", params["tool"] as? String == "kaddo_computer_observe" else { return nil }
            called = true
            return ["success": true, "contentItems": [["type": "inputText", "text": "Synthetic protocol-only QA evidence. No real screenshot, app or personal data is used."]]]
        }
        bridge.onNotification = { method, params in
            if method == "item/completed" { reply.receiveItem(params) }
            if method == "turn/completed", let turn = params["turn"] as? [String: Any] { answer = reply.finish(turn); completed = true }
        }
        try await bridge.start()
        let started = try await bridge.request("thread/start", params: ["cwd": try XCTUnwrap(bridge.workingDirectory).path, "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never", "baseInstructions": "This is a synthetic protocol test. Follow the human request and use only the provided dynamic tools.", "dynamicTools": AgentComputerPolicy.tools])
        let id = try XCTUnwrap((started["thread"] as? [String: Any])?["id"] as? String)
        reply.begin()
        let turn = try await bridge.request("turn/start", params: ["threadId": id, "input": [["type": "text", "text": "Call kaddo_computer_observe exactly once. This returns synthetic evidence only. Then reply with exactly KADDO_COMPUTER_PROTOCOL_OK. Use no other tool."]]])
        reply.bind((turn["turn"] as? [String: Any])?["id"] as? String)
        for _ in 0..<600 {
            if completed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(called, "Installed Codex did not call the mediated computer tool")
        XCTAssertTrue(completed)
        XCTAssertEqual(answer, "KADDO_COMPUTER_PROTOCOL_OK")
    }
}
