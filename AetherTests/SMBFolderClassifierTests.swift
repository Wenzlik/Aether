import Testing
@testable import AetherCore

/// Tests for folder-role classification of SMB files (#481) — the library is
/// built from folder structure, not per-filename guesses.
@Suite("AetherCore — SMBFolderClassifier (#481)")
struct SMBFolderClassifierTests {

    private func entry(_ folder: [String], episode: Bool,
                       content: SMBRootContent = .both) -> SMBFolderClassifier.Entry {
        .init(folderComponents: folder, isEpisode: episode, content: content)
    }

    @Test("content == .series forces grouping even with no SxxExx and no Season folder")
    func forcedSeriesGroupsFlatFolder() {
        // A flat series folder whose files don't parse as episodes (e.g. anime
        // "Show - 01") would auto-detect as movies; .series forces one show.
        let entries = [
            entry(["TV", "Vinland Saga"], episode: false, content: .series),
            entry(["TV", "Vinland Saga"], episode: false, content: .series),
        ]
        let result = SMBFolderClassifier.classify(entries)
        #expect(result.allSatisfy { $0.isEpisode })
        #expect(Set(result.map { $0.seriesKey }) == ["TV/Vinland Saga"])
        #expect(Set(result.map { $0.seriesName }) == ["Vinland Saga"])
    }

    @Test("content == .movies never groups, even with SxxExx-parsed files")
    func forcedMoviesNeverGroups() {
        // Files that parse as episodes in a Season-style folder would normally
        // group; .movies keeps every file a movie (the user said it's films).
        let entries = [
            entry(["Films", "Collection", "Season 1"], episode: true, content: .movies),
            entry(["Films", "Collection", "Season 1"], episode: true, content: .movies),
        ]
        let result = SMBFolderClassifier.classify(entries)
        #expect(result.allSatisfy { !$0.isEpisode })
        #expect(result.allSatisfy { $0.seriesKey == nil })
    }

    @Test("flat folder of distinct movies → all movies, no series")
    func flatMovies() {
        let entries = [
            entry(["HD", "Movies"], episode: false),
            entry(["HD", "Movies"], episode: false),
            entry(["HD", "Movies"], episode: false),
        ]
        let result = SMBFolderClassifier.classify(entries)
        #expect(result.allSatisfy { !$0.isEpisode })
        #expect(result.allSatisfy { $0.seriesKey == nil })
    }

    @Test("Season folders → all episodes of one show named after the series folder")
    func seasonFolders() {
        let entries = [
            entry(["TV", "Breaking Bad", "Season 1"], episode: true),
            entry(["TV", "Breaking Bad", "Season 1"], episode: true),
            entry(["TV", "Breaking Bad", "Season 2"], episode: true),
        ]
        let result = SMBFolderClassifier.classify(entries)
        #expect(result.allSatisfy { $0.isEpisode })
        #expect(Set(result.map { $0.seriesKey }) == ["TV/Breaking Bad"])
        #expect(Set(result.map { $0.seriesName }) == ["Breaking Bad"])
    }

    @Test("a non-episode file under a Season folder is still folded into the show")
    func nonEpisodeUnderSeasonFolder() {
        let entries = [
            entry(["TV", "The Wire", "Season 1"], episode: true),
            entry(["TV", "The Wire", "Season 1"], episode: true),
            entry(["TV", "The Wire", "Season 1"], episode: false),  // oddly-named extra
        ]
        let result = SMBFolderClassifier.classify(entries)
        #expect(result.allSatisfy { $0.isEpisode && $0.seriesName == "The Wire" })
    }

    @Test("no Season folder but ≥2 parsed episodes → still one show by folder")
    func episodesWithoutSeasonFolder() {
        let entries = [
            entry(["TV", "Chernobyl"], episode: true),
            entry(["TV", "Chernobyl"], episode: true),
        ]
        let result = SMBFolderClassifier.classify(entries)
        #expect(result.allSatisfy { $0.isEpisode && $0.seriesKey == "TV/Chernobyl" && $0.seriesName == "Chernobyl" })
    }

    @Test("episodes that parsed to different titles still group by their folder")
    func inconsistentTitlesGroupByFolder() {
        // The core fix: grouping is by folder, so filename-title variance across
        // episodes no longer fragments the show.
        let entries = [
            entry(["TV", "Show"], episode: true),
            entry(["TV", "Show"], episode: true),
            entry(["TV", "Show"], episode: true),
        ]
        let result = SMBFolderClassifier.classify(entries)
        #expect(Set(result.map { $0.seriesKey }) == ["TV/Show"])   // one group
    }

    @Test("a lone false-positive episode in a movies folder stays a movie")
    func falsePositiveEpisodeInMovies() {
        let entries = [
            entry(["HD", "Movies"], episode: false),
            entry(["HD", "Movies"], episode: true),   // a movie whose name happened to parse as SxxExx
            entry(["HD", "Movies"], episode: false),
        ]
        let result = SMBFolderClassifier.classify(entries)
        // Only 1 episode-parse and no Season folder → not a series; all movies.
        #expect(result.allSatisfy { !$0.isEpisode })
    }

    @Test("season-folder detection: words + compact forms, requires a number")
    func seasonFolderMatcher() {
        #expect(SMBFolderClassifier.isSeasonFolder("Season 1"))
        #expect(SMBFolderClassifier.isSeasonFolder("Season 01"))
        #expect(SMBFolderClassifier.isSeasonFolder("Series 2"))
        #expect(SMBFolderClassifier.isSeasonFolder("Saison 3"))
        #expect(SMBFolderClassifier.isSeasonFolder("Staffel 4"))
        #expect(SMBFolderClassifier.isSeasonFolder("S1"))
        #expect(SMBFolderClassifier.isSeasonFolder("S03"))
        // Not season folders:
        #expect(!SMBFolderClassifier.isSeasonFolder("Series"))   // no number → a container, not a season
        #expect(!SMBFolderClassifier.isSeasonFolder("Season"))
        #expect(!SMBFolderClassifier.isSeasonFolder("Studio"))   // starts with 's' but not S<number>
        #expect(!SMBFolderClassifier.isSeasonFolder("Breaking Bad"))
    }

    @Test("distinct series folders don't merge")
    func distinctSeriesStaySeparate() {
        let entries = [
            entry(["TV", "Show A", "Season 1"], episode: true),
            entry(["TV", "Show B", "Season 1"], episode: true),
        ]
        let result = SMBFolderClassifier.classify(entries)
        #expect(Set(result.compactMap { $0.seriesKey }) == ["TV/Show A", "TV/Show B"])
    }
}
