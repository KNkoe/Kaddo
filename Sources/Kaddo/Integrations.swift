import Foundation
import Combine
import Darwin

struct IntegrationConnection: Identifiable, Equatable {
    let id: String
    let toolkit: String
    let status: String
    let alias: String
}
struct IntegrationTool: Identifiable, Equatable {
    var id: String { slug }
    let slug: String
    let name: String
    let description: String
}
struct IntegrationField: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let label: String
    let description: String
    let type: String
    let required: Bool
    let choices: [String]
    let initialValue: String
    var isSimple: Bool { ["string", "boolean", "integer", "number"].contains(type) }
}
enum IntegrationForm {
    static func fields(from text: String) -> [IntegrationField]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        func schema(_ value: Any) -> [String: Any]? {
            guard let dict = value as? [String: Any] else { return nil }
            if dict["properties"] is [String: Any] { return dict }
            for key in ["input_schema", "inputSchema", "input_parameters", "parameters", "schema", "tool", "data"] {
                if let child = dict[key], let match = schema(child) { return match }
            }
            return nil
        }
        guard let selected = schema(object), let properties = selected["properties"] as? [String: Any] else { return nil }
        let required = Set(selected["required"] as? [String] ?? [])
        return properties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }.map { key in
            let item = properties[key] as? [String: Any] ?? [:]
            let type = (item["type"] as? String) ?? (item["type"] as? [String])?.first(where: { $0 != "null" }) ?? "object"
            let label = (item["title"] as? String) ?? key.replacingOccurrences(of: "_", with: " ").capitalized
            let initial: String
            if let value = item["default"] as? String { initial = value }
            else if let value = item["default"] as? NSNumber { initial = type == "boolean" ? (value.boolValue ? "true" : "false") : value.stringValue }
            else { initial = type == "boolean" && required.contains(key) ? "false" : "" }
            return IntegrationField(key: key, label: label, description: item["description"] as? String ?? "", type: type, required: required.contains(key), choices: item["enum"] as? [String] ?? [], initialValue: initial)
        }
    }
    static func encode(fields: [IntegrationField], values: [String: String], advancedJSON: String) throws -> String {
        guard let extra = try? JSONSerialization.jsonObject(with: Data(advancedJSON.utf8)), var result = extra as? [String: Any] else { throw IntegrationError.invalidJSON }
        for field in fields where field.isSimple {
            let value = values[field.key] ?? field.initialValue
            if value.isEmpty {
                if field.required, result[field.key] == nil { throw IntegrationError.failed("Enter \(field.label).") }
                continue
            }
            switch field.type {
            case "boolean":
                guard ["true", "false"].contains(value) else { throw IntegrationError.failed("Choose Yes or No for \(field.label).") }
                result[field.key] = value == "true"
            case "integer":
                guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw IntegrationError.failed("\(field.label) must be a whole number.") }
                result[field.key] = number
            case "number":
                guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { throw IntegrationError.failed("\(field.label) must be a valid number.") }
                result[field.key] = number
            default:
                guard field.choices.isEmpty || field.choices.contains(value) else { throw IntegrationError.failed("Choose a listed value for \(field.label).") }
                result[field.key] = value
            }
        }
        for field in fields where field.required && !field.isSimple && result[field.key] == nil {
            throw IntegrationError.failed("Add \(field.label) under Advanced request data.")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }
}
protocol IntegrationTransport {
    func run(arguments: [String]) async throws -> String
}
enum IntegrationError: LocalizedError {
    case unavailable, timedOut, failed(String), invalidJSON, invalidSlug, approvalRequired, outputLimit
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Composio CLI was not found. Install it and run composio login in Terminal."
        case .timedOut: return "Composio timed out. The process was stopped. Check the provider before retrying an action."
        case .failed(let text): return text
        case .invalidJSON: return "Arguments must be a valid JSON object."
        case .invalidSlug: return "Select a valid tool slug first."
        case .approvalRequired: return "Preview this exact tool call before approving it."
        case .outputLimit: return "Composio output exceeded 512 KB. Narrow the request before retrying."
        }
    }
}
/// Runs only argument arrays; no shell, credentials, or hosted fallback.
final class ComposioTransport: IntegrationTransport, @unchecked Sendable {
    let executable: URL?
    let timeout: TimeInterval
    init(executable: URL? = ComposioTransport.discover(), timeout: TimeInterval = 60) {
        self.executable = executable; self.timeout = timeout
    }
    static func discover() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [home + "/.composio", home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("composio") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    func run(arguments: [String]) async throws -> String {
        guard let executable else { throw IntegrationError.unavailable }
        let invocation = IntegrationInvocation(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in invocation.start(continuation) }
        }, onCancel: { invocation.cancel() })
    }
}
private final class IntegrationInvocation: @unchecked Sendable {
    let process = Process()
    let pipe = Pipe()
    let lock = NSLock()
    var data = Data()
    var overflow = false
    var cancelled = false
    var timedOut = false
    let timeout: TimeInterval
    let limit = 512 * 1024
    init(executable: URL, arguments: [String], timeout: TimeInterval) {
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env["NO_COLOR"] = "1"; process.environment = env
        self.timeout = timeout
    }
    func append(_ incoming: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + incoming.count > limit { overflow = true }
        data.append(incoming.prefix(max(0, limit - data.count)))
    }
    func cancel() {
        lock.lock(); cancelled = true; let running = process.isRunning; lock.unlock()
        if running { stop() }
    }
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }
    func start(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock(); let alreadyCancelled = cancelled; lock.unlock()
        if alreadyCancelled { continuation.resume(throwing: CancellationError()); return }
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { append(chunk) }
        }
        process.terminationHandler = { [self] completed in
            pipe.fileHandleForReading.readabilityHandler = nil
            append(pipe.fileHandleForReading.readDataToEndOfFile())
            lock.lock(); let payload = data; let wasCancelled = cancelled; let wasTimedOut = timedOut; let overLimit = overflow; lock.unlock()
            let output = String(decoding: payload, as: UTF8.self)
            if wasCancelled { continuation.resume(throwing: CancellationError()) }
            else if wasTimedOut { continuation.resume(throwing: IntegrationError.timedOut) }
            else if overLimit { continuation.resume(throwing: IntegrationError.outputLimit) }
            else if completed.terminationStatus != 0 { continuation.resume(throwing: IntegrationError.failed(output.trimmingCharacters(in: .whitespacesAndNewlines))) }
            else { continuation.resume(returning: output) }
        }
        do {
            try process.run()
            lock.lock(); let shouldCancel = cancelled; lock.unlock()
            if shouldCancel { stop() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                guard process.isRunning else { return }
                lock.lock(); timedOut = true; lock.unlock(); stop()
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            continuation.resume(throwing: error)
        }
    }
}

