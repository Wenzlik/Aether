import Foundation

/// What a configured SMB folder holds, chosen by the user when picking it.
/// `movies` = never group into shows; `series` = group every file under its
/// folder as one show (even without an SxxExx marker); `both` = auto-detect.
/// `.both` preserves the original heuristic (and is the default for folders
/// configured before this choice existed).
public enum SMBRootContent: String, Codable, Hashable, Sendable, CaseIterable {
    case both, movies, series
}

/// Classifies SMB video files by the **role of their containing folder** rather
/// than per-filename guesses (#481).
///
/// SMB has no catalog, so the library is inferred from files. Deciding
/// movie-vs-episode per filename is fragile: a series whose episodes parse to
/// slightly different titles fragments into many one-episode "shows", and files
/// that don't parse a `SxxExx` marker leak into Movies as loose items. The
/// folder is the reliable signal — all videos in one series folder belong to one
/// show. This groups files by their **series folder** (the path with trailing
/// `Season NN` folders stripped) and, when a folder looks like a series, marks
/// *every* file in it an episode of one show named after the folder.
public enum SMBFolderClassifier {

    /// One file's folder path (share + directories leading to it, no filename)
    /// and whether its filename parsed as an episode.
    public struct Entry: Sendable, Equatable {
        public let folderComponents: [String]
        public let isEpisode: Bool
        /// The user's content choice for the root this file came from.
        public let content: SMBRootContent
        public init(folderComponents: [String], isEpisode: Bool, content: SMBRootContent = .both) {
            self.folderComponents = folderComponents
            self.isEpisode = isEpisode
            self.content = content
        }
    }

    /// The resolved role for a file. `seriesKey`/`seriesName` are set only when
    /// the file belongs to a series folder (the key groups its episodes; the
    /// name is the folder, used as the show title when TMDb doesn't match).
    public struct Classification: Sendable, Equatable {
        public let isEpisode: Bool
        public let seriesKey: String?
        public let seriesName: String?
        public init(isEpisode: Bool, seriesKey: String? = nil, seriesName: String? = nil) {
            self.isEpisode = isEpisode
            self.seriesKey = seriesKey
            self.seriesName = seriesName
        }
    }

    /// Classify each entry; the result array is parallel to `entries`.
    ///
    /// With `content == .both` a folder is treated as a **series** when it sits
    /// above a `Season NN` subfolder, or when ≥2 of its files parsed as episodes
    /// — a strong enough signal that mis-classifying a flat folder of distinct
    /// movies is unlikely. `.movies` never groups (everything stays a movie) and
    /// `.series` always groups (every file becomes an episode of one show named
    /// after the folder, even without an SxxExx marker — the user told us so).
    public static func classify(_ entries: [Entry]) -> [Classification] {
        let folders = entries.map { stripSeasonFolders($0.folderComponents) }

        var indicesByFolder: [String: [Int]] = [:]
        for i in entries.indices {
            indicesByFolder[folders[i].path.joined(separator: "/"), default: []].append(i)
        }

        var result = [Classification](repeating: Classification(isEpisode: false), count: entries.count)
        for (key, indices) in indicesByFolder {
            // A series folder belongs to one configured root, so its files share a
            // content choice; a folder spanning roots of different types falls back
            // to auto-detect.
            let kinds = Set(indices.map { entries[$0].content })
            let content: SMBRootContent = kinds.count == 1 ? (kinds.first ?? .both) : .both

            let isSeries: Bool
            switch content {
            case .movies: isSeries = false
            case .series: isSeries = true
            case .both:
                let episodeCount = indices.filter { entries[$0].isEpisode }.count
                let underSeasonFolder = indices.contains { folders[$0].underSeason }
                isSeries = underSeasonFolder || episodeCount >= 2
            }
            guard isSeries else { continue }   // else: leave as movies

            let name = folders[indices[0]].path.last ?? "Series"
            for i in indices {
                result[i] = Classification(isEpisode: true, seriesKey: key, seriesName: name)
            }
        }
        return result
    }

    /// The series folder: drop trailing `Season NN` components. `underSeason` is
    /// true when at least one was dropped (a strong series signal).
    static func stripSeasonFolders(_ components: [String]) -> (path: [String], underSeason: Bool) {
        var path = components
        var underSeason = false
        while let last = path.last, isSeasonFolder(last) {
            path.removeLast()
            underSeason = true
        }
        return (path, underSeason)
    }

    /// A "Season N" folder — `Season 1`, `Season 01`, `Series 2` (UK), `Saison 1`,
    /// `Staffel 1`, or compact `S1`/`S01`. Requires a trailing number so a bare
    /// container folder named "Season"/"Series" isn't mistaken for one.
    static func isSeasonFolder(_ name: String) -> Bool {
        let s = name.lowercased().trimmingCharacters(in: .whitespaces)
        for word in ["season", "series", "saison", "staffel"] where s.hasPrefix(word) {
            let rest = s.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, Int(rest) != nil { return true }
        }
        // Compact `s1` / `s01` (not a longer word that merely starts with "s").
        if s.count >= 2, s.count <= 4, s.hasPrefix("s"), Int(s.dropFirst()) != nil { return true }
        return false
    }
}
