import XCTest
import SwiftUI
import AppKit
@testable import Kaddo

private final class ConnectionFixtureTransport: IntegrationTransport {
    var responses: [String] = []
    var calls: [[String]] = []
    var fails = false
    func run(arguments: [String]) async throws -> String {
        calls.append(arguments)
        if fails { throw IntegrationError.failed("Offline") }
        return responses.removeFirst()
    }
}

@MainActor final class IntegrationPresentationTests: XCTestCase {
    func testProviderStatusesNeverTreatExpiredOrUnknownAsConnected() {
        XCTAssertEqual(IntegrationHealth(status: " active "), .connected)
        for status in ["EXPIRED", "REVOKED", "FAILED"] { XCTAssertEqual(IntegrationHealth(status: status), .reconnect) }
        for status in ["INACTIVE", "DISABLED"] { XCTAssertEqual(IntegrationHealth(status: status), .disconnected) }
        for status in ["INITIATED", "INITIALIZING"] { XCTAssertEqual(IntegrationHealth(status: status), .connecting) }
        XCTAssertEqual(IntegrationHealth(status: "future-status"), .unknown)
    }
    func testIntegrationIconsUseGenericFallback() {
        XCTAssertNil(IntegrationBrand.iconURL("gmail"))
        XCTAssertNil(IntegrationBrand.iconURL("../gmail"))
        XCTAssertEqual(IntegrationBrand.name("new_app"), "New App")
    }
    func testFailedRefreshRetainsAccountsButMarksTheirStatusUnverified() async {
        let transport = ConnectionFixtureTransport()
        transport.responses = [#"{"gmail":[{"status":"ACTIVE","word_id":"personal"}]}"#]
        let store = IntegrationStore(transport: transport)
        await store.refresh()
        XCTAssertTrue(store.connectionsVerified)
        transport.fails = true
        await store.refresh()
        XCTAssertEqual(store.connections.count, 1)
        XCTAssertFalse(store.connectionsVerified)
        XCTAssertNotNil(store.connectionRefreshError)
        transport.fails = false
        transport.responses = [#"{"gmail":[{"status":"EXPIRED","word_id":"personal"}]}"#]
        await store.refresh()
        XCTAssertTrue(store.connectionsVerified)
        XCTAssertEqual(store.connections.first?.health, .reconnect)
    }
    func testExpiredAccountCannotBeUsedForActionPreview() async {
        let transport = ConnectionFixtureTransport()
        transport.responses = [#"{"gmail":[{"status":"EXPIRED","word_id":"personal"}]}"#, "schema"]
        let store = IntegrationStore(transport: transport)
        await store.refresh()
        await store.select(toolSlug: "GMAIL_FETCH_EMAILS")
        await store.preparePreview(argumentsJSON: "{}", account: "personal")
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertTrue(store.previewText.isEmpty)
        XCTAssertNotNil(store.error)
    }
    func testReconnectCreatesLinkButWaitsForExactProviderAccountToBecomeActive() async {
        let transport = ConnectionFixtureTransport()
        transport.responses = ["Open this URL\n" + #"{"connected_account_id":"fresh","redirect_url":"https://connect.composio.dev/link/test"}"#,
                               #"{"gmail":[{"status":"ACTIVE","id":"other"},{"status":"INITIATED","id":"fresh"}]}"#,
                               #"{"gmail":[{"status":"ACTIVE","id":"fresh"}]}"#]
        let store = IntegrationStore(transport: transport)
        await store.beginAuthorization(for: .init(id: "old", toolkit: "gmail", status: "EXPIRED", alias: "personal"))
        XCTAssertEqual(transport.calls[0].prefix(2), ["link", "gmail"])
        XCTAssertTrue(transport.calls[0].contains("--no-browser"))
        XCTAssertTrue(transport.calls[0].contains("--no-wait"))
        XCTAssertTrue(transport.calls[0][3].hasPrefix("kaddo-gmail-"))
        XCTAssertFalse(store.authorizedAccountIsActive)
        await store.refresh()
        XCTAssertFalse(store.authorizedAccountIsActive)
        await store.refresh()
        XCTAssertTrue(store.authorizedAccountIsActive)
        let alias = store.authorizationAlias!
        transport.responses = ["{\"gmail\":[{\"status\":\"ACTIVE\",\"word_id\":\"human-readable-id\",\"alias\":\"\(alias)\"}]}"]
        await store.refresh()
        XCTAssertEqual(store.authorizedConnection?.id, "human-readable-id")
        XCTAssertEqual(transport.calls.count, 4)
    }
    func testAuthorizationRejectsUntrustedAndMalformedLinks() throws {
        for link in ["http://connect.composio.dev/link/x", "https://composio.dev.evil.test/link/x", "https://evil.test", "https://user@connect.composio.dev/link/x", "file:///tmp/x"] {
            let object = ["connected_account_id": "test", "redirect_url": link]
            let output = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertThrowsError(try IntegrationAuthorization.parse(output))
        }
        XCTAssertThrowsError(try IntegrationAuthorization.parse("An account already exists"))
    }
    func testCardsRenderAllStatesAtNarrowWidth() throws {
        let content = VStack(spacing: 12) {
            ForEach(Array(["ACTIVE", "EXPIRED", "INACTIVE", "INITIATED", "FUTURE"].enumerated()), id: \.offset) { index, status in
                IntegrationAccountCard(item: .init(id: "fixture-\(index)", toolkit: index.isMultiple(of: 2) ? "gmail" : "github", status: status, alias: "Example account"), selected: index == 0, verified: true, busy: false, select: {}, reconnect: {})
            }
            IntegrationAccountCard(item: .init(id: "stale", toolkit: "figma", status: "ACTIVE", alias: "Example account"), selected: true, verified: false, busy: false, select: {}, reconnect: {})
        }.padding(20).frame(width: 380).background(Color(white: 0.08)).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertGreaterThan(bitmap.pixelsHigh, 1000)
        if let directory = ProcessInfo.processInfo.environment["KADDO_INTEGRATIONS_QA_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("connection-states.png"))
        }
    }
}
