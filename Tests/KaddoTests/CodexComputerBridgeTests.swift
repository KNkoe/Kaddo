import Foundation
import XCTest
@testable import Kaddo

final class CodexComputerBridgeTests: XCTestCase {
    @MainActor func testNativePermissionRequestIsForwardedThroughHost() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let bridge = CodexComputerBridge(executableURL: fixture.executable, requestTimeout: 2, credentialsURL: fixture.credentials)
        defer { bridge.stop() }
        var requested = 0
        bridge.onPermissionRequest = { params in
            requested += 1
            XCTAssertEqual(params["message"] as? String, "Use QA?")
            return ["action": "accept", "content": [:], "_meta": ["persist": "session"]]
        }
        try await bridge.start()
        _ = try await bridge.observe(appID: "com.example.Permission")
        _ = try await bridge.observe(appID: "com.example.Permission")
        XCTAssertEqual(requested, 1)
        bridge.stop()
        try await bridge.start()
        _ = try await bridge.observe(appID: "com.example.Permission")
        XCTAssertEqual(requested, 2)
    }
    @MainActor func testInitializeObserveAndExecuteUseMCPRuntime() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let bridge = CodexComputerBridge(executableURL: fixture.executable, requestTimeout: 2, credentialsURL: fixture.credentials)
        defer { bridge.stop() }

        try await bridge.start()
        let state = try await bridge.observe(appID: "com.example.Editor")
        XCTAssertEqual(state.text, "Window: Editor")
        XCTAssertNil(state.imageURL)

        let input = "hello 'quoted' \"text\"\n); nodeRepl.write('injected')"
        try await bridge.execute(appID: "com.example.Editor", action: DesktopAction(type: .typeText, text: input), elementIndex: nil)
        try await bridge.execute(appID: "com.example.Editor", action: DesktopAction(type: .key, key: "return"), elementIndex: nil)
        try await bridge.execute(appID: "com.example.Editor", action: DesktopAction(type: .click), elementIndex: 3)
        try await bridge.execute(appID: "com.example.Editor", action: DesktopAction(type: .scroll, scrollDelta: -2), elementIndex: 7)

        let lines = try String(contentsOf: fixture.calls, encoding: .utf8).split(separator: "\n")
        let calls = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let observe = try XCTUnwrap(calls.first { ($0["title"] as? String) == "Observe application" })
        let observeCode = try XCTUnwrap(observe["code"] as? String)
        XCTAssertTrue(observeCode.contains("com.example.Editor"))
        let execute = try XCTUnwrap(calls.first { ($0["title"] as? String) == "Perform approved action" })
        let executeCode = try XCTUnwrap(execute["code"] as? String)
        let encodedText = try String(decoding: JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed]), as: UTF8.self)
        XCTAssertTrue(executeCode.contains("\"text\":\(encodedText)"))
        let codes = calls.compactMap { $0["code"] as? String }.joined(separator: "\n")
        XCTAssertTrue(codes.contains("\"key\":\"Return\""))
        XCTAssertTrue(codes.contains("\"element_index\":3"))
        XCTAssertTrue(codes.contains("\"direction\":\"down\",\"element_index\":7,\"pages\":2"))
    }

    @MainActor func testToolErrorAndMalformedStateAreReported() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let bridge = CodexComputerBridge(executableURL: fixture.executable, requestTimeout: 2, credentialsURL: fixture.credentials)
        defer { bridge.stop() }
        try await bridge.start()

        do {
            _ = try await bridge.observe(appID: "com.example.Malformed")
            XCTFail("Expected malformed state to fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("malformed application state")) }

        let errorBridge = CodexComputerBridge(executableURL: fixture.executable, requestTimeout: 2, credentialsURL: fixture.credentials)
        defer { errorBridge.stop() }
        try await errorBridge.start()
        do {
            try await errorBridge.execute(appID: "com.example.Editor", action: DesktopAction(type: .typeText, text: "TOOL_ERROR"), elementIndex: nil)
            XCTFail("Expected an MCP tool error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("reported an error")) }
    }

    @MainActor func testTimeoutAndStopSettlePendingRequests() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let bridge = CodexComputerBridge(executableURL: fixture.executable, requestTimeout: 2, credentialsURL: fixture.credentials)
        try await bridge.start()

        do {
            try await bridge.execute(appID: "com.example.Editor", action: DesktopAction(type: .typeText, text: "TIMEOUT"), elementIndex: nil)
            XCTFail("Expected a request timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let stopFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: stopFixture.folder) }
        let stoppable = CodexComputerBridge(executableURL: stopFixture.executable, requestTimeout: 2, credentialsURL: stopFixture.credentials)
        try await stoppable.start()
        let task = Task { @MainActor in
            try await stoppable.execute(appID: "com.example.Editor", action: DesktopAction(type: .typeText, text: "TIMEOUT"), elementIndex: nil)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        stoppable.stop()
        do { try await task.value; XCTFail("Expected stop to settle the pending request") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testInvalidAppAndUnsupportedOpenAppDoNotCallRuntime() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let bridge = CodexComputerBridge(executableURL: fixture.executable, requestTimeout: 2, credentialsURL: fixture.credentials)
        defer { bridge.stop() }
        try await bridge.start()

        do { _ = try await bridge.observe(appID: "bad;app"); XCTFail("Expected invalid app id") } catch {}
        do {
            try await bridge.execute(appID: "com.example.Editor", action: DesktopAction(type: .openApp, appID: "com.example.Other"), elementIndex: nil)
            XCTFail("Expected unsupported openApp")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
        XCTAssertTrue(try String(contentsOf: fixture.calls, encoding: .utf8).isEmpty)
    }

    private func makeFixture() throws -> (folder: URL, executable: URL, calls: URL, credentials: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-computer-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let executable = folder.appendingPathComponent("fixture.py")
        let calls = folder.appendingPathComponent("calls.jsonl")
        let script = #"""
        #!/usr/bin/python3
        import json,sys
        assert any(a.startswith('mcp_servers.kaddo_computer.command="/Applications/') for a in sys.argv[2:])
        assert all('\\/' not in a for a in sys.argv[2:])
        log = open(sys.argv[1], 'a', buffering=1)
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get('method')
            if method == 'initialize':
                assert message['params']['clientInfo']['name'] == 'kaddo'
                send({'jsonrpc':'2.0','id':message['id'],'result':{}})
            elif method == 'initialized': pass
            elif method == 'thread/start':
                assert message['params']['approvalPolicy']=='on-request'
                send({'jsonrpc':'2.0','id':message['id'],'result':{'thread':{'id':'native-host'}}})
            elif method == 'mcpServer/tool/call':
                assert message['params']['server'] == 'kaddo_computer'
                assert message['params']['threadId'] == 'native-host'
                assert message['params']['tool'] == 'js'
                assert message['params']['_meta']['sessionId'] == 'native-host'
                arguments = message['params']['arguments']
                log.write(json.dumps(arguments, ensure_ascii=False) + '\n')
                code = arguments['code']
                if 'com.example.Permission' in code:
                    send({'id':900,'method':'mcpServer/elicitation/request','params':{'serverName':'kaddo_computer','threadId':'native-host','mode':'form','message':'Use QA?','_meta':{'connector_id':'computer-use','tool_params':{'app':'com.example.Permission'},'persist':['session']},'requestedSchema':{'type':'object','properties':{}}}})
                    reply=json.loads(sys.stdin.readline())
                    assert reply['id']==900 and reply['result']['action']=='accept'
                if 'TIMEOUT' in code: continue
                if 'TOOL_ERROR' in code:
                    result = {'content':[{'type':'text','text':'failure'}], 'isError':True}
                elif 'KADDO_NATIVE_STATE' in code and 'com.example.Malformed' in code:
                    result = {'content':[{'type':'text','text':'KADDO_NATIVE_STATE:{broken'}]}
                elif 'KADDO_NATIVE_STATE' in code:
                    result = {'content':[{'type':'text','text':'KADDO_NATIVE_STATE:{\"text\":\"Window: Editor\",\"screenshot\":null}'}]}
                else: result = {'content':[{'type':'text','text':'action complete'}]}
                send({'jsonrpc':'2.0','id':message['id'],'result':result})
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let wrapper = folder.appendingPathComponent("runtime")
        let wrapperScript = "#!/bin/sh\nexec /usr/bin/python3 \"\(executable.path)\" \"\(calls.path)\" \"$@\"\n"
        try Data(wrapperScript.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let credentials = folder.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: credentials)
        return (folder, wrapper, calls, credentials)
    }
}
