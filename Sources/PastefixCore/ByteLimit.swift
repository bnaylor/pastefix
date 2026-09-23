import Foundation

/// Renders a byte cap the way the UI states it: binary units, whole numbers only.
public enum ByteLimit {
    public static func describe(_ bytes: Int) -> String {
        if bytes >= 1_048_576, bytes % 1_048_576 == 0 { return "\(bytes / 1_048_576) MB" }
        if bytes >= 1024, bytes % 1024 == 0 { return "\(bytes / 1024) KB" }
        return "\(bytes) bytes"
    }
}
