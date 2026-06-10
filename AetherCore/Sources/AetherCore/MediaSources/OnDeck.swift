import Foundation

/// Picks a TV show's **On Deck** episode (#260) — the one a user means when they
/// open a show: continue what you're in the middle of, otherwise start the next
/// one. Pure + testable (the show-page Next Up bug lived in an inline view
/// version that picked "the first season with an unwatched episode", surfacing
/// e.g. Season 3 while the user was mid-Season 7).
public enum OnDeck {

    /// The On Deck episode, in priority order:
    /// 1. the **most-recently-active in-progress** episode, or
    /// 2. the episode **following the last one watched** (in season/episode
    ///    order), or the first episode if none are watched.
    /// Returns `nil` only when the whole show is watched (nothing left) or there
    /// are no episodes.
    ///
    /// - Parameter inProgressActivity: returns the resume timestamp for an
    ///   episode that is *in progress* (has a resume point and isn't fully
    ///   watched), else `nil`. Keeps this function free of resume-store types.
    public static func next(
        episodes: [MediaItem],
        inProgressActivity: (MediaItem) -> Date?
    ) -> MediaItem? {
        // 1. Most-recently-active in-progress episode. (Built with an explicit
        //    loop — the nested compactMap/map tuple tripped the type-checker.)
        var active: [(episode: MediaItem, activity: Date)] = []
        for episode in episodes {
            if let activity = inProgressActivity(episode) {
                active.append((episode, activity))
            }
        }
        if let best = active.max(by: { $0.activity < $1.activity }) { return best.episode }

        // 2. The episode after the last one watched, in order.
        let ordered = episodes.sorted { a, b in
            let sa = a.seasonNumber ?? 0, sb = b.seasonNumber ?? 0
            if sa != sb { return sa < sb }
            return (a.episodeNumber ?? 0) < (b.episodeNumber ?? 0)
        }
        if let last = ordered.lastIndex(where: { $0.isWatched }) {
            return ordered.indices.contains(last + 1) ? ordered[last + 1] : nil
        }
        return ordered.first
    }
}
