import Foundation

public enum Timestamp {
    /// Seconds from session start → "MM:SS", or "H:MM:SS" once past an hour.
    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Inverse of `format`. Returns nil for anything that is not MM:SS or H:MM:SS.
    public static func parse(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let v = parts.compactMap { $0 }
        switch v.count {
        case 2: return TimeInterval(v[0] * 60 + v[1])
        case 3: return TimeInterval(v[0] * 3600 + v[1] * 60 + v[2])
        default: return nil
        }
    }
}
