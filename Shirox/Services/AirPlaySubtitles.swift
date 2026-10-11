import Foundation

/// Soft subtitles for an AirPlay receiver — pure text and byte work, no app state.
///
/// The player draws subtitles itself, over the video on the phone. AirPlay hands the Apple TV
/// only the stream's URL, so none of that reached the TV. What a receiver does draw is a
/// WebVTT rendition named in the HLS master playlist, so while AirPlay goes through
/// ``CastProxyServer`` the proxy adds one, built from the cues the player already has:
///
///     #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="shirox-subs",…,URI="<subtitle playlist>"
///     #EXT-X-STREAM-INF:…,SUBTITLES="shirox-subs"
///
/// WebVTT cue times start at 0, the video's timestamps usually don't (an ffmpeg-made TS starts
/// around 1.4 s), and without an `X-TIMESTAMP-MAP` the receiver lines cue 0 up with timestamp 0.
/// So the first segment's timestamp is read off the stream and put in the map.
enum AirPlaySubtitles {
    static let groupID = "shirox-subs"

    // MARK: Playlists

    /// The `#EXT-X-MEDIA` line naming the subtitle playlist at `uri`.
    static func mediaTag(uri: String, name: String) -> String {
        let safeName = name.replacingOccurrences(of: "\"", with: "'")
        // Without a language AVFoundation lists the track as "Unknown", whatever its NAME.
        let language = languageCode(forName: name).map { "LANGUAGE=\"\($0)\"," } ?? ""
        return "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"\(groupID)\",NAME=\"\(safeName)\",\(language)"
            + "DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"\(uri)\""
    }

