import XCTest
@testable import Kaddo
final class NativeComputerPermissionTests: XCTestCase {
    func testTaskScopeCannotAuthorizeAnotherAppOrAnotherConnector() {
        var request: [String: Any] = ["_meta": ["connector_id": "computer-use", "tool_params": ["app": "com.example.QA"]]]
        XCTAssertTrue(NativeComputerPermission.isAppRequest(request, appID: "com.example.QA"))
        XCTAssertFalse(NativeComputerPermission.isAppRequest(request, appID: "com.example.Other"))
        request["_meta"] = ["connector_id": "other", "tool_params": ["app": "com.example.QA"]]
        XCTAssertFalse(NativeComputerPermission.isAppRequest(request, appID: "com.example.QA"))
        XCTAssertFalse(NativeComputerPermission.isAppRequest([:], appID: "com.example.QA"))
    }
    func testOnlyPresentedChoicesCanBeAccepted() {
        let request = NativeComputerPermission(["mode": "form", "message": "Use QA app?", "requestedSchema": ["type": "object", "properties": ["scope": ["type": "string", "enum": ["once", "always"]], "confirm": ["type": "boolean"]], "required": ["scope", "confirm"]]])
        XCTAssertTrue(request.supported)
        XCTAssertEqual(request.response(allow: true, values: ["scope": "once", "confirm": true])["action"] as? String, "accept")
        XCTAssertEqual(request.response(allow: true, values: ["scope": "other", "confirm": true])["action"] as? String, "decline")
        XCTAssertEqual(request.response(allow: true, values: [:])["action"] as? String, "decline")
        XCTAssertEqual(request.response(allow: false, values: ["scope": "always", "confirm": true])["action"] as? String, "decline")
    }
    func testProtectedVerificationAndUnknownFieldsCannotBeApproved() {
        let requests: [[String: Any]] = [["mode": "openai/userVerification"], ["mode": "url"], ["mode": "form", "requestedSchema": ["properties": ["password": ["type": "string"]]]]]
        for params in requests {
            let request = NativeComputerPermission(params)
            XCTAssertFalse(request.supported)
            XCTAssertEqual(request.response(allow: true, values: [:])["action"] as? String, "decline")
        }
    }
    func testSessionRememberingRequiresOfferedScopeAndExplicitChoice() {
        let params: [String: Any] = ["mode": "form", "requestedSchema": ["type": "object", "properties": [:]], "_meta": ["persist": ["session", "always"]]]
        let request = NativeComputerPermission(params)
        XCTAssertNil(request.response(allow: true, values: [:])["_meta"])
        XCTAssertEqual((request.response(allow: true, values: [:], rememberSession: true)["_meta"] as? [String: String])?["persist"], "session")
        var restricted = params; restricted["_meta"] = [:]
        XCTAssertNil(NativeComputerPermission(restricted).response(allow: true, values: [:], rememberSession: true)["_meta"])
        restricted["_meta"] = ["persist": "session"]
        XCTAssertTrue(NativeComputerPermission(restricted).allowSession)
        restricted["_meta"] = ["persist": "always"]
        XCTAssertFalse(NativeComputerPermission(restricted).allowSession)
    }
}
