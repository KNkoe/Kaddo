import XCTest
@testable import Kaddo

final class CodexRealtimeBridgeTests: XCTestCase {
    func testFramingAcceptsPartialUTF8AndMultipleMessages() throws {
        var framing = CodexRealtimeFraming()
        let bytes = try CodexRealtimeFraming.encode(["method": "voice", "params": ["text": "héllo 🌱"]])
        let split = bytes.count / 2
        XCTAssertTrue(try framing.append(bytes.prefix(split)).isEmpty)
        let tail = bytes.suffix(from: split) + Data("\n{\"id\":3,\"result\":{}}\r\n".utf8)
        let messages = try framing.append(tail)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual((messages[0]["params"] as? [String: Any])?["text"] as? String, "héllo 🌱")
        XCTAssertEqual(messages[1]["id"] as? Int, 3)
    }

    func testFramingRejectsMalformedAndOversizedMessages() throws {
        var invalid = CodexRealtimeFraming()
        XCTAssertThrowsError(try invalid.append(Data("[]\n".utf8)))
        var oversized = CodexRealtimeFraming()
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: CodexRealtimeFraming.maximumLineBytes + 1)))
        XCTAssertThrowsError(try CodexRealtimeFraming.encode(["text": String(repeating: "x", count: CodexRealtimeFraming.maximumLineBytes)]))
    }

    func testLaunchAlwaysUsesPrivateStdioAndChatGPTLogin() {
        let args = CodexRealtimeBridge.arguments
        XCTAssertFalse(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("sandbox_mode=\"read-only\""))
        XCTAssertTrue(args.contains("features.codex_hooks=false"))
        XCTAssertTrue(args.contains("features.plugin_hooks=false"))
        XCTAssertTrue(args.contains("notify=[]"))
        XCTAssertTrue(args.contains("--stdio"))
        XCTAssertTrue(args.contains("forced_login_method=\"chatgpt\""))
        XCTAssertTrue(args.contains("model_provider=\"openai\""))
        XCTAssertFalse(args.contains("--listen"))
        let clean = CodexLaunchPolicy.environment(["OPENAI_API_KEY": "synthetic-secret", "CODEX_API_KEY": "synthetic-secret", "OPENAI_BASE_URL": "https://unwanted.invalid"], home: URL(fileURLWithPath: "/tmp/test-home"))
        XCTAssertNil(clean["OPENAI_API_KEY"]); XCTAssertNil(clean["CODEX_API_KEY"]); XCTAssertNil(clean["OPENAI_BASE_URL"])
    }

    @MainActor func testProcessInitializationRequestsToolsAndStop() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let bridge = CodexRealtimeBridge(executableURL: fixture, requestTimeout: 2)
        defer { bridge.stop() }
        var notified = false
        bridge.onNotification = { method, params in
            XCTAssertEqual(method, "thread/realtime/started")
            XCTAssertEqual(params["threadId"] as? String, "synthetic-thread")
            notified = true
        }
        bridge.onServerRequest = { method, params in
            XCTAssertEqual(method, "item/tool/call")
            XCTAssertEqual(params["tool"] as? String, "kaddo_agents_status")
            return ["success": true, "contentItems": [["type": "inputText", "text": "All idle"]]]
        }
        try await bridge.start()
        let echo = try await bridge.request("echo", params: ["text": "test"])
        XCTAssertEqual(echo["text"] as? String, "test")
        XCTAssertTrue(notified)
        let dynamic = try await bridge.request("dynamic", params: [:])
        XCTAssertEqual(dynamic["success"] as? Bool, true)
        let approval = try await bridge.request("approval", params: [:])
        XCTAssertEqual(approval["decision"] as? String, "decline")
        bridge.onServerRequest = nil
        let denied = try await bridge.request("dynamic", params: [:])
        XCTAssertEqual(denied["success"] as? Bool, false)
        bridge.stop()
        do { _ = try await bridge.request("echo", params: [:]); XCTFail("Stopped bridge accepted a request") } catch {}
    }

    @MainActor func testTimeoutAndCancellationDoNotPoisonConnection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let bridge = CodexRealtimeBridge(executableURL: fixture, requestTimeout: 2)
        defer { bridge.stop() }
        try await bridge.start()
        do { _ = try await bridge.request("pending", params: [:]); XCTFail("Missing timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let task = Task { try await bridge.request("pending", params: [:]) }
        await Task.yield(); task.cancel()
        do { _ = try await task.value; XCTFail("Missing cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let echo = try await bridge.request("echo", params: ["ok": true])
        XCTAssertEqual(echo["ok"] as? Bool, true)
    }

    @MainActor func testComputerConfigurationIsIsolatedAndCleanupPreservesCredentials() async throws {
        let fixture = try makeFixture()
        let folder = fixture.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let auth = folder.appendingPathComponent("synthetic-auth.json")
        try Data("{\"fixture\":true}".utf8).write(to: auth)
        let bridge = CodexRealtimeBridge(executableURL: fixture, requestTimeout: 2, isolatedConfiguration: true, credentialsURL: auth)
        try await bridge.start()
        let privateRoot = try XCTUnwrap(bridge.workingDirectory)
        let privateHome = privateRoot.appendingPathComponent("codex-home")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: privateHome.appendingPathComponent("auth.json").path), auth.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateHome.appendingPathComponent("config.toml").path))
        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateRoot.path))
        XCTAssertEqual(try Data(contentsOf: auth), Data("{\"fixture\":true}".utf8))
    }

    @MainActor func testUnexpectedExitFailsPendingRequestAndCallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let bridge = CodexRealtimeBridge(executableURL: fixture, requestTimeout: 2)
        defer { bridge.stop() }
        let failure = expectation(description: "failure reported")
        bridge.onFailure = { message in XCTAssertTrue(message.contains("Codex voice")); failure.fulfill() }
        try await bridge.start()
        do { _ = try await bridge.request("exit", params: [:]); XCTFail("Missing exit failure") } catch {}
        await fulfillment(of: [failure], timeout: 2)
    }

    @MainActor func testWarmupPreparesOneEmptyThreadWithoutMediaOrUserTurns() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let bridge = CodexRealtimeBridge(executableURL: fixture, requestTimeout: 2)
        let warmup = CodexVoiceBackendWarmup(instructions: "Test style", bridge: bridge)
        defer { warmup.stop() }
        XCTAssertTrue(warmup.matches("Test style"))
        XCTAssertFalse(warmup.matches("Changed style"))
        let first = try await warmup.ready()
        let second = try await warmup.ready()
        XCTAssertEqual(first, "prepared-thread")
        XCTAssertEqual(first, second)
        let calls = try await bridge.request("calls", params: [:])["methods"] as? [String]
        XCTAssertEqual(calls, ["initialize", "initialized", "thread/start", "calls"])
        warmup.stop()
        XCTAssertFalse(warmup.matches("Test style"))
        XCTAssertNil(bridge.workingDirectory)
    }

    @MainActor func testRepeatedPrivateReconnectPreservesHandshakeAndResponseOwnership() async throws {
        let fixture = try makeFixture()
        let folder = fixture.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let auth = folder.appendingPathComponent("synthetic-auth.json")
        try Data("{}".utf8).write(to: auth)
        for index in 0..<12 {
            let bridge = CodexRealtimeBridge(executableURL: fixture, requestTimeout: 2, isolatedConfiguration: true, credentialsURL: auth)
            defer { bridge.stop() }
            try await bridge.start()
            let result = try await bridge.request("echo", params: ["iteration": index])
            XCTAssertEqual(result["iteration"] as? Int, index)
            bridge.stop()
        }
    }

    private func makeFixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-rpc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("fixture.py")
        let script = #"""
        #!/usr/bin/python3
        import json,sys
        pending = None
        methods = []
        def send(x):
            print(json.dumps(x), flush=True)
        for line in sys.stdin:
            m = json.loads(line)
            method = m.get('method')
            methods.append(method)
            if method == 'initialize':
                assert m['params']['capabilities']['experimentalApi'] is True
                send({'id':m['id'],'result':{'serverInfo':'fixture'}})
            elif method == 'initialized': send({'method':'thread/realtime/started','params':{'threadId':'synthetic-thread'}})
            elif method == 'thread/start':
                p=m['params']
                assert p['ephemeral'] is True and p['sandbox']=='read-only' and p['approvalPolicy']=='never'
                assert 'Test style' in p['baseInstructions'] and {t['name'] for t in p['dynamicTools']} == {'kaddo_agents_status', 'kaddo_start_agent_task', 'kaddo_screen_context', 'kaddo_computer_apps', 'kaddo_start_computer_task', 'kaddo_start_browser_task', 'kaddo_stop_computer_tasks'}
                assert 'input' not in p and 'initialItems' not in p
                send({'id':m['id'],'result':{'thread':{'id':'prepared-thread'}}})
            elif method == 'calls': send({'id':m['id'],'result':{'methods':methods}})
            elif method == 'echo': send({'id':m['id'],'result':m['params']})
            elif method in ('dynamic','approval'):
                pending = m['id']
                send({'id':700,'method':'item/tool/call' if method == 'dynamic' else 'item/commandExecution/requestApproval','params':{'tool':'kaddo_agents_status'}})
            elif method == 'exit': sys.exit(0)
            elif m.get('id') == 700:
                send({'id':pending,'result':m.get('result',{'denied':True})})
        """#
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
