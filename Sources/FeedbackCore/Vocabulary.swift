import Foundation

public enum Vocabulary {
    public static let maxPhrases = 100

    public static func parse(_ text: String) -> [String] {
        let filtered = Array(
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
        return Array(filtered.prefix(maxPhrases))
    }

    /// Returns [] when the file does not exist.
    public static func load(from url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }
}
