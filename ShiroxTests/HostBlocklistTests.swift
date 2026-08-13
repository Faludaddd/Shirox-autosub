import XCTest
@testable import Shirox

final class HostBlocklistTests: XCTestCase {

    func testParseHandlesHostsFileAndBareLinesAndComments() {
        let contents = """
        # a comment
        127.0.0.1 blocked.example.com
        0.0.0.0 restricted.example.net
        another-restricted.org

        127.0.0.1 localhost
        """
        let set = HostBlocklist.parse(contents)
        XCTAssertTrue(set.contains("blocked.example.com"))
        XCTAssertTrue(set.contains("restricted.example.net"))
        XCTAssertTrue(set.contains("another-restricted.org"))
        XCTAssertFalse(set.contains("localhost"))   // skipped
        XCTAssertFalse(set.contains(""))            // blank line skipped
    }

    func testParseLowercasesHosts() {
        XCTAssertTrue(HostBlocklist.parse("0.0.0.0 Blocked.Example.COM").contains("blocked.example.com"))
    }

    func testExactHostBlocked() {
        let set: Set<String> = ["blocked.example.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("blocked.example.com", in: set))
    }

    func testSubdomainBlocked() {
        let set: Set<String> = ["blocked.example.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("cdn.videos.blocked.example.com", in: set))
    }

    func testLookalikeNotBlocked() {
        let set: Set<String> = ["blocked.com"]
        XCTAssertFalse(HostBlocklist.isHostBlocked("notblocked.com", in: set))
        XCTAssertFalse(HostBlocklist.isHostBlocked("blockedial.com", in: set))
    }

    func testUnrelatedHostNotBlocked() {
        let set: Set<String> = ["blocked.example.com"]
        XCTAssertFalse(HostBlocklist.isHostBlocked("anilist.co", in: set))
    }

    func testCaseInsensitiveMatch() {
        let set: Set<String> = ["blocked.example.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("CDN.Blocked.Example.Com", in: set))
    }

    func testDoesNotBlockBareTLD() {
        let set: Set<String> = ["com"]   // pathological entry must not nuke everything
        XCTAssertFalse(HostBlocklist.isHostBlocked("anilist.com", in: set))
    }

    func testLoadForTestingPopulatesIsBlocked() {
        HostBlocklist.loadForTesting(["blocked.example.com"])
        XCTAssertTrue(HostBlocklist.shared.isBlocked(URL(string: "https://cdn.blocked.example.com/a.m3u8")!))
        XCTAssertFalse(HostBlocklist.shared.isBlocked(URL(string: "https://anilist.co")!))
    }
}
