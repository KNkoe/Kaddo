import Foundation
import Darwin

/// Every agent-controlled path component is opened relative to a trusted
/// storage descriptor without following links. Atomic replacement also avoids
/// truncating an existing hard-linked file.
enum AgentResultWriter {
    static func write(_ text: String, storageDirectory: URL, helperID: UUID, jobID: UUID, attempt: Int) throws {
        try writeText(text, storageDirectory: storageDirectory, components: components(helperID, jobID) + ["output"], name: "result-attempt-\(attempt).md")
    }
    static func readNotes(storageDirectory: URL, helperID: UUID, jobID: UUID? = nil, baseline: Bool = false) throws -> String? {
        let directory = try openDirectory(storageDirectory, components: components(helperID, jobID))
        defer { close(directory) }
        let file = openat(directory, baseline ? ".notes-baseline.md" : "notes.md", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw failure()
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw failure() }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { throw failure() }
        return text
    }
    static func writeNotes(_ text: String, storageDirectory: URL, helperID: UUID, jobID: UUID? = nil, baseline: Bool = false) throws {
        try writeText(text, storageDirectory: storageDirectory, components: components(helperID, jobID), name: baseline ? ".notes-baseline.md" : "notes.md")
    }
    private static func components(_ helperID: UUID, _ jobID: UUID?) -> [String] {
        ["Helpers", helperID.uuidString] + (jobID.map { ["Jobs", $0.uuidString] } ?? [])
    }
    private static func openDirectory(_ root: URL, components: [String]) throws -> Int32 {
        var directory = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw failure() }
        for component in components {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { close(directory); throw failure() }
            close(directory); directory = next
        }
        return directory
    }
    private static func writeText(_ text: String, storageDirectory: URL, components: [String], name: String) throws {
        let directory = try openDirectory(storageDirectory, components: components)
        defer { close(directory) }
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
           (info.st_mode & S_IFMT) == S_IFLNK { throw failure() }
        let temporary = ".kaddo-write-\(UUID().uuidString).tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw failure() }
        defer { close(file); unlinkat(directory, temporary, 0) }
        try Data(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        guard renameat(directory, temporary, directory, name) == 0 else { throw failure() }
    }
    private static func failure() -> NSError {
        NSError(domain: "KaddoWorkspace", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "An agent workspace path is unsafe or unavailable. Linked files and directories are not accepted."])
    }
}