    /// The language a track's name gives away — "English", "Español (Latino)", "pt-BR", "jpn" —
    /// as an ISO 639 code; nil when it doesn't.
    static func languageCode(forName name: String) -> String? {
        let lowered = name.lowercased()
        let words = Set(lowered.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        let codes = Locale.isoLanguageCodes.filter { $0.count == 2 }
        // A bare code, two letters or three ("en", "eng", "pt-BR").
        if let first = lowered.split(whereSeparator: { !$0.isLetter }).first.map(String.init) {
            if first.count == 2, codes.contains(first), lowered.count <= 5 { return first }
            if first.count == 3, lowered.count <= 6, let two = alpha3[first] { return two }
        }
        // A language's name, in English or in itself.
        for code in codes {
            let names = [Locale(identifier: "en"), Locale(identifier: code)]
                .compactMap { $0.localizedString(forLanguageCode: code)?.lowercased() }
            if names.contains(where: { words.contains($0) || lowered.hasPrefix($0) }) { return code }
        }
        return nil
    }

    /// The three-letter codes subtitle tracks are labelled with in practice (ISO 639-2, both forms).
    private static let alpha3: [String: String] = [
        "eng": "en", "jpn": "ja", "spa": "es", "por": "pt", "fre": "fr", "fra": "fr", "ger": "de",
        "deu": "de", "ita": "it", "rus": "ru", "ara": "ar", "chi": "zh", "zho": "zh", "kor": "ko",
        "tha": "th", "vie": "vi", "ind": "id", "may": "ms", "msa": "ms", "tur": "tr", "pol": "pl",
        "hin": "hi", "dut": "nl", "nld": "nl", "swe": "sv", "fil": "fil", "heb": "he", "ukr": "uk",
    ]

    /// `master` with the subtitle rendition added and every variant pointed at it. A
    /// `SUBTITLES` group a variant already names is replaced: a variant takes one.
    static func inject(into master: String, mediaTag: String) -> String {
        var lines = master.components(separatedBy: .newlines)
        for i in lines.indices where lines[i].hasPrefix("#EXT-X-STREAM-INF:") {
            var line = lines[i]
            if let range = line.range(of: "(?<=[:,])SUBTITLES=\"[^\"]*\"", options: .regularExpression) {
                line.replaceSubrange(range, with: "SUBTITLES=\"\(groupID)\"")
            } else {
                line += ",SUBTITLES=\"\(groupID)\""
            }
            lines[i] = line
        }
        // Right after the header; the tags before any variant are global anyway.
        let at = lines.firstIndex { $0.hasPrefix("#EXTM3U") }.map { $0 + 1 } ?? 0
        lines.insert(mediaTag, at: at)
        return lines.joined(separator: "\n")
    }

    /// A master playlist with a single variant, `mediaPlaylistURL`, for a stream that is just a
    /// media playlist: a rendition can only be added to a master.
    static func wrap(mediaPlaylistURL: String, mediaTag: String) -> String {
        """
        #EXTM3U
        #EXT-X-VERSION:3
        \(mediaTag)
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,SUBTITLES="\(groupID)"
        \(mediaPlaylistURL)
        """
    }

    /// A subtitle playlist of one WebVTT segment covering the whole video.
    static func subtitlePlaylist(vttURL: String, duration: Double) -> String {
        let seconds = max(duration, 1)
        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(Int(seconds.rounded(.up)))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(String(format: "%.3f", seconds)),
        \(vttURL)
        #EXT-X-ENDLIST
        """
    }

    // MARK: WebVTT

    /// `cues` as WebVTT, mapped onto the stream's timestamps, which start at `firstTimestamp`
    /// (90 kHz).
    static func webVTT(cues: [SubtitleCue], firstTimestamp: Int64) -> String {
        var out = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:\(max(firstTimestamp, 0)),LOCAL:00:00:00.000\n"
        for cue in cues where cue.end > cue.start {
            // A blank line inside a cue would end it early.
            let text = cue.text
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
                .replacingOccurrences(of: "-->", with: "→")
            guard !text.isEmpty else { continue }
            out += "\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(text)\n"
        }
        return out
    }

    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// The dialogue of an ASS/SSA script as plain cues — what a receiver can show of it. Styling,
    /// positions and signs are libass's and don't survive; the words do.
    static func cues(fromASS script: String) -> [SubtitleCue] {
        var format: [String] = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inEvents = false
        var cues: [SubtitleCue] = []
        for raw in script.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst("format:".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:"),
                  let startIndex = format.firstIndex(of: "start"),
                  let endIndex = format.firstIndex(of: "end"),
                  let textIndex = format.firstIndex(of: "text") else { continue }
            // Text is last and may itself hold commas.
            let fields = line.dropFirst("dialogue:".count)
                .split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == format.count,
                  let start = assTime(fields[startIndex]), let end = assTime(fields[endIndex]) else { continue }
            let text = assText(fields[textIndex])
            guard !text.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// `H:MM:SS.cc` in seconds.
    private static func assTime(_ field: String) -> Double? {
        let parts = field.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// The words of an ASS text field: override blocks dropped, line breaks made real. A line that
    /// is only a drawing (`\p1`) carries no words.
    private static func assText(_ field: String) -> String {
        if field.range(of: "\\\\p[1-9]", options: .regularExpression) != nil { return "" }
        return field
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: First timestamp

    /// The earliest presentation timestamp (90 kHz) in the start of an MPEG-TS segment.
    static func firstTimestamp(transportStream data: Data) -> Int64? {
        let bytes = [UInt8](data)
        var earliest: Int64?
        var offset = 0
        while offset + 188 <= bytes.count {
            defer { offset += 188 }
            guard bytes[offset] == 0x47 else { continue }
            let payloadStart = bytes[offset + 1] & 0x40 != 0
            let adaptation = (bytes[offset + 3] >> 4) & 0x3
            guard payloadStart, adaptation & 0x1 != 0 else { continue }
            var at = offset + 4
            if adaptation & 0x2 != 0 { at += 1 + Int(bytes[at]) }
            // PES start code, a stream id, then flags with the PTS bit.
            guard at + 14 <= offset + 188, bytes[at] == 0, bytes[at + 1] == 0, bytes[at + 2] == 1,
                  bytes[at + 7] & 0x80 != 0 else { continue }
            let p = at + 9
            let pts = Int64(bytes[p] >> 1 & 0x07) << 30
                | Int64(bytes[p + 1]) << 22 | Int64(bytes[p + 2] >> 1) << 15
                | Int64(bytes[p + 3]) << 7 | Int64(bytes[p + 4] >> 1)
            earliest = min(earliest ?? pts, pts)
        }
        return earliest
    }

    /// The first fragment's decode time in 90 kHz, from an fMP4 init segment (for the timescale)
    /// and the start of the first media segment (for `tfdt`).
    static func firstTimestamp(fragmentedInit initData: Data, segment: Data) -> Int64? {
        guard let mdhd = findBox(["moov", "trak", "mdia", "mdhd"], in: [UInt8](initData)),
              let tfdt = findBox(["moof", "traf", "tfdt"], in: [UInt8](segment)) else { return nil }
        let timescale: UInt64 = mdhd.first == 1 ? readUInt(mdhd, at: 20, size: 4) : readUInt(mdhd, at: 12, size: 4)
        let decodeTime: UInt64 = tfdt.first == 1 ? readUInt(tfdt, at: 4, size: 8) : readUInt(tfdt, at: 4, size: 4)
        guard timescale > 0 else { return nil }
        return Int64(Double(decodeTime) * 90_000 / Double(timescale))
    }

    /// The payload of the box at `path` (each name a child of the one before), or nil.
    private static func findBox(_ path: [String], in bytes: [UInt8]) -> [UInt8]? {
        var region = bytes[...]
        for name in path {
            var found: ArraySlice<UInt8>?
            var at = region.startIndex
            while at + 8 <= region.endIndex {
                var size = Int(readUInt(Array(region[at..<at + 4]), at: 0, size: 4))
                let type = String(bytes: region[at + 4..<at + 8], encoding: .ascii)
                var header = 8
                if size == 1, at + 16 <= region.endIndex {
                    size = Int(readUInt(Array(region[at + 8..<at + 16]), at: 0, size: 8))
                    header = 16
                } else if size == 0 {
                    size = region.endIndex - at
                }
                guard size >= header else { return nil }
                let end = min(at + size, region.endIndex)
                if type == name { found = region[(at + header)..<end]; break }
                at += size
            }
            guard let found else { return nil }
            region = found
        }
        return Array(region)
    }

    private static func readUInt(_ bytes: [UInt8], at offset: Int, size: Int) -> UInt64 {
        guard offset + size <= bytes.count else { return 0 }
        return bytes[offset..<offset + size].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
