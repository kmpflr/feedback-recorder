import Foundation

public struct SavedSession: Identifiable, Sendable, Equatable {
    public var id: URL { folder.url }
    public let folder: SessionFolder
    public let state: SessionState
    public let customName: String?
    public var name: String { customName ?? folder.url.lastPathComponent }

    public func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let text = "\(name) \(folder.url.lastPathComponent) \(state.mode.rawValue) \(state.input.name) \(state.startedAt.formatted(date: .abbreviated, time: .shortened))"
        return terms.allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

public enum SessionLibrary {
    private struct Label: Codable { let name: String }
    private static func labelURL(_ folder: SessionFolder) -> URL {
        folder.url.appendingPathComponent("session-label.json")
    }

    public struct Snapshot: Sendable {
        public var sessions: [SavedSession]
        public var warnings: [String]
    }

    /// Reads only session metadata and optional display names; never opens recordings or transcripts.
    public static func load(roots: [URL]) -> Snapshot {
        var result = Snapshot(sessions: [], warnings: [])
        var seen: Set<URL> = []
        for root in Set(roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }).sorted(by: { $0.path < $1.path }) {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            do {
                for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                    guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                        result.warnings.append("Couldn’t inspect \(entry.lastPathComponent).")
                        continue
                    }
                    guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    let folder = SessionFolder(url: entry.standardizedFileURL)
                    guard seen.insert(folder.url).inserted,
                          FileManager.default.fileExists(atPath: folder.stateURL.path) else { continue }
                    do {
                        let state = try SessionState.decoder.decode(SessionState.self, from: Data(contentsOf: folder.stateURL))
                        let label = (try? Data(contentsOf: labelURL(folder))).flatMap { try? JSONDecoder().decode(Label.self, from: $0) }
                        result.sessions.append(SavedSession(folder: folder, state: state, customName: label?.name))
                    } catch {
                        result.warnings.append("Couldn’t read \(entry.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            } catch { result.warnings.append("Couldn’t read \(root.lastPathComponent): \(error.localizedDescription)") }
        }
        result.sessions.sort {
            if $0.state.startedAt != $1.state.startedAt { return $0.state.startedAt > $1.state.startedAt }
            return $0.folder.url.path.compare($1.folder.url.path, options: .numeric) == .orderedDescending
        }
        return result
    }

    /// A display name lives beside the recording, so existing paths and active writers stay valid.
    public static func rename(_ folder: SessionFolder, to text: String) throws {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.contains(where: \.isNewline) else {
            throw LibraryError.invalidName
        }
        guard FileManager.default.fileExists(atPath: folder.stateURL.path) else { throw LibraryError.missingSession }
        let data = try JSONEncoder().encode(Label(name: name))
        try data.write(to: labelURL(folder), options: .atomic)
    }

    public enum LibraryError: LocalizedError {
        case invalidName, missingSession
        public var errorDescription: String? {
            switch self {
            case .invalidName: "Use a session name between 1 and 120 characters on one line."
            case .missingSession: "This session is no longer available. Refresh the recordings list."
            }
        }
    }
}
