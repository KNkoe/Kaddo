import Foundation

/// A private stdio connection to the installed Codex. Authentication stays in Codex.
@MainActor final class CodexRealtimeBridge {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    var onServerRequest: ((String, [String: Any]) async -> [String: Any]?)?

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var directory: URL?
    private var framing = CodexRealtimeFraming()
    private var generation = UUID()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var serverTasks: [UUID: Task<Void, Never>] = [:]
    private var serverDeadlines: [UUID: Task<Void, Never>] = [:]
    private let executableOverride: URL?
    private let requestTimeout: TimeInterval
    private let toolTimeout: TimeInterval
    private let isolatedConfiguration: Bool
    private let credentialsURL: URL?
    private let additionalArguments: [String]
    private let includeRequestErrorDetails: Bool
    private let allowedServerRequests: Set<String>
    var workingDirectory: URL? { directory }

    init(executableURL: URL? = nil, requestTimeout: TimeInterval = 45, toolTimeout: TimeInterval = 45, isolatedConfiguration: Bool = false, credentialsURL: URL? = nil, additionalArguments: [String] = [], includeRequestErrorDetails: Bool = false, allowedServerRequests: Set<String> = ["item/tool/call"]) {
        executableOverride = executableURL
        self.requestTimeout = max(0.01, requestTimeout)
        self.toolTimeout = min(180, max(0.01, toolTimeout))
        self.isolatedConfiguration = isolatedConfiguration
        self.credentialsURL = credentialsURL
        self.additionalArguments = additionalArguments
        self.includeRequestErrorDetails = includeRequestErrorDetails
        self.allowedServerRequests = allowedServerRequests
    }

