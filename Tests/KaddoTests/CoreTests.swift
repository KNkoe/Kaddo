import XCTest
import Foundation
@testable import Kaddo

private final class MockProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var hold = false
    static var stopped = false
    static var captured: URLRequest?
    static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = request
        if let body = request.httpBody { Self.payload = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            Self.payload = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                Self.payload.append(buffer, count: count)
            }
        }
        guard !Self.hold else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopped = true }
}

@MainActor final class CoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var session: URLSession!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = directory.appendingPathComponent("conversations.json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        session = URLSession(configuration: config)
        MockProtocol.status = 200; MockProtocol.body = Data(); MockProtocol.hold = false
        MockProtocol.stopped = false; MockProtocol.captured = nil
    }
    override func tearDown() async throws {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
    private func makeModel() -> AppModel {
        let model = AppModel(storageURL: file, session: session, useKeychain: false)
        model.provider = "api"
        return model
    }
    private func finish(_ model: AppModel) async throws {
        for _ in 0..<200 { if !model.busy { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Request did not finish")
    }
    func testSuccessPersistenceAndNoPlaintextKey() async throws {
        MockProtocol.body = Data(#"{"choices":[{"message":{"content":"Hello back"}}]}"#.utf8)
        let model = makeModel()
        model.apiKey = "test-secret-never-persist"
        model.input = "Hello"; model.send()
        try await finish(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.selectedConversation?.messages.map(\.content), ["Hello", "Hello back"])
        XCTAssertEqual(MockProtocol.captured?.url?.path, "/v1/chat/completions")
        XCTAssertEqual(MockProtocol.captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret-never-persist")
        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(stored.contains("test-secret-never-persist"))
        let restored = makeModel()
        XCTAssertEqual(restored.selectedConversation?.messages.map(\.content), ["Hello", "Hello back"])
        XCTAssertEqual(restored.apiKey, "")
        model.newConversation()
        let second = model.selectedID
        model.selectedID = model.conversations.last?.id
        XCTAssertNotEqual(second, makeModel().selectedID)
        XCTAssertEqual(model.selectedID, makeModel().selectedID)
    }
    func testHTTPFailure() async throws {
        MockProtocol.status = 503; MockProtocol.body = Data("Unavailable".utf8)
        let model = makeModel(); model.input = "Hello"; model.send(); try await finish(model)
        XCTAssertTrue(model.error?.contains("503") == true)
        XCTAssertEqual(model.selectedConversation?.messages.count, 1)
    }
    func testMalformedAndEmptyResponses() async throws {
        for response in ["invalid JSON", #"{"choices":[]}"#, #"{"choices":[{"message":{"content":""}}]}"#] {
            MockProtocol.body = Data(response.utf8)
            let model = makeModel(); model.input = "Hello"; model.send(); try await finish(model)
            XCTAssertNotNil(model.error)
            XCTAssertFalse(model.selectedConversation?.messages.contains { $0.role == "assistant" } ?? false)
        }
    }
    func testCancellationAndDeletingActiveConversation() async throws {
        MockProtocol.hold = true
        let model = makeModel(); let active = model.selectedID!
        model.input = "Hello"; model.send()
        for _ in 0..<100 { if MockProtocol.captured != nil { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        model.newConversation()
        model.deleteConversation(active)
        XCTAssertFalse(model.busy)
        MockProtocol.hold = false
        MockProtocol.body = Data(#"{"choices":[{"message":{"content":"New reply"}}]}"#.utf8)
        model.input = "Again"; model.send(); try await finish(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.selectedConversation?.messages.last?.content, "New reply")
        XCTAssertFalse(model.conversations.contains { $0.id == active })
    }
    func testLegacyArchiveAndProviderPersistence() throws {
        let model = makeModel()
        model.provider = "codex"
        XCTAssertEqual(AppModel(storageURL: file, session: session, useKeychain: false).provider, "codex")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object.removeValue(forKey: "provider")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let legacy = AppModel(storageURL: file, session: session, useKeychain: false)
        XCTAssertEqual(legacy.provider, "codex")
        XCTAssertNil(legacy.error)
    }
    func testHelperConversationIsolation() async throws {
        MockProtocol.body = Data(#"{"choices":[{"message":{"content":"Reply"}}]}"#.utf8)
        let model = makeModel()
        model.addHelper(name: "Teacher", instructions: "TEACHER_ONLY")
        let teacher = model.selectedHelperID
        model.newConversation()
        let teacherConversation = model.selectedID
        model.addHelper(name: "Writer", instructions: "WRITER_ONLY")
        model.newConversation()
        model.selectedID = teacherConversation
        XCTAssertEqual(model.selectedConversation?.helperID, teacher)
        XCTAssertEqual(model.selectedHelperID, teacher)
        model.input = "Help"; model.send(); try await finish(model)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: MockProtocol.payload) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertTrue(messages.first?["content"]?.contains("TEACHER_ONLY") == true)
        XCTAssertFalse(messages.first?["content"]?.contains("WRITER_ONLY") == true)
        let restored = AppModel(storageURL: file, session: session, useKeychain: false)
        XCTAssertEqual(restored.helpers.count, 3)
        XCTAssertEqual(restored.selectedConversation?.helperID, teacher)
    }
    func testDeletingConversationKeepsHelperAndSendTargetAligned() async throws {
        MockProtocol.body = Data(#"{"choices":[{"message":{"content":"Reply"}}]}"#.utf8)
        let model = makeModel()
        model.addHelper(name: "Teacher", instructions: "TEACHER_ONLY")
        let teacher = model.selectedHelperID
        model.newConversation(); let firstTeacherChat = model.selectedID
        model.newConversation(); let secondTeacherChat = try XCTUnwrap(model.selectedID)
        model.addHelper(name: "Writer", instructions: "WRITER_ONLY")
        let writer = model.selectedHelperID
        model.newConversation(); let writerChat = model.selectedID
        model.selectedID = secondTeacherChat
        model.deleteConversation(secondTeacherChat)
        XCTAssertEqual(model.selectedID, firstTeacherChat)
        XCTAssertEqual(model.selectedHelperID, teacher)
        model.deleteConversation(try XCTUnwrap(firstTeacherChat))
        XCTAssertEqual(model.selectedID, writerChat)
        XCTAssertEqual(model.selectedHelperID, writer)
        model.input = "Continue the selected chat"; model.send(); try await finish(model)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: MockProtocol.payload) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertTrue(messages.first?["content"]?.contains("WRITER_ONLY") == true)
        XCTAssertFalse(messages.first?["content"]?.contains("TEACHER_ONLY") == true)
    }

    func testEndpointBoundary() {
        let model = makeModel()
        for endpoint in ["http://example.com/v1", "https://secret@example.com/v1", "https://name:password@localhost/v1", "file:///tmp/api"] {
            model.endpoint = endpoint; model.input = "Hello"; model.send()
            XCTAssertFalse(model.busy); XCTAssertNotNil(model.error)
            XCTAssertTrue(model.selectedConversation?.messages.isEmpty == true)
        }
    }
}
