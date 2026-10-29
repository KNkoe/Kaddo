import XCTest
@testable import Kaddo

private final class MockIntegrationTransport: IntegrationTransport {
    var calls: [[String]] = []
    var outputs: [String] = []
    var failure: Error?
    func run(arguments: [String]) async throws -> String {
        calls.append(arguments)
        if let failure { throw failure }
        return outputs.isEmpty ? "{}" : outputs.removeFirst()
    }
}
@MainActor final class IntegrationTests: XCTestCase {
    func testActualCLISearchPlanShape() throws {
        let output = #"{"results":[{"use_case":"list calendars","primary_tool_slugs":["GOOGLECALENDAR_LIST_CALENDARS"],"related_tool_slugs":["GOOGLECALENDAR_GET_CALENDAR"]}],"tool_schemas":{"primary":{"GOOGLECALENDAR_LIST_CALENDARS":"/cache/schema.json"}}}"#
        let tools = try IntegrationStore.parseTools(output)
        XCTAssertEqual(Set(tools.map(\.slug)), ["GOOGLECALENDAR_LIST_CALENDARS", "GOOGLECALENDAR_GET_CALENDAR"])
        XCTAssertEqual(tools.first(where: { $0.slug == "GOOGLECALENDAR_LIST_CALENDARS" })?.name, "List Calendars")
    }
    func testActualCLIKeyedConnectionShape() throws {
        let output = #"{"gmail":[{"status":"ACTIVE","alias":null,"word_id":"synthetic-gmail"}],"github":[{"status":"ACTIVE","word_id":"synthetic-github"}]}"#
        let connections = try IntegrationStore.parseConnections(output)
        XCTAssertEqual(Set(connections.map(\.toolkit)), ["gmail", "github"])
        XCTAssertEqual(Set(connections.map(\.id)), ["synthetic-gmail", "synthetic-github"])
    }
    func testSchemaDrivenFieldsAndEncoding() throws {
        let schema = #"{"input_schema":{"type":"object","required":["recipient_email","max_results","enabled"],"properties":{"recipient_email":{"type":"string","title":"Recipient","description":"Who receives this"},"max_results":{"type":"integer"},"enabled":{"type":"boolean"},"ratio":{"type":"number"},"labels":{"type":"array","items":{"type":"string"}},"priority":{"type":"string","enum":["low","high"],"default":"low"}}}}"#
        let fields = try XCTUnwrap(IntegrationForm.fields(from: schema))
        XCTAssertEqual(fields.first(where: { $0.key == "recipient_email" })?.label, "Recipient")
        XCTAssertEqual(fields.first(where: { $0.key == "enabled" })?.initialValue, "false")
        XCTAssertEqual(fields.first(where: { $0.key == "labels" })?.isSimple, false)
        let json = try IntegrationForm.encode(fields: fields, values: ["recipient_email": "test@example.test", "max_results": "3", "enabled": "true", "ratio": "1.25"], advancedJSON: #"{"labels":["work"]}"#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["recipient_email"] as? String, "test@example.test")
        XCTAssertEqual(object["max_results"] as? Int, 3)
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["ratio"] as? Double, 1.25)
        XCTAssertEqual(object["labels"] as? [String], ["work"])
        XCTAssertEqual(object["priority"] as? String, "low")
    }
    func testFormValidationAndUnknownSchema() throws {
        XCTAssertNil(IntegrationForm.fields(from: "unavailable"))
        XCTAssertNil(IntegrationForm.fields(from: #"{"message":"unknown schema"}"#))
        let fields = try XCTUnwrap(IntegrationForm.fields(from: #"{"properties":{"count":{"type":"integer"},"nested":{"type":"object"}},"required":["count","nested"]}"#))
        XCTAssertThrowsError(try IntegrationForm.encode(fields: fields, values: [:], advancedJSON: "{}"))
        XCTAssertThrowsError(try IntegrationForm.encode(fields: fields, values: ["count":"1.5"], advancedJSON: #"{"nested":{}}"#))
        XCTAssertThrowsError(try IntegrationForm.encode(fields: fields, values: ["count":"1"], advancedJSON: "{}"))
        XCTAssertThrowsError(try IntegrationForm.encode(fields: fields, values: ["count":"1"], advancedJSON: "[]"))
        let json = try IntegrationForm.encode(fields: fields, values: ["count":"2"], advancedJSON: #"{"count":99,"nested":{"key":"value"}}"#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["count"] as? Int, 2)
    }
    func testNestedConnectionAndToolDiscovery() throws {
        let accounts = try IntegrationStore.parseConnections(#"{"items":[{"id":"ca_1","toolkit":{"slug":"gmail"},"status":"ACTIVE","alias":"work"}]}"#)
        XCTAssertEqual(accounts, [.init(id: "ca_1", toolkit: "gmail", status: "ACTIVE", alias: "work")])
        let tools = try IntegrationStore.parseTools(#"{"results":[{"tools":[{"slug":"GMAIL_FETCH_EMAILS","name":"Fetch emails","description":"Mail"},{"slug":"invalid"}]}]}"#)
        XCTAssertEqual(tools.map(\.slug), ["GMAIL_FETCH_EMAILS"])
    }
    func testApprovalIsRequiredAndConsumedBeforeExecution() async {
        let mock = MockIntegrationTransport(); mock.outputs = ["schema", "validated", "result"]
        let store = IntegrationStore(transport: mock)
        await store.executeApproved()
        XCTAssertTrue(mock.calls.isEmpty)
        await store.select(toolSlug: "GMAIL_SEND_EMAIL")
        await store.preparePreview(argumentsJSON: #"{"body":"a; $(touch /tmp/nope)","recipient_email":"person@example.test"}"#, account: "work")
        XCTAssertEqual(mock.calls.count, 2)
        XCTAssertTrue(mock.calls[1].contains("--dry-run"))
        XCTAssertTrue(mock.calls[1].contains("work"))
        XCTAssertTrue(store.previewText.contains("person@example.test"))
        await store.executeApproved()
        XCTAssertEqual(mock.calls.count, 3)
        XCTAssertFalse(mock.calls[2].contains("--dry-run"))
        XCTAssertEqual(store.resultText, "result")
        XCTAssertTrue(store.previewText.isEmpty)
        await store.executeApproved()
        XCTAssertEqual(mock.calls.count, 3)
    }
    func testInvalidJSONAndInvalidatedPreviewNeverExecute() async {
        let mock = MockIntegrationTransport(); mock.outputs = ["schema", "preview"]
        let store = IntegrationStore(transport: mock)
        await store.select(toolSlug: "GITHUB_CREATE_AN_ISSUE")
        await store.preparePreview(argumentsJSON: "[]")
        XCTAssertEqual(mock.calls.count, 1)
        await store.preparePreview(argumentsJSON: "{}")
        store.invalidatePreview()
        await store.executeApproved()
        XCTAssertEqual(mock.calls.count, 2)
        await store.select(toolSlug: "; rm -rf")
        XCTAssertEqual(mock.calls.count, 2)
    }
    func testFailedNewExecutionDoesNotExposePreviousResult() async {
        let mock = MockIntegrationTransport()
        mock.outputs = ["schema", "preview", "old result", "new preview"]
        let store = IntegrationStore(transport: mock)
        await store.select(toolSlug: "GMAIL_FETCH_EMAILS")
        await store.preparePreview(argumentsJSON: "{}")
        await store.executeApproved()
        XCTAssertEqual(store.resultText, "old result")
        await store.preparePreview(argumentsJSON: "{\"max_results\":2}")
        mock.failure = IntegrationError.failed("Provider unavailable")
        await store.executeApproved()
        XCTAssertTrue(store.resultText.isEmpty)
        XCTAssertNotNil(store.error)
    }
    func testCLIAuthFailureIsVisible() async {
        let mock = MockIntegrationTransport(); mock.failure = IntegrationError.failed("Invalid or revoked user API key")
        let store = IntegrationStore(transport: mock)
        await store.refresh()
        XCTAssertEqual(store.error, "Invalid or revoked user API key")
        XCTAssertTrue(store.connections.isEmpty)
    }
    func testRealProcessFailureAndTimeout() async throws {
        let errorCLI = ComposioTransport(executable: URL(fileURLWithPath: "/usr/bin/false"), timeout: 1)
        do { _ = try await errorCLI.run(arguments: []); XCTFail("Expected failure") } catch {}
        let slowCLI = ComposioTransport(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: 0.05)
        do { _ = try await slowCLI.run(arguments: ["3"]); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error.localizedDescription, IntegrationError.timedOut.localizedDescription) }
    }
    func testRealProcessCancellationAndBoundedOutput() async throws {
        let slowCLI = ComposioTransport(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: 10)
        let task = Task { try await slowCLI.run(arguments: ["5"]) }
        try await Task.sleep(nanoseconds: 30_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let echo = ComposioTransport(executable: URL(fileURLWithPath: "/bin/echo"))
        let output = try await echo.run(arguments: ["literal;$(whoami)"])
        XCTAssertEqual(output, "literal;$(whoami)\n")
        let large = ComposioTransport(executable: URL(fileURLWithPath: "/usr/bin/python3"))
        do { _ = try await large.run(arguments: ["-c", "print('x' * 600000)"]); XCTFail("Expected bounded output failure") }
        catch { XCTAssertEqual(error.localizedDescription, IntegrationError.outputLimit.localizedDescription) }
    }
}