    deinit {
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close(); try? output?.close()
        if let process, process.isRunning { process.terminate() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    nonisolated static var arguments: [String] {
        ["app-server", "--stdio",
         "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\"",
         "-c", "approval_policy=\"never\"", "-c", "sandbox_mode=\"read-only\"",
         "-c", "features.codex_hooks=false", "-c", "features.hooks=false",
         "-c", "features.plugin_hooks=false", "-c", "features.plugins=false",
         "-c", "features.apps=false", "-c", "features.shell_tool=false", "-c", "notify=[]", "-c", "web_search=\"live\""]
    }

    func start() async throws {
        guard process == nil else { throw CodexRealtimeError("Codex voice connection is already running.") }
        try Task.checkCancellation()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let executable = executableOverride ?? [home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let executable else { throw CodexRealtimeError("Install Codex CLI and sign in with ChatGPT to use Codex voice.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-realtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = folder
        let runner = Process(), stdin = Pipe(), stdout = Pipe()
        let token = UUID(); generation = token; framing = CodexRealtimeFraming()
        runner.executableURL = executable
        runner.arguments = Self.arguments + additionalArguments
        runner.currentDirectoryURL = folder
        runner.environment = CodexLaunchPolicy.environment(ProcessInfo.processInfo.environment, home: home)
        if isolatedConfiguration {
            // Reuse the existing sign-in without loading user MCP servers, project
            // plugins or hooks that could give an agent unmediated desktop access.
            let authHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            let privateHome = folder.appendingPathComponent("codex-home", isDirectory: true)
            try FileManager.default.createDirectory(at: privateHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let credentials = credentialsURL ?? authHome.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: credentials.path) else { stop(); throw CodexRealtimeError("Computer agents need the existing Codex ChatGPT file sign-in. Run codex login, then try again.") }
            try FileManager.default.createSymbolicLink(at: privateHome.appendingPathComponent("auth.json"), withDestinationURL: credentials)
            runner.environment?["CODEX_HOME"] = privateHome.path
        }
        runner.standardInput = stdin; runner.standardOutput = stdout
        // Never forward authentication or transcript-bearing diagnostics to the UI.
        runner.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; process = runner
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if data.isEmpty { self.fail("Codex voice connection closed.") }
                else { self.receive(data) }
            }
        }
        runner.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.fail("Codex voice process exited. Check your Codex ChatGPT sign-in and try again.")
            }
        }
        do {
            try runner.run()
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "kaddo", "title": "Kaddo", "version": "1.0"],
                "capabilities": ["experimentalApi": true]
            ])
            try notify("initialized")
        } catch { stop(); throw error }
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw CodexRealtimeError("Codex voice is not connected.") }
        nextID += 1; let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                let nanoseconds = UInt64(min(requestTimeout, 3600) * 1_000_000_000)
                deadlines[id] = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
                    self?.finish(id, result: .failure(CodexRealtimeError("Codex voice request timed out.")))
                }
                do { try send(["id": id, "method": method, "params": params]) }
                catch { finish(id, result: .failure(error)) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.finish(id, result: .failure(CancellationError())) }
        }
    }

    func notify(_ method: String, params: [String: Any] = [:]) throws {
        try send(["method": method, "params": params])
    }

    func stop() {
        generation = UUID()
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil
        if let runner = process, runner.isRunning {
            runner.terminate()
            // A non-cooperating child must not survive the voice session.
            Task.detached {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if runner.isRunning { kill(runner.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        serverTasks.values.forEach { $0.cancel() }; serverTasks.removeAll()
        serverDeadlines.values.forEach { $0.cancel() }; serverDeadlines.removeAll()
        for id in Array(pending.keys) { finish(id, result: .failure(CancellationError())) }
        framing = CodexRealtimeFraming()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func send(_ value: [String: Any]) throws {
        guard process?.isRunning == true, let input else { throw CodexRealtimeError("Codex voice is not connected.") }
        let data = try CodexRealtimeFraming.encode(value)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        do {
            for message in try framing.append(data) {
                if let method = message["method"] as? String {
                    if let id = message["id"] {
                        handleServerRequest(id: id, method: method, params: message["params"] as? [String: Any] ?? [:])
                    } else {
                        onNotification?(method, message["params"] as? [String: Any] ?? [:])
                    }
                } else if let id = message["id"] as? Int {
                    if let error = message["error"] as? [String: Any] {
                        let code = error["code"] as? Int ?? -1
                        let detail = includeRequestErrorDetails ? ": " + String((error["message"] as? String ?? "").prefix(1200)) : "."
                        finish(id, result: .failure(CodexRealtimeError("Codex request failed (\(code))" + detail)))
                    } else if let result = message["result"] as? [String: Any] {
                        finish(id, result: .success(result))
                    } else if message["result"] is NSNull {
                        finish(id, result: .success([:]))
                    } else {
                        finish(id, result: .failure(CodexRealtimeError("Codex voice returned an invalid response.")))
                    }
                }
            }
        } catch { fail("Codex voice returned an invalid or oversized protocol message.") }
    }

    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        // Only explicitly supplied dynamic tools can reach the caller. All approvals
        // and authentication requests remain unavailable to spoken model output.
        guard allowedServerRequests.contains(method), let callback = onServerRequest else {
            replyToServer(id: id, method: method, result: nil)
            return
        }
        let key = UUID(), token = generation
        serverTasks[key] = Task { @MainActor [weak self] in
            let result = await callback(method, params)
            guard let self, self.generation == token, self.serverTasks.removeValue(forKey: key) != nil else { return }
            self.serverDeadlines.removeValue(forKey: key)?.cancel()
            self.replyToServer(id: id, method: method, result: result)
        }
        serverDeadlines[key] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64((self?.toolTimeout ?? 45) * 1_000_000_000)) } catch { return }
            guard let self, self.generation == token, let task = self.serverTasks.removeValue(forKey: key) else { return }
            task.cancel(); self.serverDeadlines.removeValue(forKey: key)
            self.replyToServer(id: id, method: method, result: nil)
        }
    }

    private func replyToServer(id: Any, method: String, result: [String: Any]?) {
        do {
            if let result { try send(["id": id, "result": result]) }
            else if method == "item/tool/call" {
                try send(["id": id, "result": ["contentItems": [["type": "inputText", "text": "This tool is unavailable in Kaddo voice."]], "success": false]])
            } else if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                try send(["id": id, "result": ["decision": "decline"]])
            } else {
                try send(["id": id, "error": ["code": -32601, "message": "Kaddo voice does not support this server request."]])
            }
        } catch { fail("Codex voice connection could not send a response.") }
    }

    private func finish(_ id: Int, result: Result<[String: Any], Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func fail(_ message: String) {
        guard process != nil else { return }
        // Preserve the failure reason for all callers before cleanup cancels leftovers.
        for id in Array(pending.keys) { finish(id, result: .failure(CodexRealtimeError(message))) }
        stop()
        onFailure?(message)
    }
}

struct CodexRealtimeFraming {
    static let maximumLineBytes = 2 * 1024 * 1024
    private var buffer = Data()

    static func encode(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw CodexRealtimeError("Invalid Codex voice request.") }
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= maximumLineBytes else { throw CodexRealtimeError("Codex voice message is too large.") }
        data.append(10)
        return data
    }

    mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 10) {
            let length = buffer.distance(from: buffer.startIndex, to: newline)
            guard length <= Self.maximumLineBytes else { throw CodexRealtimeError("Codex voice message is too large.") }
            let line = buffer.prefix(upTo: newline)
            if !line.isEmpty {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexRealtimeError("Invalid Codex voice message.")
                }
                messages.append(object)
            }
            buffer.removeSubrange(...newline)
        }
        guard buffer.count <= Self.maximumLineBytes else { throw CodexRealtimeError("Codex voice message is too large.") }
        return messages
    }
}

private struct CodexRealtimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
