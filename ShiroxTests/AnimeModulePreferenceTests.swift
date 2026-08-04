import XCTest
@testable import Shirox

final class AnimeModulePreferenceTests: XCTestCase {
    // `ModuleDefinition` is Codable with a custom `init(from:)` (ModuleDefinition.swift:41).
    // Required decode keys: sourceName, version, scriptUrl, type. `id` is computed as
    // `scriptUrl`, so set scriptUrl to the id. `isManga` is `type == "mangas" || "manga"`.
    private func mod(_ id: String, manga: Bool) -> ModuleDefinition {
        let type = manga ? "mangas" : "anime"
        let json = #"{"sourceName":"\#(id)","version":"1","scriptUrl":"\#(id)","type":"\#(type)"}"#
        return try! JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
    }

    func testKeepsActiveWhenActiveIsAnime() {
        let active = mod("a", manga: false)
        let picked = AnimeModulePreference.pick(active: active, modules: [active, mod("m", manga: true)])
        XCTAssertEqual(picked?.id, "a")
    }

    func testSwitchesToFirstAnimeWhenActiveIsManga() {
        let active = mod("m", manga: true)
        let anime = mod("a", manga: false)
        let picked = AnimeModulePreference.pick(active: active, modules: [active, anime])
        XCTAssertEqual(picked?.id, "a")
    }

    func testNilWhenNoAnimeModule() {
        let active = mod("m", manga: true)
        XCTAssertNil(AnimeModulePreference.pick(active: active, modules: [active]))
    }
}

// MARK: - StreamPreferenceMatcher tests

final class StreamPreferenceMatcherTests: XCTestCase {
    private static let fillerURL = URL(string: "https://example.com/stream")!
    private func stream(_ title: String) -> StreamResult {
        StreamResult(title: title, url: Self.fillerURL, headers: [:])
    }

    // MARK: - Off preference (default)

    func testOffAlwaysReturnsNil() {
        XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [stream("SUB"), stream("DUB")], preference: .off))
    }

    func testOffReturnsNilForEmptyList() {
        XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [], preference: .off))
    }

    func testCurrentPreferenceDefaultsToOff() {
        UserDefaults.standard.removeObject(forKey: "autoPickSubDub")
        XCTAssertEqual(StreamPreferenceMatcher.currentPreference(), .off)
    }

    func testCurrentPreferenceFallsBackToOffForInvalidValue() {
        UserDefaults.standard.set("garbage", forKey: "autoPickSubDub")
        XCTAssertEqual(StreamPreferenceMatcher.currentPreference(), .off)
        UserDefaults.standard.removeObject(forKey: "autoPickSubDub")
    }

    // MARK: - Sub preference

    func testSubPicksSubWhenSubAndDubAvailable() {
        let picked = StreamPreferenceMatcher.preferredStream(in: [stream("SUB"), stream("DUB")], preference: .sub)
        XCTAssertEqual(picked?.title, "SUB")
    }

    func testSubPrefersSoftsubOverGenericSub() {
        let picked = StreamPreferenceMatcher.preferredStream(in: [stream("SUB"), stream("Softsub")], preference: .sub)
        XCTAssertEqual(picked?.title, "Softsub")
    }

    func testSubNeverPicksDubEvenWhenTitleContainsSub() {
        // "Subbed (English Dub)" contains both "sub" and "dub" — must be rejected.
        let picked = StreamPreferenceMatcher.preferredStream(in: [stream("Subbed (English Dub)"), stream("1080p")], preference: .sub)
        XCTAssertEqual(picked?.title, "1080p")
    }

    func testSubFallsBackToFirstNonDubWhenNoSubMarker() {
        let picked = StreamPreferenceMatcher.preferredStream(in: [stream("1080p"), stream("720p")], preference: .sub)
        XCTAssertEqual(picked?.title, "1080p")
    }

    func testSubReturnsNilWhenOnlyDubStreams() {
        XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [stream("DUB"), stream("Dubbed")], preference: .sub))
    }

    func testSubIsCaseInsensitive() {
        let picked = StreamPreferenceMatcher.preferredStream(in: [stream("DUB"), stream("sub")], preference: .sub)
        XCTAssertEqual(picked?.title, "sub")
    }

    // MARK: - Dub preference

    func testDubPicksDubWhenSubAndDubAvailable() {
        let picked = StreamPreferenceMatcher.preferredStream(in: [stream("SUB"), stream("DUB")], preference: .dub)
        XCTAssertEqual(picked?.title, "DUB")
    }

    func testDubReturnsNilWhenOnlySubStreams() {
        XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [stream("SUB"), stream("Softsub")], preference: .dub))
    }

    // MARK: - Edge cases

    func testEmptyStreamListReturnsNilForAllPreferences() {
        for pref in StreamSubDubPreference.allCases {
            XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [], preference: pref))
        }
    }
}
