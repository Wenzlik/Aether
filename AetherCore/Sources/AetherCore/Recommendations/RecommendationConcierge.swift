import Foundation
import os

#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// The result of a recommendation request — a single grounded pick, an optional
/// one-line reason, and the candidate shortlist it was chosen from.
public struct RecommendationResult: Sendable, Equatable {
    /// The recommended title, or `nil` when nothing matched.
    public let pick: UnifiedMediaItem?
    /// A short, spoiler-free reason — only present when the on-device model
    /// produced one (the deterministic fallback has no prose).
    public let reason: String?
    /// The full candidate shortlist the engine produced (and, on the AI path,
    /// the set the model was allowed to choose from).
    public let shortlist: [UnifiedMediaItem]
    /// `true` when an on-device model produced this result; `false` for the
    /// deterministic keyword fallback (tvOS, ineligible devices, errors).
    public let usedAI: Bool

    public init(
        pick: UnifiedMediaItem?,
        reason: String?,
        shortlist: [UnifiedMediaItem],
        usedAI: Bool
    ) {
        self.pick = pick
        self.reason = reason
        self.shortlist = shortlist
        self.usedAI = usedAI
    }

    public var isEmpty: Bool { pick == nil }
}

/// Natural-language recommendations over the user's own library.
///
/// On Apple-Intelligence platforms (iOS / iPadOS / macOS / visionOS 26+) it uses
/// the on-device **Foundation Models** to (1) turn free text into a structured
/// filter and (2) pick + explain a title from the engine's shortlist — **by id**,
/// so it can only ever recommend something the user actually owns. Everywhere
/// else (tvOS, ineligible devices) and on any failure it falls back to the
/// deterministic `RecommendationQueryParser` + `RecommendationEngine`.
///
/// See `docs/next-steps/0.9-apple-intelligence.md`.
public struct RecommendationConcierge: Sendable {
    public init() {}

