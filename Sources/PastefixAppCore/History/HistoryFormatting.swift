import Foundation

public enum HistoryFormatting {
    /// First two non-blank lines, whitespace collapsed, ≤ 160 characters, "…" when cut.
    public static func previewText(for item: HistoryItem) -> String {
        if item.hasText, let text = item.plainText {
            let lines = text.split(whereSeparator: \.isNewline)
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .filter { !$0.isEmpty }
            var out = lines.prefix(2).joined(separator: "\n")
            var cut = lines.count > 2
            if out.count > 160 { out = String(out.prefix(159)); cut = true }
            return cut ? out + "…" : out
        }
        if let w = item.imagePixelWidth, let h = item.imagePixelHeight { return "Image \(w)×\(h)" }
        return "Image"
    }

    public static func relativeAge(from date: Date, to now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 5 { return "now" }
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if Calendar.current.isDate(date, inSameDayAs: now.addingTimeInterval(-86_400)) { return "yesterday" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    public static func byteLabel(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(Int((Double(n) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(n) / 1_048_576)
    }
}
