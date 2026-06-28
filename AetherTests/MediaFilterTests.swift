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

    // MARK: - Code variants (Jellyfin server-side filter)

    @Test("variants(of:) expands a canonical key to its 2- and 3-letter forms")
    func variantsExpansion() {
        // cs → itself + both ISO 639-2 forms (terminological + bibliographic).
        #expect(Set(AudioLanguage.variants(of: "cs")) == ["cs", "ces", "cze"])
        #expect(Set(AudioLanguage.variants(of: "en")) == ["en", "eng"])
        #expect(Set(AudioLanguage.variants(of: "de")) == ["de", "deu", "ger"])
        // A canonical key with no 3-letter mapping just returns itself.
        #expect(AudioLanguage.variants(of: "xx") == ["xx"])
        // Every variant folds back to the canonical key it came from (round-trip).
        for code in ["cs", "en", "de", "fr", "ja"] {
            #expect(AudioLanguage.variants(of: code).allSatisfy { AudioLanguage.canonical($0) == code })
        }
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
