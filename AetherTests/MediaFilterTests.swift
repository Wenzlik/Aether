import Testing
import Foundation
@testable import AetherCore

@Suite("MediaFilter / AudioLanguage (#295)")
struct MediaFilterTests {

    // MARK: - Canonicalization

    @Test("ISO 639-2/B and /T 3-letter codes fold to the same 2-letter key")
    func canonicalFolding() {
        #expect(AudioLanguage.canonical("eng") == "en")
        // Czech: bibliographic 'cze' and terminological 'ces' must agree, so a
        // Plex 'cze' title and a Jellyfin 'ces' title match the same filter.
        #expect(AudioLanguage.canonical("cze") == "cs")
        #expect(AudioLanguage.canonical("ces") == "cs")
        #expect(AudioLanguage.canonical("ger") == "de")
        #expect(AudioLanguage.canonical("deu") == "de")
        #expect(AudioLanguage.canonical("fre") == "fr")
        #expect(AudioLanguage.canonical("fra") == "fr")
    }

    @Test("2-letter codes pass through; case + whitespace normalized")
    func canonicalPassthrough() {
        #expect(AudioLanguage.canonical("en") == "en")
        #expect(AudioLanguage.canonical("EN") == "en")
        #expect(AudioLanguage.canonical(" cs ") == "cs")
    }

    @Test("Empty / und / nil map to the unknown sentinel")
    func canonicalUnknown() {
        #expect(AudioLanguage.canonical(nil) == AudioLanguage.unknown)
        #expect(AudioLanguage.canonical("") == AudioLanguage.unknown)
        #expect(AudioLanguage.canonical("und") == AudioLanguage.unknown)
        #expect(AudioLanguage.canonical("unknown") == AudioLanguage.unknown)
    }

    // MARK: - Options

    @Test("Options dedup across code variants and drop unknown")
    func optionsBuild() {
        let options = AudioLanguage.options(fromRawCodes: ["eng", "en", "cze", "ces", "und", nil, "jpn"])
        // eng/en → one 'en'; cze/ces → one 'cs'; und/nil dropped. (Order is by
        // localized display name, which is locale-dependent — assert the set.)
        #expect(Set(options.map(\.code)) == ["cs", "en", "ja"])
        #expect(options.count == 3)
        #expect(options.allSatisfy { $0.code != AudioLanguage.unknown })
        #expect(options.allSatisfy { !$0.displayName.isEmpty })
    }

    // MARK: - Local matching

    private func item(languages: [String?]) -> MediaItem {
        MediaItem(
            id: .init(source: .jellyfin(serverID: "s"), rawValue: "i\(languages.count)\(languages.compactMap { $0 }.joined())"),
            title: "Film",
            kind: .movie,
            audioTracks: languages.enumerated().map { index, code in
                MediaAudioTrack(id: "\(index)", title: "Track", languageCode: code)
            }
        )
    }

    @Test("matchesLocally: a title matches when any audio track is in the language")
    func matchesAnyTrack() {
        let bilingual = item(languages: ["eng", "ces"])
        #expect(MediaFilter(audioLanguage: "en").matchesLocally(bilingual))
        #expect(MediaFilter(audioLanguage: "cs").matchesLocally(bilingual))
        #expect(!MediaFilter(audioLanguage: "ja").matchesLocally(bilingual))
    }

    @Test("matchesLocally: no audio-track data can't match a specific language")
    func unknownDoesNotMatch() {
        let noTracks = item(languages: [])
        #expect(!MediaFilter(audioLanguage: "en").matchesLocally(noTracks))
        let undTrack = item(languages: ["und"])
        #expect(!MediaFilter(audioLanguage: "en").matchesLocally(undTrack))
    }

    @Test("matchesLocally: an inactive filter (nil) matches everything")
    func inactiveMatchesAll() {
        #expect(MediaFilter.none.matchesLocally(item(languages: [])))
        #expect(!MediaFilter.none.isActive)
        #expect(MediaFilter(audioLanguage: "en").isActive)
    }
}
