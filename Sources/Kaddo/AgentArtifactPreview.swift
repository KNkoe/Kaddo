import AppKit
import Darwin

/// Agent output is data. Never ask Launch Services to choose an executable handler.
enum AgentArtifactPreview {
    static let maximumBytes = 32 * 1024 * 1024
    static func application(for file: URL) -> URL {
        let images = ["pdf", "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic"]
        return URL(fileURLWithPath: images.contains(file.pathExtension.lowercased()) ? "/System/Applications/Preview.app" : "/System/Applications/TextEdit.app")
    }
    static func snapshot(_ file: URL, workspace: URL) throws -> URL {
        let root = workspace.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root) else { throw PreviewError() }
        let components = String(path.dropFirst(root.count)).split(separator: "/").map(String.init)
        guard components.count >= 2, components.first == "output", !components.contains("..") else { throw PreviewError() }
        var directory = Darwin.open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw PreviewError() }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw PreviewError() }
            Darwin.close(directory); directory = next
        }
        let descriptor = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw PreviewError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw PreviewError() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            guard bytes.count + chunk.count <= maximumBytes else { throw PreviewError() }
            bytes.append(chunk)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-artifact-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        try bytes.write(to: copy, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        return copy
    }
    @MainActor static func open(_ file: URL, workspace: URL) throws {
        let copy = try snapshot(file, workspace: workspace)
        NSWorkspace.shared.open([copy], withApplicationAt: application(for: file), configuration: NSWorkspace.OpenConfiguration())
    }
    struct PreviewError: LocalizedError {
        var errorDescription: String? { "This file changed, is linked, or is too large to preview safely. Use Show task workspace to inspect it." }
    }
}