@MainActor final class IntegrationStore: ObservableObject {
    @Published private(set) var connections: [IntegrationConnection] = []
    @Published private(set) var tools: [IntegrationTool] = []
    @Published private(set) var connectionsCheckedAt: Date?
    @Published private(set) var connectionRefreshError: String?
    @Published private(set) var authorization: IntegrationAuthorization?
    @Published private(set) var authorizationToolkit: String?
    private(set) var authorizationAlias: String?
    var connectionsVerified: Bool { connectionsCheckedAt != nil && connectionRefreshError == nil }
    var authorizedConnection: IntegrationConnection? {
        guard let authorization, connectionsVerified else { return nil }
        // Consumer CLI lists word IDs, not ca_ IDs; the unique alias binds this exact flow.
        return connections.first {
            $0.toolkit == authorizationToolkit && $0.health == .connected &&
            ($0.id == authorization.accountID || $0.alias == authorizationAlias)
        }
    }
    var authorizedAccountIsActive: Bool { authorizedConnection != nil }
    @Published private(set) var hasSearched = false
    @Published private(set) var selectedSlug = ""
    @Published private(set) var schemaText = ""
    @Published private(set) var formFields: [IntegrationField]?
    @Published private(set) var previewText = ""
    @Published private(set) var resultText = ""
    @Published private(set) var busy = false
    @Published var error: String?
    private let transport: IntegrationTransport
    private var operation: Task<Void, Never>?
    private var approvedArguments: [String]?
    private var previewRevision = 0
    init(transport: IntegrationTransport = ComposioTransport()) { self.transport = transport }
    func cancel() { operation?.cancel(); invalidatePreview() }
    func invalidatePreview() { previewRevision += 1; approvedArguments = nil; previewText = "" }
    private func perform(_ work: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil
        let task = Task { @MainActor in
            do { try await work() } catch is CancellationError { self.error = "Cancelled. Check the provider before retrying an action that may have started." }
            catch { self.error = error.localizedDescription }
            self.busy = false
        }
        operation = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    func refresh() async {
        await perform {
            do {
                let output = try await self.transport.run(arguments: ["connections", "list"])
                self.connections = try Self.parseConnections(output)
                self.connectionsCheckedAt = Date()
                self.connectionRefreshError = nil
                self.invalidatePreview()
            } catch {
                self.connectionRefreshError = "Connection status could not be verified. Refresh to check again."
                self.invalidatePreview()
                throw error
            }
        }
    }
    func beginAuthorization(for item: IntegrationConnection) async {
        guard item.toolkit.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil else {
            error = "This app has an invalid connection identifier."; return
        }
        await perform {
            self.authorization = nil
            self.authorizationToolkit = item.toolkit
            // Fresh alias avoids replacing or confusing another active upstream account.
            let alias = "kaddo-" + item.toolkit + "-" + UUID().uuidString.prefix(8).lowercased()
            self.authorizationAlias = alias
            let output = try await self.transport.run(arguments: ["link", item.toolkit, "--alias", alias, "--no-browser", "--no-wait"])
            self.authorization = try IntegrationAuthorization.parse(output)
        }
    }
    func clearAuthorization() { authorization = nil; authorizationToolkit = nil; authorizationAlias = nil }
    func search(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        await perform {
            self.tools = try Self.parseTools(try await self.transport.run(arguments: ["search", query, "--limit", "20", "--json"]))
            self.hasSearched = true
        }
    }
    func select(toolSlug: String) async {
        guard !busy else { return }
        invalidatePreview(); schemaText = ""; formFields = nil; resultText = ""; selectedSlug = toolSlug
        guard Self.validSlug(toolSlug) else { error = IntegrationError.invalidSlug.localizedDescription; return }
        await perform {
            self.schemaText = try await self.transport.run(arguments: ["execute", toolSlug, "--get-schema"])
            self.formFields = IntegrationForm.fields(from: self.schemaText)
        }
    }
    func preparePreview(argumentsJSON: String, account: String? = nil) async {
        invalidatePreview()
        guard Self.validSlug(selectedSlug) else { error = IntegrationError.invalidSlug.localizedDescription; return }
        if connectionsCheckedAt != nil || connectionRefreshError != nil {
            guard connectionsVerified, let account,
                  connections.contains(where: { ($0.id == account || $0.alias == account) && $0.health == .connected }) else {
                error = "Choose a verified, connected app account before reviewing this action."; return
            }
        }
        guard let data = argumentsJSON.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else { error = IntegrationError.invalidJSON.localizedDescription; return }
        let canonical = String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        var args = ["execute", selectedSlug, "-d", canonical]
        if let account, !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--account", account] }
        let executionArgs = args
        let revision = previewRevision
        await perform {
            let output = try await self.transport.run(arguments: executionArgs + ["--dry-run"])
            guard self.previewRevision == revision, !Task.isCancelled else { return }
            self.previewText = "Tool: \(self.selectedSlug)\nAccount: \(account?.isEmpty == false ? account! : "CLI default")\nArguments:\n\(canonical)\n\nCLI preview:\n\(output)"
            self.approvedArguments = executionArgs
        }
    }
    func executeApproved() async {
        guard let args = approvedArguments, !busy else { error = IntegrationError.approvalRequired.localizedDescription; return }
        // Consume approval before starting: retries always require a new preview.
        approvedArguments = nil; previewText = ""; resultText = ""
        await perform { self.resultText = try await self.transport.run(arguments: args) }
    }
    static func validSlug(_ value: String) -> Bool { !value.isEmpty && value.range(of: "^[A-Z][A-Z0-9_]{1,180}$", options: .regularExpression) != nil }
    static func parseConnections(_ output: String) throws -> [IntegrationConnection] {
        let root = try JSONSerialization.jsonObject(with: Data(output.utf8))
        var found: [IntegrationConnection] = []
        func walk(_ value: Any, key: String = "") {
            if let array = value as? [Any] { array.forEach { walk($0, key: key) }; return }
            guard let dict = value as? [String: Any] else { return }
            let toolkitObject = dict["toolkit"] as? [String: Any]
            let inheritedToolkit: String? = !["data", "items", "accounts", "results", "connections", ""].contains(key) ? key : nil
            let toolkit = (dict["toolkit"] as? String) ?? (dict["toolkit_slug"] as? String) ?? (toolkitObject?["slug"] as? String) ?? inheritedToolkit
            if let toolkit, let status = dict["status"] as? String {
                let id = (dict["id"] as? String) ?? (dict["connected_account_id"] as? String) ?? (dict["word_id"] as? String) ?? toolkit + "-" + String(found.count)
                found.append(.init(id: id, toolkit: toolkit, status: status, alias: (dict["alias"] as? String) ?? (dict["word_id"] as? String) ?? id))
            } else { for (key, child) in dict { walk(child, key: key) } }
        }
        walk(root)
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }.sorted {
            ($0.displayName, $0.alias, $0.id) < ($1.displayName, $1.alias, $1.id)
        }
    }
    static func parseTools(_ output: String) throws -> [IntegrationTool] {
        let root = try JSONSerialization.jsonObject(with: Data(output.utf8))
        var found: [String: IntegrationTool] = [:]
        func walk(_ value: Any) {
            if let list = value as? [Any] { list.forEach(walk); return }
            guard let dict = value as? [String: Any] else { return }
            for key in ["primary_tool_slugs", "related_tool_slugs"] {
                for slug in dict[key] as? [String] ?? [] where validSlug(slug) {
                    let name = slug.split(separator: "_").dropFirst().map { $0.lowercased().capitalized }.joined(separator: " ")
                    found[slug] = .init(slug: slug, name: name.isEmpty ? slug : name, description: (dict["use_case"] as? String) ?? "")
                }
            }
            let slug = (dict["slug"] as? String) ?? (dict["tool_slug"] as? String)
            if let slug, validSlug(slug) { found[slug] = .init(slug: slug, name: (dict["name"] as? String) ?? slug, description: (dict["description"] as? String) ?? "") }
            else { dict.values.forEach(walk) }
        }
        walk(root); return found.values.sorted { $0.name < $1.name }
    }
}
