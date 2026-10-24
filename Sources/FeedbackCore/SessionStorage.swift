import Foundation

public enum SessionStorage {
    /// Verify a destination by writing a disposable file before saving it as a preference.
    /// Existing recordings are never moved or removed.
    public static func prepare(_ directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".feedback-write-check-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        try fm.removeItem(at: probe)
    }
}
