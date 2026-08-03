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
    // Helper to build a StreamResult with just a title. The matcher only inspects `title`,
    // so url/headers are filler. Using a fixed URL avoids URL-encoding issues with titles
    // that contain spaces or parens (e.g. "Subbed (English Dub)").
    private static let fillerURL = URL(string: "https://example.com/stream")!
    private func stream(_ title: String) -> StreamResult {
        StreamResult(title: title, url: Self.fillerURL, headers: [:])
    }

    // MARK: - Off preference

    func testOffAlwaysReturnsNil() {
        let streams = [stream("SUB"), stream("DUB")]
        XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: streams, preference: .off))
    }

    func testOffReturnsNilEvenForSingleStream() {
        XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [stream("SUB")], preference: .off))
    }

    func testOffReturnsNilForEmptyList() {
        XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [], preference: .off))
    }

    // MARK: - Sub preference

    func testSubPicksSubWhenSubAndDubAvailable() {
        let sub = stream("SUB")
        let dub = stream("DUB")
        let picked = StreamPreferenceMatcher.preferredStream(in: [sub, dub], preference: .sub)
        XCTAssertEqual(picked?.title, "SUB")
    }

    func testSubPrefersSoftsubOverGenericSub() {
        let softsub = stream("Softsub")
        let genericSub = stream("SUB")
        let picked = StreamPreferenceMatcher.preferredStream(in: [genericSub, softsub], preference: .sub)
        XCTAssertEqual(picked?.title, "Softsub")
    }

    func testSubPrefersSoftsubOverHardsub() {
        let softsub = stream("Softsub")
        let hardsub = stream("Hardsub")
        let picked = StreamPreferenceMatcher.preferredStream(in: [hardsub, softsub], preference: .sub)
        XCTAssertEqual(picked?.title, "Softsub")
    }

    func testSubPicksHardsubWhenNoOtherSub() {
        let hardsub = stream("Hardsub")
        let dub = stream("DUB")
        let picked = StreamPreferenceMatcher.preferredStream(in: [dub, hardsub], preference: .sub)
        XCTAssertEqual(picked?.title, "Hardsub")
    }

    func testSubNeverPicksDubEvenWhenTitleContainsSub() {
        // "Subbed (English Dub)" contains both "sub" and "dub" — must be rejected for sub pref.
        let tricky = stream("Subbed (English Dub)")
        let clean = stream("1080p")
        let picked = StreamPreferenceMatcher.preferredStream(in: [tricky, clean], preference: .sub)
        XCTAssertEqual(picked?.title, "1080p")
    }

    func testSubFallsBackToFirstNonDubWhenNoSubMarker() {
        // Quality-only titles (no sub/dub marker) — sub pref picks the first non-dub.
        let q1080 = stream("1080p")
        let q720 = stream("720p")
        let picked = StreamPreferenceMatcher.preferredStream(in: [q1080, q720], preference: .sub)
        XCTAssertEqual(picked?.title, "1080p")
    }

    func testSubReturnsNilWhenOnlyDubStreams() {
        let dub1 = stream("DUB")
        let dub2 = stream("Dubbed")
        XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [dub1, dub2], preference: .sub))
    }

    func testSubIsCaseInsensitive() {
        let lower = stream("sub")
        let upper = stream("DUB")
        let picked = StreamPreferenceMatcher.preferredStream(in: [upper, lower], preference: .sub)
        XCTAssertEqual(picked?.title, "sub")
    }

    func testSubHandlesMixedCaseVariants() {
        let variants = ["SUB", "Sub", "sub", "Subbed", "Softsub", "Hardsub"]
        for v in variants {
            let picked = StreamPreferenceMatcher.preferredStream(in: [stream("DUB"), stream(v)], preference: .sub)
            XCTAssertEqual(picked?.title, v, "Failed for variant '\(v)'")
        }
    }

    // MARK: - Dub preference

    func testDubPicksDubWhenSubAndDubAvailable() {
        let sub = stream("SUB")
        let dub = stream("DUB")
        let picked = StreamPreferenceMatcher.preferredStream(in: [sub, dub], preference: .dub)
        XCTAssertEqual(picked?.title, "DUB")
    }

    func testDubPicksFirstDubVariant() {
        let dubbed = stream("Dubbed")
        let dub = stream("DUB")
        let picked = StreamPreferenceMatcher.preferredStream(in: [dubbed, dub], preference: .dub)
        XCTAssertEqual(picked?.title, "Dubbed")
    }

    func testDubReturnsNilWhenOnlySubStreams() {
        let sub1 = stream("SUB")
        let sub2 = stream("Softsub")
        XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [sub1, sub2], preference: .dub))
    }

    func testDubIsCaseInsensitive() {
        let lower = stream("dub")
        let picked = StreamPreferenceMatcher.preferredStream(in: [stream("SUB"), lower], preference: .dub)
        XCTAssertEqual(picked?.title, "dub")
    }

    // MARK: - Edge cases

    func testEmptyStreamListReturnsNilForAllPreferences() {
        for pref in StreamSubDubPreference.allCases {
            XCTAssertNil(StreamPreferenceMatcher.preferredStream(in: [], preference: pref),
                         "Expected nil for empty list with preference \(pref)")
        }
    }

    func testCurrentPreferenceDefaultsToSub() {
        // Clear any persisted value to verify the default.
        UserDefaults.standard.removeObject(forKey: "autoPickSubDub")
        XCTAssertEqual(StreamPreferenceMatcher.currentPreference(), .sub)
    }

    func testCurrentPreferenceReadsPersistedValue() {
        UserDefaults.standard.set("dub", forKey: "autoPickSubDub")
        XCTAssertEqual(StreamPreferenceMatcher.currentPreference(), .dub)
        UserDefaults.standard.set("off", forKey: "autoPickSubDub")
        XCTAssertEqual(StreamPreferenceMatcher.currentPreference(), .off)
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "autoPickSubDub")
    }

    func testCurrentPreferenceFallsBackToSubForInvalidValue() {
        UserDefaults.standard.set("garbage", forKey: "autoPickSubDub")
        XCTAssertEqual(StreamPreferenceMatcher.currentPreference(), .sub)
        UserDefaults.standard.removeObject(forKey: "autoPickSubDub")
    }
}
