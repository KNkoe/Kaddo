import AppKit
import Foundation

@MainActor protocol ComputerUseBackend: AnyObject {
    var onPermissionRequest: (([String: Any]) async -> [String: Any]?)? { get set }
    func start() async throws
    func observe(appID: String) async throws -> NativeComputerState
    func execute(appID: String, action: DesktopAction, elementIndex: Int?) async throws
    func stop()
}

struct NativeComputerState {
    let text: String
    let imageURL: String?
}

enum NativeComputerInput {
    static func scrollPages(_ delta: Int) -> Int { Int(min(UInt(10), max(UInt(1), delta.magnitude))) }
}

/// Runs the installed Codex computer-use MCP runtime in an isolated stdio process.
@MainActor final class CodexComputerBridge: ComputerUseBackend {
    var onPermissionRequest: (([String: Any]) async -> [String: Any]?)?
    private let bridge: CodexRealtimeBridge
    private let requestTimeout: TimeInterval
    private var threadID: String?
    private var screenshotScale: CGFloat = 1
    private var activeAppID: String?
    private var performingAction = false
    private var grantedAppID: String?

    init(executableURL: URL? = nil, requestTimeout: TimeInterval = 150, credentialsURL: URL? = nil) {
        self.requestTimeout = min(180, max(0.01, requestTimeout))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = "/Applications/ChatGPT.app/Contents/Resources/cua_node"
        let env = [
            "HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path,
            "CODEX_CLI_PATH": "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS": "1000",
            "NODE_REPL_NODE_PATH": root + "/bin/node", "NODE_REPL_NODE_MODULE_DIRS": root + "/lib/node_modules",
            "NODE_REPL_TRUSTED_SERVICES": #"{"sky":"@oai/sky/service"}"#,
            "NODE_REPL_TRUSTED_CODE_PATHS": root + "/lib/node_modules",
            "SKY_CUA_SERVICE_PATH": home.appendingPathComponent(".codex/computer-use/Codex Computer Use.app").path
        ]
        func literal(_ value: String) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self) }
        var args = ["-c", "mcp_servers.kaddo_computer.command=" + literal(root + "/bin/node_repl")]
        for (key, value) in env.sorted(by: { $0.key < $1.key }) { args += ["-c", "mcp_servers.kaddo_computer.env." + key + "=" + literal(value)] }
        bridge = CodexRealtimeBridge(executableURL: executableURL, requestTimeout: self.requestTimeout, toolTimeout: self.requestTimeout, isolatedConfiguration: true, credentialsURL: credentialsURL, additionalArguments: args, includeRequestErrorDetails: true, allowedServerRequests: ["mcpServer/elicitation/request"])
    }

    func start() async throws {
        guard threadID == nil else { throw ComputerBridgeError("Computer-use runtime is already running.") }
        do {
            bridge.onServerRequest = { [weak self] method, params in
                guard let self, method == "mcpServer/elicitation/request", params["serverName"] as? String == "kaddo_computer", params["threadId"] as? String == self.threadID else { return nil }
                if let app = self.activeAppID, self.grantedAppID == app, NativeComputerPermission.isAppRequest(params, appID: app) {
                    return ["action": "accept", "content": [:], "_meta": ["persist": "session"]]
                }
                // A new access dialog must not introduce a long gap after the
                // reviewed state check and then release an old input event.
                guard !self.performingAction else { return ["action": "decline"] }
                let response = await self.onPermissionRequest?(params) ?? ["action": "decline"]
                if response["action"] as? String == "accept", (response["_meta"] as? [String: Any])?["persist"] as? String == "session", let app = self.activeAppID, NativeComputerPermission.isAppRequest(params, appID: app) { self.grantedAppID = app }
                if response["action"] as? String == "accept" { await self.activateTarget() }
                return response
            }
            try await bridge.start()
            let result = try await bridge.request("thread/start", params: ["cwd": bridge.workingDirectory?.path ?? FileManager.default.temporaryDirectory.path, "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "on-request"])
            guard let id = (result["thread"] as? [String: Any])?["id"] as? String else { throw ComputerBridgeError("Codex returned no computer-use host thread.") }
            threadID = id
        } catch { stop(); throw error }
    }

    func observe(appID: String) async throws -> NativeComputerState {
        do {
        let app = try validAppID(appID)
        activeAppID = app
        await activateTarget()
        let code = #"var sky=(await import('@oai/sky')).sky; var s=await sky.get_app_state({app:APP_ID,disableDiff:true}); nodeRepl.write('KADDO_NATIVE_STATE:'+JSON.stringify({text:s.text??'',screenshot:s.screenshot?.url??null}));"#
            .replacingOccurrences(of: "APP_ID", with: jsLiteral(app))
        let response = try await callJavaScript(code, title: "Observe application")
        let output = try toolOutput(response)
        guard let marker = output.range(of: "KADDO_NATIVE_STATE:") else {
            throw ComputerBridgeError("Computer-use runtime returned no state marker.")
        }
        let json = output[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = value["text"] as? String else {
            throw ComputerBridgeError("Computer-use runtime returned malformed application state.")
        }
        let imageURL: String?
        if let source = value["screenshot"] as? String {
            imageURL = try jpegDataURL(from: source)
        } else {
            imageURL = nil
        }
        return NativeComputerState(text: text, imageURL: imageURL)
        } catch {
            stop()
            throw error
        }
    }

    func execute(appID: String, action: DesktopAction, elementIndex: Int?) async throws {
        do {
        let app = try validAppID(appID)
        activeAppID = app
        if let elementIndex, elementIndex < 0 { throw ComputerBridgeError("Element index must be nonnegative.") }
        var args: [String: Any] = ["app": app]
        let code: String
        switch action.type {
        case .click:
            if let elementIndex { args["element_index"] = elementIndex }
            else if let x = action.x, let y = action.y { args["x"] = x / screenshotScale; args["y"] = y / screenshotScale }
            else { throw ComputerBridgeError("Click needs an element index or screen coordinates.") }
            code = #"var sky=(await import('@oai/sky')).sky; await sky.click(ARGUMENTS);"#
        case .typeText:
            guard let text = action.text else { throw ComputerBridgeError("Text entry has no text.") }
            args["text"] = text
            code = #"var sky=(await import('@oai/sky')).sky; await sky.type_text(ARGUMENTS);"#
        case .key:
            guard let key = action.key else { throw ComputerBridgeError("Key action has no key.") }
            let keys = ["return": "Return", "tab": "Tab", "escape": "Escape", "space": "space", "delete": "BackSpace", "left": "Left", "right": "Right", "up": "Up", "down": "Down", "new_window": "super+n", "address_bar": "super+l"]
            guard let nativeKey = keys[key.lowercased()] else { throw ComputerBridgeError("Unsupported navigation key.") }
            args["key"] = nativeKey
            code = #"var sky=(await import('@oai/sky')).sky; await sky.press_key(ARGUMENTS);"#
        case .scroll:
            if let elementIndex { args["element_index"] = elementIndex }
            else if let x = action.x, let y = action.y { args["x"] = x / screenshotScale; args["y"] = y / screenshotScale }
            else { throw ComputerBridgeError("Scroll needs an element index or screen coordinates.") }
            let delta = action.scrollDelta ?? 0
            guard delta != 0, delta.magnitude <= 10 else { throw ComputerBridgeError("Scroll distance must be 1–10 pages.") }
            args["direction"] = delta < 0 ? "down" : "up"
            args["pages"] = NativeComputerInput.scrollPages(delta)
            code = #"var sky=(await import('@oai/sky')).sky; await sky.scroll(ARGUMENTS);"#
        case .openApp:
            throw ComputerBridgeError("Opening applications is unavailable through the computer-use runtime.")
        }
        let encodedArgs = try jsonLiteral(args)
        let rendered = code.replacingOccurrences(of: "ARGUMENTS", with: encodedArgs)
        performingAction = true
        defer { performingAction = false }
        _ = try toolOutput(await callJavaScript(rendered, title: "Perform approved action"))
        } catch {
            stop()
            throw error
        }
    }

    func stop() { threadID = nil; activeAppID = nil; grantedAppID = nil; bridge.stop() }

    private func activateTarget() async {
        guard let id = activeAppID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        _ = app.activate(from: .current, options: [.activateAllWindows])
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private func callJavaScript(_ code: String, title: String) async throws -> [String: Any] {
        guard let threadID else { throw ComputerBridgeError("Computer-use runtime is not connected.") }
        return try await bridge.request("mcpServer/tool/call", params: ["threadId": threadID, "server": "kaddo_computer", "tool": "js", "_meta": ["sessionId": threadID], "arguments": ["code": code, "title": title, "timeout_ms": Int(requestTimeout * 1000)]])
    }

    private func toolOutput(_ response: [String: Any]) throws -> String {
        if response["isError"] as? Bool == true {
            let detail = (response["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
            throw ComputerBridgeError("Computer-use tool reported an error: " + String(detail.prefix(1200)))
        }
        guard let content = response["content"] as? [[String: Any]] else {
            throw ComputerBridgeError("Computer-use tool returned malformed content.")
        }
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func jpegDataURL(from value: String) throws -> String? {
        guard let url = URL(string: value), url.isFileURL else {
            throw ComputerBridgeError("Computer-use screenshot was not a local file URL.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 32 * 1024 * 1024 else {
            throw ComputerBridgeError("Computer-use screenshot exceeded the image size limit.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else {
            throw ComputerBridgeError("Computer-use screenshot could not be decoded.")
        }
        let scale = min(1, 1440 / CGFloat(max(image.width, image.height)))
        screenshotScale = scale
        let width = max(1, Int((CGFloat(image.width) * scale).rounded(.down)))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded(.down)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ComputerBridgeError("Computer-use screenshot could not be resized.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: resized).representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            throw ComputerBridgeError("Computer-use screenshot could not be encoded.")
        }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    private func validAppID(_ value: String) throws -> String {
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw ComputerBridgeError("A valid application bundle identifier is required.")
        }
        return value
    }

    private func jsLiteral(_ value: String) -> String {
        (try? jsonLiteral(value)) ?? "''"
    }

    private func jsonLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ComputerBridgeError("Could not encode computer-use arguments.")
        }
        return json
    }

}

private struct ComputerBridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
