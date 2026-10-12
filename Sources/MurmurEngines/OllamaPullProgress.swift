import Foundation

/// Parses the newline-delimited JSON that `POST /api/pull` streams.
public enum OllamaPullProgress {
    private static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Fraction in 0...1, or nil when the line carries no usable `completed` and `total`.
    public static func fraction(line: String) -> Double? {
        guard let obj = object(line),
              let total = (obj["total"] as? NSNumber)?.doubleValue, total > 0,
              let completed = (obj["completed"] as? NSNumber)?.doubleValue else { return nil }
        return min(max(completed / total, 0), 1)
    }

    public static func isSuccess(line: String) -> Bool {
        (object(line)?["status"] as? String) == "success"
    }

    public static func errorMessage(line: String) -> String? {
        object(line)?["error"] as? String
    }
}
