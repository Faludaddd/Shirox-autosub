import XCTest
@testable import Shirox

final class ContentSafetyFilterTests: XCTestCase {

    // normalize
    func testNormalizeLowercasesAndStripsPunctuation() {
        XCTAssertEqual(ContentSafetyFilter.normalize("Re:ZERO -Starting Life-"), "re zero starting life")
    }
    func testNormalizeStripsSeasonSuffix() {
        XCTAssertEqual(ContentSafetyFilter.normalize("Overflow Season 2"), "overflow")
        XCTAssertEqual(ContentSafetyFilter.normalize("Kaguya-sama 3rd Season"), "kaguya sama")
    }

    // keyword layer — whole-token, no false positives
    func testKeywordFlagsExplicitTerms() {
        XCTAssertTrue(ContentSafetyFilter.containsBlockedKeyword(ContentSafetyFilter.normalize("Some Hentai OVA")))
        XCTAssertTrue(ContentSafetyFilter.containsBlockedKeyword(ContentSafetyFilter.normalize("XXX Holic Uncut")))
    }
    func testKeywordFlagsExpandedTerms() {
        for title in ["Futanari World", "Eroge H mo Game", "The Erotic Night",
                      "Milf Apartment", "Threesome OVA", "Incest Diary"] {
            XCTAssertTrue(ContentSafetyFilter.containsBlockedKeyword(ContentSafetyFilter.normalize(title)),
                          "expected \(title) to be flagged")
        }
    }
    func testKeywordDoesNotFalseFlagInnocentTitles() {
        XCTAssertFalse(ContentSafetyFilter.containsBlockedKeyword(ContentSafetyFilter.normalize("Assassination Classroom")))
        XCTAssertFalse(ContentSafetyFilter.containsBlockedKeyword(ContentSafetyFilter.normalize("Prison School")))
        XCTAssertFalse(ContentSafetyFilter.containsBlockedKeyword(ContentSafetyFilter.normalize("Cassandra")))
    }
    // Whole-token safety + deliberate exclusions must stay unflagged.
    func testKeywordDoesNotFalseFlagLookalikesOrGenreTitles() {
        for title in ["Analog Memory", "Peacock King", "Cumulus", "Moby Dick Anime",
                      "Eromanga Sensei", "Sexy Commando Gaiden", "High School DxD (Ecchi)",
                      "Yuri on Ice", "Given (Yaoi Romance)"] {
            XCTAssertFalse(ContentSafetyFilter.containsBlockedKeyword(ContentSafetyFilter.normalize(title)),
                           "did not expect \(title) to be flagged")
        }
    }

    // restricted-set cross-check layer
    func testRestrictedExactMatch() {
        let set: Set<String> = ["overflow"]
        XCTAssertTrue(ContentSafetyFilter.isRestrictedTitle("overflow", restrictedSet: set))
    }
    func testRestrictedMultiTokenSubsetMatch() {
        let set: Set<String> = ["boku no pico"]
        XCTAssertTrue(ContentSafetyFilter.isRestrictedTitle("boku no pico uncensored", restrictedSet: set))
    }
    func testRestrictedSingleTokenDoesNotOverMatch() {
        // A single-token restricted variant must only match exactly, not every
        // title sharing the word.
        let set: Set<String> = ["school"]
        XCTAssertFalse(ContentSafetyFilter.isRestrictedTitle("prison school", restrictedSet: set))
    }
    func testNonRestrictedTitleNotFlagged() {
        let set: Set<String> = ["overflow"]
        XCTAssertFalse(ContentSafetyFilter.isRestrictedTitle("fullmetal alchemist", restrictedSet: set))
    }
}
