import XCTest
@testable import Kaddo

final class CodexLaunchPolicyTests: XCTestCase {
    func testLiveWebSearchIsExplicitForChatAndBackground() {
        let root = URL(fileURLWithPath: "/tmp/web-test")
        for background in [false, true] {
            XCTAssertTrue(CodexLaunchPolicy.arguments(workspace: root, output: root, background: background).contains("web_search=\"live\""))
        }
        XCTAssertTrue(CodexRealtimeBridge.arguments.contains("web_search=\"live\""))
    }
    func testSubscriptionLaunchCannotSelectAPIProviderOrBroadenWriteRoot() {
        let root = URL(fileURLWithPath: "/tmp/synthetic helper")
        let output = URL(fileURLWithPath: "/tmp/reply.txt")
        let args = CodexLaunchPolicy.arguments(workspace: root, output: output, background: true)
        XCTAssertTrue(args.contains("forced_login_method=\"chatgpt\""))
        XCTAssertTrue(args.contains("model_provider=\"openai\""))
        XCTAssertTrue(args.contains("approval_policy=\"never\""))
        XCTAssertEqual(args[try! XCTUnwrap(args.firstIndex(of: "--sandbox")) + 1], "workspace-write")
        XCTAssertEqual(args[try! XCTUnwrap(args.firstIndex(of: "-C")) + 1], root.path)
        XCTAssertFalse(args.contains("--add-dir"))
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("--ephemeral"))
    }

    func testAPIEnvironmentRemovedWithoutReplacingExistingCodexLoginHome() {
        let input = ["OPENAI_API_KEY": "synthetic", "CODEX_API_KEY": "synthetic",
                     "OPENAI_BASE_URL": "http://example.invalid", "OPENAI_API_BASE": "http://example.invalid",
                     "OPENAI_ORG_ID": "synthetic", "OPENAI_ORGANIZATION": "synthetic", "OPENAI_PROJECT_ID": "synthetic",
                     "CODEX_HOME": "/tmp/synthetic-codex-home", "HOME": "/tmp/synthetic-home", "LANG": "en_US.UTF-8"]
        let result = CodexLaunchPolicy.environment(input, home: URL(fileURLWithPath: "/tmp/synthetic-home"))
        for key in input.keys where key.hasPrefix("OPENAI_") || key == "CODEX_API_KEY" { XCTAssertNil(result[key]) }
        XCTAssertEqual(result["CODEX_HOME"], input["CODEX_HOME"])
        XCTAssertEqual(result["HOME"], input["HOME"])
        XCTAssertEqual(result["LANG"], input["LANG"])
    }

    func testDedicatedVerifierIsAvailableOnlyForSandboxedBackgroundJobs() throws {
        let root = URL(fileURLWithPath: "/tmp/verification workspace")
        let background = CodexLaunchPolicy.arguments(workspace: root, output: root, background: true)
        let chat = CodexLaunchPolicy.arguments(workspace: root, output: root, background: false)
        XCTAssertTrue(background.contains("mcp_servers.kaddo_verifier.command=\"/usr/bin/python3\""))
        let configured = try XCTUnwrap(background.first { $0.hasPrefix("mcp_servers.kaddo_verifier.args=") })
        let value = String(configured.dropFirst("mcp_servers.kaddo_verifier.args=".count))
        let args = try JSONDecoder().decode([String].self, from: Data(value.utf8))
        XCTAssertEqual(args.first, "-I")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(args.last)))
        XCTAssertFalse(configured.contains("\\/")) // TOML does not accept JSON's escaped slash.
        XCTAssertFalse(chat.contains { $0.contains("mcp_servers.kaddo_verifier") })
        XCTAssertFalse(background.contains { $0.contains("network_access=true") })
        XCTAssertTrue(background.contains("mcp_servers.kaddo_verifier.tools.verify_task.approval_mode=\"approve\""))
        XCTAssertTrue(background.contains("mcp_servers.kaddo_verifier.enabled_tools=[\"verify_task\"]"))
        XCTAssertFalse(background.contains("mcp_servers.kaddo_verifier.default_tools_approval_mode=\"approve\""))
    }

    func testChatKeepsReadOnlySandbox() {
        let args = CodexLaunchPolicy.arguments(workspace: URL(fileURLWithPath: "/tmp/chat"), output: URL(fileURLWithPath: "/tmp/reply"), background: false)
        XCTAssertEqual(args[try! XCTUnwrap(args.firstIndex(of: "--sandbox")) + 1], "read-only")
    }
}
