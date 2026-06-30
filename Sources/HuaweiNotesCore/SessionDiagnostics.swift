import Foundation

public final class SessionDiagnostics: @unchecked Sendable {
    public static let shared = SessionDiagnostics()

    public let logURL: URL
    private let queue = DispatchQueue(label: "HuaweiNotesCore.SessionDiagnostics")

    public init(
        logURL: URL = SessionDiagnostics.defaultLogURL()
    ) {
        self.logURL = logURL
    }

    public func log(_ event: String, fields: [String: String] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var payload = fields
        payload["ts"] = timestamp
        payload["event"] = event
        let payloadForWrite = payload
        let logURL = logURL

        queue.async {
            do {
                let fileManager = FileManager.default
                let directoryURL = logURL.deletingLastPathComponent()
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )

                let data = try JSONSerialization.data(
                    withJSONObject: payloadForWrite,
                    options: [.sortedKeys]
                )
                guard var line = String(data: data, encoding: .utf8) else { return }
                line.append("\n")
                let lineData = Data(line.utf8)

                if fileManager.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: lineData)
                    try handle.close()
                } else {
                    try lineData.write(to: logURL, options: [.atomic])
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
                }
            } catch {
                // Diagnostics must never interfere with session handling.
            }
        }
    }

    public static func defaultLogURL() -> URL {
        let logsURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs", isDirectory: true)

        return logsURL
            .appendingPathComponent("HuaweiNotes", isDirectory: true)
            .appendingPathComponent("session.log")
    }
}
