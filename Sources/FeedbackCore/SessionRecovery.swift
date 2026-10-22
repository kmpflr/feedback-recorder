import Foundation

public enum SessionRecovery {
    /// Marks every session still `recording` as stopped with reason `crash`. Returns the folders touched.
    public static func recoverOrphans(root: URL, now: Date = Date(), fileManager: FileManager = .default) throws -> [URL] {
        var touched: [URL] = []
        for folder in sessionFolders(root: root, fileManager: fileManager) {
            guard let data = try? Data(contentsOf: folder.stateURL),
                  var state = try? SessionState.decoder.decode(SessionState.self, from: data),
                  state.state == .recording else { continue }
            state.stop(reason: .crash, at: now)
            try SessionState.encoder.encode(state).write(to: folder.stateURL, options: .atomic)
            touched.append(folder.url)
        }
        return touched.sorted { $0.path < $1.path }
    }

    /// Metadata retains sub-minute ordering even when folder suffixes reach _10 or a clock changes.
    public static func newestSession(root: URL, fileManager: FileManager = .default) -> SessionFolder? {
        sessionFolders(root: root, fileManager: fileManager).compactMap { folder -> (SessionFolder, Date)? in
            guard let data = try? Data(contentsOf: folder.stateURL),
                  let state = try? SessionState.decoder.decode(SessionState.self, from: data) else { return nil }
            return (folder, state.startedAt)
        }.max {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.url.lastPathComponent.compare($1.0.url.lastPathComponent, options: .numeric) == .orderedAscending
        }?.0
    }

    private static func sessionFolders(root: URL, fileManager: FileManager) -> [SessionFolder] {
        let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.map { SessionFolder(url: $0.standardizedFileURL) }.filter { fileManager.fileExists(atPath: $0.stateURL.path) }
    }
}
