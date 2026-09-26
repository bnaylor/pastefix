import Foundation

/// The one parse of a configured Zipline server address, shared by every place in the app that
/// has to decide whether `SettingsStore.ziplineServerURL` is currently usable
/// (`UploadOverlayView`'s configure-state check and upload path, `UploadSettingsView`'s
/// validation line).
///
/// Deliberately only a scheme and host check. It must NOT reject private, LAN or Tailscale
/// hosts: a self-hosted Zipline on `http://box.tailnet.ts.net` is the expected deployment, not
/// an attack. (`MarkdownLink.isFetchable`, which does reject those, guards link *unfurling* —
/// where the URL comes from someone else's text. Here the user typed it into their own
/// settings.) One copy of this rule means the next person who tightens URL validation can't
/// tighten only half of it.
enum ZiplineServerURL {
    /// Trims `raw`, then returns the parsed URL if it is `http`/`https` with a non-empty host —
    /// nil otherwise, including for an empty or all-whitespace string.
    static func parse(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
