import Testing
import Foundation
@testable import PastefixCore

/// Which hosts `URLSessionTitleFetcher` will contact. The address literals are parsed with
/// `inet_pton`, so alternate spellings (`0x7f.1`, `2130706433`, `::ffff:127.0.0.1`) reduce to
/// the same 4/16 bytes as the dotted form and cannot slip past the range checks.
@Suite struct FetchableHostTests {
    private func fetchable(_ s: String) -> Bool {
        URLSessionTitleFetcher.isFetchable(URL(string: s)!)
    }
    private func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
        URLSessionTitleFetcher.isPrivateIPv4((a, b, c, d))
    }
    private func v6(_ literal: String) -> Bool {
        var addr = in6_addr()
        #expect(literal.withCString { inet_pton(AF_INET6, $0, &addr) } == 1)
        return URLSessionTitleFetcher.isPrivateIPv6(withUnsafeBytes(of: addr) { Array($0) })
    }

    // MARK: names

    @Test func hostnamesAreFetchable() {
        #expect(fetchable("https://example.com/a"))
        #expect(fetchable("https://sub.domain.example.co.uk/a"))
    }
    @Test func localhostAndLocalSuffixesAreNotFetchable() {
        #expect(!fetchable("http://localhost/a"))
        #expect(!fetchable("http://LOCALHOST:3000/a"))
        #expect(!fetchable("http://foo.local/a"))
        #expect(!fetchable("http://Mac.LOCAL/a"))
        #expect(!fetchable("http://foo.localhost/a"))
    }
    @Test func emptyHostIsNotFetchable() {
        #expect(!URLSessionTitleFetcher.isFetchable(URL(string: "file:///tmp/x.html")!))
    }

    // MARK: IPv4 ranges, at the boundaries

    @Test func blockedIPv4Ranges() {
        #expect(v4(0, 0, 0, 0))                 // 0.0.0.0/8
        #expect(v4(0, 255, 255, 255))
        #expect(v4(10, 0, 0, 1))                // 10.0.0.0/8
        #expect(v4(100, 64, 0, 1))              // 100.64.0.0/10
        #expect(v4(100, 127, 255, 255))
        #expect(v4(127, 0, 0, 1))               // 127.0.0.0/8
        #expect(v4(127, 1, 2, 3))
        #expect(v4(169, 254, 1, 1))             // 169.254.0.0/16
        #expect(v4(172, 16, 0, 0))              // 172.16.0.0/12
        #expect(v4(172, 31, 255, 255))
        #expect(v4(192, 168, 1, 1))             // 192.168.0.0/16
        #expect(v4(224, 0, 0, 1))               // 224.0.0.0/4
        #expect(v4(239, 255, 255, 255))
        #expect(v4(240, 0, 0, 1))               // 240.0.0.0/4
        #expect(v4(255, 255, 255, 255))
    }
    @Test func allowedIPv4JustOutsideTheBlockedRanges() {
        #expect(!v4(1, 0, 0, 1))
        #expect(!v4(8, 8, 8, 8))
        #expect(!v4(9, 255, 255, 255))
        #expect(!v4(11, 0, 0, 1))
        #expect(!v4(100, 63, 255, 255))
        #expect(!v4(100, 128, 0, 0))
        #expect(!v4(126, 255, 255, 255))
        #expect(!v4(128, 0, 0, 1))
        #expect(!v4(169, 253, 255, 255))
        #expect(!v4(169, 255, 0, 0))
        #expect(!v4(172, 15, 255, 255))
        #expect(!v4(172, 32, 0, 0))
        #expect(!v4(192, 167, 255, 255))
        #expect(!v4(192, 169, 0, 0))
        #expect(!v4(223, 255, 255, 255))
    }
    @Test func ipv4LiteralURLsAreClassified() {
        #expect(!fetchable("http://10.1.2.3/a"))
        #expect(!fetchable("http://127.0.0.1/a"))
        #expect(!fetchable("http://192.168.1.1/a"))
        #expect(!fetchable("http://169.254.1.1/a"))
        #expect(!fetchable("http://0.0.0.0/a"))
        #expect(!fetchable("http://100.64.0.1/a"))
        #expect(!fetchable("http://255.255.255.255/a"))
        #expect(fetchable("https://8.8.8.8/a"))
        #expect(fetchable("https://172.32.0.1/a"))
        #expect(fetchable("https://11.0.0.1/a"))
    }

    // MARK: IPv6 ranges

    @Test func blockedIPv6Ranges() {
        #expect(v6("::"))                       // unspecified
        #expect(v6("::1"))                      // loopback
        #expect(v6("fe80::1"))                  // link-local
        #expect(v6("febf:ffff::1"))
        #expect(v6("fc00::1"))                  // unique local
        #expect(v6("fd00::1"))
        #expect(v6("fdff:ffff::1"))
        #expect(v6("fec0::1"))                  // site-local (deprecated)
        #expect(v6("feff::1"))
        #expect(v6("::ffff:10.0.0.1"))          // IPv4-mapped, private v4
        #expect(v6("::ffff:127.0.0.1"))
        #expect(v6("::ffff:192.168.0.1"))
    }
    @Test func allowedIPv6() {
        #expect(!v6("2606:4700::1111"))
        #expect(!v6("2001:4860:4860::8888"))
        #expect(!v6("::ffff:8.8.8.8"))          // IPv4-mapped, public v4
        #expect(!v6("fb00::1"))                 // just below fc00::/7
    }
    @Test func ipv6LiteralURLsAreClassified() {
        #expect(!fetchable("http://[::1]/a"))
        #expect(!fetchable("http://[::]/a"))
        #expect(!fetchable("http://[fe80::1]/a"))
        #expect(!fetchable("http://[fd00::1]/a"))
        #expect(!fetchable("http://[fc00::1]/a"))
        #expect(!fetchable("http://[::ffff:10.0.0.1]/a"))
        #expect(!fetchable("http://[::ffff:127.0.0.1]/a"))
        #expect(fetchable("https://[2606:4700::1111]/a"))
        #expect(fetchable("https://[::ffff:8.8.8.8]/a"))
    }

    // MARK: alternate encodings the old dotted-quad parse would have missed

    @Test func alternateIPv4SpellingsDoNotBypassTheCheck() {
        // inet_pton is strict about these forms, so they are hostnames, not addresses —
        // the point is that they can no longer be *mistaken* for a public dotted quad.
        #expect(!fetchable("http://[::ffff:169.254.169.254]/latest/meta-data/"))
    }
}