    /// Quality telemetry — **local only** (os_log), never the network: the
    /// privacy-first principle means the request text never leaves the device,
    /// so we log only non-identifying outcome metadata (which path ran, whether
    /// a pick surfaced, shortlist size, latency). Visible in Console.app /
    /// `log stream --predicate 'subsystem == "cz.zmrhal.aether"'`.
    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "recommendations")

    /// Whether an on-device model is available right now (compile-time framework
    /// presence + runtime eligibility / enablement / readiness).
    public static var isAvailable: Bool {
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(iOS 26, macOS 26, visionOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        return false
        #else
        return false
        #endif
    }

    /// Recommend a title for a free-text request. Never throws — it always
    /// returns a result (possibly empty), degrading to the deterministic path
    /// when the model is unavailable or errors.
    /// - Parameters:
    ///   - useAI: when `false`, skip the on-device model and use the
    ///     deterministic path even where Apple Intelligence is available (the
    ///     user's "Use Apple Intelligence" Settings toggle).
    ///   - excludeWatched: leave already-watched titles out of the candidates.
    ///   - personalize: when `true` (default), the shortlist is ranked with a
    ///     `TasteProfile` learned from the library's own watch-state, so titles
    ///     in genres the user tends to watch, favourite, or rate highly rise
    ///     within an equally-good match. The explicit request always wins; taste
    ///     only breaks ties (and drives a genre-less "recommend me something").
    ///   - reasonLanguage: BCP-47 code (`"en"`, `"cs"`, `"uk"`, …) the model
    ///     should write the reason in — usually the app's UI language. `nil`
    ///     leaves the model to answer in its default (English).
    ///   - enrich: optional async hook that, given the engine's shortlist,
    ///     returns extra per-item context keyed by `UnifiedMediaItem.id` (e.g.
    ///     TMDb keywords) to fold into the model's candidate descriptions. Lets
    ///     the app inject network-backed metadata without `AetherCore` depending
    ///     on TMDb.
    public func recommend(
        query: String,
        in library: [UnifiedMediaItem],
        useAI: Bool = true,
        excludeWatched: Bool = true,
        personalize: Bool = true,
        reasonLanguage: String? = nil,
        engine: RecommendationEngine = RecommendationEngine(),
        parser: RecommendationQueryParser = RecommendationQueryParser(),
        enrich: (@Sendable ([UnifiedMediaItem]) async -> [String: [String]])? = nil
    ) async -> RecommendationResult {
        let clock = ContinuousClock()
        let start = clock.now

        // Learn taste from the same library snapshot (watched / favourited /
        // highly-rated titles). Pure + in-memory — no I/O, works on every path.
        let taste = personalize ? TasteProfile.from(library: library) : nil

        #if canImport(FoundationModels) && !os(tvOS)
        if useAI, #available(iOS 26, macOS 26, visionOS 26, *), Self.isAvailable {
            do {
                let result = try await aiRecommend(
                    query: query, in: library, engine: engine,
                    excludeWatched: excludeWatched, taste: taste,
                    reasonLanguage: reasonLanguage, enrich: enrich
                )
                Self.logOutcome(result, elapsed: start.duration(to: clock.now))
                return result
            } catch {
                Self.log.error("AI recommend failed, falling back to deterministic: \(String(describing: error), privacy: .public)")
            }
        }
        #endif
        let result = deterministic(query: query, in: library, engine: engine, parser: parser, excludeWatched: excludeWatched, taste: taste)
        Self.logOutcome(result, elapsed: start.duration(to: clock.now))
        return result
    }

    /// Log non-identifying outcome metadata for one recommendation (see `log`).
    private static func logOutcome(_ result: RecommendationResult, elapsed: Duration) {
        let ms = elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        log.info("recommend usedAI=\(result.usedAI, privacy: .public) pick=\(result.pick != nil, privacy: .public) shortlist=\(result.shortlist.count, privacy: .public) latency=\(ms, privacy: .public)ms")
    }

    // MARK: - Deterministic fallback (all platforms)

    private func deterministic(
        query: String,
        in library: [UnifiedMediaItem],
        engine: RecommendationEngine,
        parser: RecommendationQueryParser,
        excludeWatched: Bool,
        taste: TasteProfile?
    ) -> RecommendationResult {
        var request = parser.parse(query, availableGenres: engine.availableGenres(in: library))
        request.excludeWatched = excludeWatched
        let shortlist = engine.recommend(from: library, request: request, taste: taste)
        return RecommendationResult(pick: shortlist.first, reason: nil, shortlist: shortlist, usedAI: false)
    }

    /// Resolve the model's chosen id back to a real shortlist item. Falls back to
    /// the top candidate when the model returns an id outside the shortlist —
    /// the last guard against a hallucinated pick. Pure + testable.
    static func resolve(pickID: String, in shortlist: [UnifiedMediaItem]) -> UnifiedMediaItem? {
        shortlist.first { $0.id == pickID } ?? shortlist.first
    }

    /// Map the model's free-text media type to a concrete kind.
    static func mediaKind(from raw: String) -> MediaItem.Kind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "movie", "movies", "film": return .movie
        case "show", "shows", "series", "tv": return .show
        default: return nil
        }
    }

    // MARK: - On-device model path

    #if canImport(FoundationModels) && !os(tvOS)
    /// English name of a BCP-47 language code, used to tell the model which
    /// language to write the reason in. `nil` for nil/empty → model default.
    static func languageName(for code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let base = String(code.prefix(2)).lowercased()
        switch base {
        case "en": return "English"
        case "cs": return "Czech"
        case "uk": return "Ukrainian"
        default:   return Locale(identifier: "en").localizedString(forLanguageCode: base)
        }
    }

    @available(iOS 26, macOS 26, visionOS 26, *)
    private func aiRecommend(
        query: String,
        in library: [UnifiedMediaItem],
        engine: RecommendationEngine,
        excludeWatched: Bool,
        taste: TasteProfile?,
        reasonLanguage: String?,
        enrich: (@Sendable ([UnifiedMediaItem]) async -> [String: [String]])?
    ) async throws -> RecommendationResult {
        let availableGenres = engine.availableGenres(in: library)

        // Step 1 — natural language → structured filter.
        let parseSession = LanguageModelSession {
            "You convert a user's request into a structured filter for their personal movie and TV library."
            "Available genres: \(availableGenres.joined(separator: ", "))."
            "Only choose genres from that list. Map moods (e.g. 'scary' to Horror) to the closest available genre."
            "kind must be exactly 'movie', 'show', or 'any'. maxMinutes is a runtime cap in minutes; use 0 for no limit."
        }
        let parsed = try await parseSession.respond(to: query, generating: ParsedQuery.self).content

        let request = RecommendationRequest(
            genres: parsed.genres,
            type: Self.mediaKind(from: parsed.kind),
            maxRuntime: parsed.maxMinutes > 0 ? .seconds(parsed.maxMinutes * 60) : nil,
            excludeWatched: excludeWatched,
            limit: 12
        )
        let shortlist = engine.recommend(from: library, request: request, taste: taste)
        guard !shortlist.isEmpty else {
            return RecommendationResult(pick: nil, reason: nil, shortlist: [], usedAI: true)
        }

        // Optional themed metadata (e.g. TMDb keywords) for the shortlist, so the
        // model can reason thematically ("a heist movie" → favours a heist-tagged
        // candidate). Injected by the app; empty when unavailable.
        let topShortlist = Array(shortlist.prefix(10))
        let keywordMap = await enrich?(topShortlist) ?? [:]

        // Step 2 — pick + explain, grounded to the shortlist (by id).
        let candidates = topShortlist.map { item -> String in
            let rating = item.tmdbRating ?? item.communityRating ?? 0
            let year = item.year.map { " (\($0))" } ?? ""
            let synopsis = item.overview.map { String($0.prefix(160)) } ?? ""
            let themes = (keywordMap[item.id]?.isEmpty == false)
                ? " | themes: \(keywordMap[item.id]!.joined(separator: ", "))"
                : ""
            return "id=\(item.id) | \(item.title)\(year) | rating \(rating) | \(synopsis)\(themes)"
        }.joined(separator: "\n")

        let reasonLang = Self.languageName(for: reasonLanguage)
        let pickSession = LanguageModelSession {
            "You are a film concierge for the user's personal library."
            "Recommend exactly one title from the candidates that best fits the request."
            "Copy the chosen id EXACTLY from the list — never invent one."
            "Give one short, spoiler-free sentence on why it fits."
            if let reasonLang { "Write the reason in \(reasonLang)." }
        }
        let pick = try await pickSession.respond(
            to: "Request: \(query)\n\nCandidates:\n\(candidates)",
            generating: Pick.self
        ).content

        if shortlist.first(where: { $0.id == pick.id }) == nil {
            // Model returned an id outside the shortlist — the resolve() guard
            // recovers, but it's worth knowing the grounding slipped.
            Self.log.warning("model returned out-of-shortlist id; using top candidate")
        }

        return RecommendationResult(
            pick: Self.resolve(pickID: pick.id, in: shortlist),
            reason: pick.reason,
            shortlist: shortlist,
            usedAI: true
        )
    }
    #endif
}

#if canImport(FoundationModels) && !os(tvOS)
@available(iOS 26, macOS 26, visionOS 26, *)
@Generable
private struct ParsedQuery {
    @Guide(description: "Genres to match, chosen only from the provided list. Empty if none implied.")
    let genres: [String]
    @Guide(description: "Exactly 'movie', 'show', or 'any'.")
    let kind: String
    @Guide(description: "Maximum runtime in minutes; 0 means no limit.")
    let maxMinutes: Int
}

@available(iOS 26, macOS 26, visionOS 26, *)
@Generable
private struct Pick {
    @Guide(description: "The id of the chosen title, copied exactly from the candidates.")
    let id: String
    @Guide(description: "One short, spoiler-free sentence on why this title fits.")
    let reason: String
}
#endif
