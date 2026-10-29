import Foundation

struct NativePermissionField: Identifiable {
    let id: String
    let title: String
    let choices: [String]
    let boolean: Bool
}

struct NativeComputerPermission: Identifiable {
    static func isAppRequest(_ params: [String: Any], appID: String) -> Bool {
        // The caller has already pinned the private sky-only MCP server and thread.
        // App Server can omit connector_id for a non-Apps MCP server.
        guard let meta = params["_meta"] as? [String: Any], meta["connector_id"] == nil || meta["connector_id"] as? String == "computer-use",
              let tools = meta["tool_params"] as? [String: Any] else { return false }
        return tools["app"] as? String == appID
    }
    let id = UUID()
    let message: String
    let fields: [NativePermissionField]
    let supported: Bool
    let allowSession: Bool

    init(_ params: [String: Any]) {
        message = String((params["message"] as? String ?? params["description"] as? String ?? "Codex requests computer access.").prefix(2000))
        let mode = params["mode"] as? String ?? ""
        let schema = params["requestedSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        var supported = ["form", "openai/form", "openaiForm"].contains(mode) && schema["type"] as? String == "object" && properties.count <= 12
        var fields: [NativePermissionField] = []
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            let choices = value["enum"] as? [String] ?? []
            let boolean = value["type"] as? String == "boolean"
            if !boolean && (choices.isEmpty || choices.count > 12) { supported = false }
            fields.append(NativePermissionField(id: key, title: String((value["title"] as? String ?? value["description"] as? String ?? key).prefix(200)), choices: choices, boolean: boolean))
        }
        let required = schema["required"] as? [String] ?? []
        if required.contains(where: { properties[$0] == nil }) { supported = false }
        self.fields = fields; self.supported = supported
        let persistence = (params["_meta"] as? [String: Any])?["persist"]
        allowSession = persistence as? String == "session" || (persistence as? [String] ?? []).contains("session")
    }
    func response(allow: Bool, values: [String: Any], rememberSession: Bool = false) -> [String: Any] {
        guard allow, supported, fields.allSatisfy({ field in
            field.boolean ? values[field.id] is Bool : field.choices.contains(values[field.id] as? String ?? "")
        }) else { return ["action": "decline"] }
        var result: [String: Any] = ["action": "accept", "content": values.filter { key, _ in fields.contains { $0.id == key } }]
        if rememberSession && allowSession { result["_meta"] = ["persist": "session"] }
        return result
    }
}
