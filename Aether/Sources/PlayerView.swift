import SwiftUI
import AVKit
import Combine
import AetherCore

/// Full-screen player. Deliberately bare: `AVPlayerViewController`'s native
/// transport owns Play/Pause, Seek, and the Audio / Subtitle media-options
/// picker (HLS renditions for transcode titles), so Aether adds only what the
/// system doesn't — a Back affordance on iOS — and otherwise gets out of the
/// way. Primary audio / subtitle selection already happened on Detail.
///
/// Chrome auto-hides ~2.5s after the last interaction and reveals on tap, so
/// when the user isn't touching anything it's 100% content. No permanent
/// overlays, no floating buttons left behind.
struct PlayerView: View {
    let item: MediaItem
    /// The source the item came from — resolves a fresh playback URL (new Plex
    /// transcode session) on open / retry, instead of replaying a stale one.
    let source: (any MediaSource)?
    /// Where playback should begin. `nil` resumes from the persisted point;
    /// `0` (or any explicit value) starts there, ignoring the saved resume.
    let startAt: Double?
    let onDismiss: () -> Void
    /// Playback defaults — drives Skip Intro / Skip Credits (Button /
    /// Automatically / Off). `nil` falls back to "Show Button".
    let playbackPreferences: PlaybackPreferencesStore?
    @State private var viewModel: PlayerStateViewModel
    @State private var showFailureDetails = false
    /// Foreground/background — drives suspending the UI-refresh poll while
    /// backgrounded (audio keeps playing; we just stop the 500 ms CPU churn).
    @Environment(\.scenePhase) private var scenePhase
    /// Segments already auto-skipped this session, so `.automatically` fires
    /// once per segment instead of on every time tick.
    @State private var autoSkipped: Set<String> = []
    /// The resolved next episode (Auto-Play-Next), fetched on open.
    @State private var nextItem: MediaItem?
    /// Seconds left on the "Next Episode" countdown; `nil` when not counting.
    @State private var countdownRemaining: Int?
    @State private var countdownTask: Task<Void, Never>?

    /// Chrome auto-hide window — short, so controls don't linger over the video.
    private static let chromeIdleHide: Duration = .milliseconds(2500)

    #if os(iOS)
    @State private var isCloseVisible = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Live vertical offset while the user is swiping the player down to dismiss
    /// (#288). 0 when at rest; follows the finger during a deliberate downward
    /// drag, then either commits to dismiss or springs back.
    @State private var dragOffset: CGFloat = 0
    #endif

    /// visionOS only: auto-expand the system player so it docks into an open
    /// immersive space without a manual expand tap. Set by Cinema Mode.
    let preferExpanded: Bool
    /// visionOS only: bumped when the cinema size/seat changes, so the docked
    /// player re-docks to re-fit. `nil` for windowed playback.
    let redockToken: UUID?
    /// visionOS Cinema only: builds the Screen-size + Seat panel for the player's
    /// Info panel (`customInfoViewControllers`). `nil` for windowed playback.
    let makeCinemaInfoControllers: (() -> [UIViewController])?

    init(
        item: MediaItem,
        source: (any MediaSource)?,
        session: PlaybackSession,
        startAt: Double? = nil,
        preferExpanded: Bool = false,
        redockToken: UUID? = nil,
        makeCinemaInfoControllers: (() -> [UIViewController])? = nil,
        playbackPreferences: PlaybackPreferencesStore? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.item = item
        self.source = source
        self.startAt = startAt
        self.preferExpanded = preferExpanded
        self.redockToken = redockToken
        self.makeCinemaInfoControllers = makeCinemaInfoControllers
        self.playbackPreferences = playbackPreferences
        self.onDismiss = onDismiss
        _viewModel = State(initialValue: PlayerStateViewModel(session: session))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.state.status == .failed {
                playbackFailed
            } else if let player = viewModel.player {
                SystemVideoPlayer(
                    player: player,
                    preferExpanded: preferExpanded,
                    redockToken: redockToken,
                    makeCinemaInfoControllers: makeCinemaInfoControllers,
                    onDismiss: {
                        Task { await dismissPlayer() }
                    }
                )
                #if os(visionOS)
                .safeAreaPadding(.top, AetherDesign.Spacing.l)
                #else
                .ignoresSafeArea()
                #endif
                #if os(iOS)
                // Swipe-down-to-dismiss (#288): the player slides with the finger
                // and commits past a high threshold. `simultaneousGesture` so it
                // never steals touches from AVKit's transport (scrubber/menus).
                .offset(y: dragOffset)
                .simultaneousGesture(swipeDownDismissGesture)
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.85), value: dragOffset)
                #endif
            } else {
                ProgressView()
                    .tint(AetherDesign.Palette.textPrimary)
            }

            #if os(iOS)
            // iOS-only Back affordance. visionOS dismisses through AVKit's
            // native `Back` contextual action; tvOS through the Menu button
            // (`.onExitCommand`) and the native `Done` action — neither needs a
            // SwiftUI overlay, which would just duplicate system chrome.
            closeButton
                .zIndex(20)
                .opacity(effectiveChromeVisibility ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.25),
                    value: effectiveChromeVisibility
                )
                .allowsHitTesting(effectiveChromeVisibility)
            #endif

            skipOverlay
                .zIndex(25)

            nextEpisodeOverlay
                .zIndex(26)
        }
        .onChange(of: viewModel.currentSeconds) { _, _ in
            autoSkipIfNeeded()
            updateNextEpisodePrompt()
        }
        #if os(iOS)
        // `simultaneousGesture` keeps AVPlayer's own tap-to-toggle-chrome intact
        // while letting us mirror its visibility on the Back button. Without the
        // simultaneous variant our tap would consume the touch and the native
        // transport bar would stop responding.
        .simultaneousGesture(TapGesture().onEnded { revealChrome() })
        #endif
        .task {
            await viewModel.open(item, source: source, startAt: startAt)
            await loadNextItem()
            #if os(iOS)
            if viewModel.player != nil { scheduleChromeHide() }
            #endif
        }
        // Suspend the 500 ms UI-refresh poll while backgrounded (no visible
        // player UI to update) so the app stops burning CPU behind the lock
        // screen; resume on return to foreground. Audio keeps playing.
        .onChange(of: scenePhase) { _, phase in
            viewModel.setAppActive(phase == .active)
            // Don't tick the once-a-second next-episode countdown (or auto-play
            // the next item) while backgrounded — it re-arms on return to
            // foreground when the prompt is re-evaluated.
            if phase != .active { cancelCountdown() }
        }
        .onDisappear {
            cancelCountdown()
            Task { await viewModel.close() }
            // `onDisappear` is the reliable "player is gone" signal — it fires
            // even when the system dismisses a *docked* player without our Back
            // action or an end-of-playback event. Route it through `onDismiss`
            // so the host tears down too; in Cinema Mode that's what closes the
            // Dark Theater (otherwise the immersive space stays open → black
            // screen). `onDismiss` (DetailView.dismissPlayer / cinema.end) is
            // idempotent, so the normal Back / end paths calling it first is fine.
            onDismiss()
            #if os(iOS)
            hideTask?.cancel()
            #endif
        }
        // When the movie plays to its end, dismiss — so windowed playback
        // returns to Detail and, in Cinema Mode (visionOS), the immersive Dark
        // Theater closes instead of leaving the user in a black void. Runs on
        // the main actor (SwiftUI `onReceive`), so no data-race plumbing.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let current = viewModel.player?.currentItem,
                  (note.object as? AVPlayerItem) === current else { return }
            // Played to the end → auto-advance to the next episode if enabled
            // and one exists (`playNext` also marks the finished one watched);
            // otherwise mark watched and dismiss.
            if autoPlayNext, nextItem != nil {
                Task { await playNext() }
            } else {
                let finishedID = viewModel.state.item?.id ?? item.id
                if let source { Task { await source.markWatched(finishedID) } }
                Task { await dismissPlayer() }
            }
        }
        #if os(tvOS)
        .onExitCommand { Task { await dismissPlayer() } }
        #endif
    }

    // MARK: - Skip Intro / Credits

    private var introMode: SkipMode { playbackPreferences?.skipIntro ?? .button }
    private var creditsMode: SkipMode { playbackPreferences?.skipCredits ?? .button }

    /// The intro/recap segment active right now, unless Skip Intro is Off.
    private var activeIntro: PlaybackSegment? {
        guard introMode != .off else { return nil }
        return viewModel.segments.introSegment(at: viewModel.currentSeconds)
    }

    /// The credits segment active right now, unless Skip Credits is Off.
    private var activeCredits: PlaybackSegment? {
        guard creditsMode != .off else { return nil }
        return viewModel.segments.creditsSegment(at: viewModel.currentSeconds)
    }

    /// Bottom-trailing skip button, shown only while inside a segment whose mode
    /// is "Show Button". Intro takes precedence over credits if they overlap.
    @ViewBuilder
    private var skipOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if introMode == .button, let intro = activeIntro {
                    skipButton("Skip Intro", to: intro.end)
                } else if creditsMode == .button, let credits = activeCredits, countdownRemaining == nil {
                    // The Next Episode countdown card supersedes Skip Credits.
                    skipButton("Skip Credits", to: credits.end)
                }
            }
        }
        .padding(AetherDesign.Spacing.xl)
    }

    private func skipButton(_ title: String, to target: Double) -> some View {
        AetherButton(title, systemImage: "forward.end.fill", role: .secondary) {
            Task { await viewModel.skip(toContentSeconds: target) }
        }
    }

    // MARK: - Auto-Play-Next

    private var autoPlayNext: Bool { playbackPreferences?.autoPlayNext ?? true }

    /// Credits segment active right now (independent of the Skip Credits mode —
    /// auto-play has its own setting).
    private var creditsForNext: PlaybackSegment? {
        viewModel.segments.creditsSegment(at: viewModel.currentSeconds)
    }

    /// Bottom-trailing "Up Next" card with a live countdown — shown while inside
    /// the credits segment when Auto-Play-Next is on and a next episode exists.
    @ViewBuilder
    private var nextEpisodeOverlay: some View {
        if let remaining = countdownRemaining, let next = nextItem {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
                        Text("Up Next")
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textSecondary)
                        Text(next.displayTitle)
                            .font(AetherDesign.Typography.cardTitle)
                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                            .lineLimit(2)
                        Text("Starting in \(remaining)s")
                            .font(AetherDesign.Typography.caption)
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                        HStack(spacing: AetherDesign.Spacing.s) {
                            AetherButton("Play Now", systemImage: "play.fill", role: .primary) {
                                Task { await playNext() }
                            }
                            AetherButton("Dismiss", role: .secondary) {
                                cancelCountdown()
                            }
                        }
                        .padding(.top, AetherDesign.Spacing.xs)
                    }
                    .padding(AetherDesign.Spacing.l)
                    .frame(maxWidth: 380, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AetherDesign.Radius.card, style: .continuous)
                            .fill(AetherDesign.Materials.card)
                    )
                }
            }
            .padding(AetherDesign.Spacing.xl)
        }
    }

    /// Resolve the episode after whatever is currently playing.
    private func loadNextItem() async {
        let currentID = viewModel.state.item?.id ?? item.id
        nextItem = await source?.nextEpisode(after: currentID)
    }

    /// Enter / leave the credits region drives the countdown.
    private func updateNextEpisodePrompt() {
        guard autoPlayNext, nextItem != nil else { cancelCountdown(); return }
        if creditsForNext != nil {
            if countdownRemaining == nil { startCountdown() }
        } else {
            cancelCountdown()
        }
    }

    private func startCountdown() {
        let total = playbackPreferences?.nextEpisodeCountdown ?? 10
        countdownRemaining = total
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            var remaining = total
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
                countdownRemaining = remaining
            }
            await playNext()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
    }

    /// Advance to the next episode in place — reuse the same player/session.
    /// Marks the finished episode watched, then opens the next and pre-resolves
    /// the one after it.
    private func playNext() async {
        guard let next = nextItem else { return }
        cancelCountdown()
        let finished = viewModel.state.item ?? item
        if let source { await source.markWatched(finished.id) }
        autoSkipped = []
        nextItem = nil
        // Carry the session's audio/subtitle/quality choices onto the next
        // episode (language-matched), with the app defaults as the base —
        // episode 2 used to revert to the container's default track (#68).
        let configured = playbackPreferences?.appliedToNextEpisode(next, continuing: finished) ?? next
        await viewModel.open(configured, source: source, startAt: 0)
        await loadNextItem()
    }

    /// For the "Automatically" mode: seek past a segment the moment it starts,
    /// once per segment (`autoSkipped` guards re-firing on every time tick).
    private func autoSkipIfNeeded() {
        if introMode == .automatically, let intro = activeIntro, !autoSkipped.contains(intro.id) {
            autoSkipped.insert(intro.id)
            Task { await viewModel.skip(toContentSeconds: intro.end) }
        } else if creditsMode == .automatically, let credits = activeCredits, !autoSkipped.contains(credits.id) {
            autoSkipped.insert(credits.id)
            Task { await viewModel.skip(toContentSeconds: credits.end) }
        }
    }

    // MARK: - iOS chrome (Back only)

    #if os(iOS)
    /// Visible while loading or on failure (so the user is never stranded), and
    /// auto-hidden during live playback to mirror AVKit's transport bar.
    private var effectiveChromeVisibility: Bool {
        guard viewModel.state.status != .failed else { return true }
        guard viewModel.player != nil else { return true }
        return isCloseVisible
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Button {
                    Task { await dismissPlayer() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(AetherDesign.Spacing.s)
                        // Match the hit-test area to the visible button — the
                        // material background isn't always honoured for hit
                        // testing otherwise, leaving "dead" rings around it.
                        .background(.ultraThinMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("Close player")

                Spacer()
            }
            .padding(AetherDesign.Spacing.m)
            Spacer()
        }
    }

    /// Downward swipe-to-dismiss (#288). Engages only on a clearly vertical,
    /// downward drag, so a horizontal scrub on AVKit's transport never moves the
    /// player; pairs with the chrome-reveal tap via `simultaneousGesture` so the
    /// native controls keep all their touches. Commits only past a high
    /// threshold (or a fast flick) — a small/accidental drag springs back.
    private var swipeDownDismissGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let verticalDominant = value.translation.height > abs(value.translation.width)
                let committed = value.translation.height > 140 || value.predictedEndTranslation.height > 280
                if verticalDominant && committed {
                    Task { await dismissPlayer() }
                } else {
                    dragOffset = 0
                }
            }
    }

    private func revealChrome() {
        isCloseVisible = true
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.chromeIdleHide)
            guard !Task.isCancelled else { return }
            isCloseVisible = false
        }
    }
    #endif

    // MARK: - Dismiss / retry

    private func dismissPlayer() async {
        // Pause first so audio stops on the same frame the fade begins.
        await viewModel.pause()
        onDismiss()
    }

    private func retryPlayback() async {
        showFailureDetails = false
        await viewModel.open(item, source: source, startAt: startAt)
        #if os(iOS)
        if viewModel.player != nil { scheduleChromeHide() }
        #endif
    }

    // MARK: - Failure state (Retry + Close, never a dead-end black screen)

    private var playbackFailed: some View {
        VStack(spacing: AetherDesign.Spacing.l) {
            Image(systemName: "play.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(AetherDesign.Palette.textTertiary)

            VStack(spacing: AetherDesign.Spacing.s) {
                Text("Unable to prepare playback")
                    .font(AetherDesign.Typography.sectionTitle)
                    .foregroundStyle(AetherDesign.Palette.textPrimary)

                Text(failureMessage)
                    .font(AetherDesign.Typography.body)
                    .foregroundStyle(AetherDesign.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AetherDesign.Spacing.m) {
                AetherButton("Retry", systemImage: "arrow.clockwise", role: .primary) {
                    Task { await retryPlayback() }
                }
                AetherButton("Close", systemImage: "xmark", role: .secondary) {
                    Task { await dismissPlayer() }
                }
            }

            // Technical detail (host, NSURLError domain/code) is hidden by
            // default — surfaced only on demand so the user sees a calm message,
            // not a stack of jargon.
            if let detail = viewModel.state.error, !detail.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showFailureDetails.toggle() }
                } label: {
                    Text(showFailureDetails ? "Hide details" : "Details")
                        .font(AetherDesign.Typography.caption)
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
                .buttonStyle(.plain)

                if showFailureDetails {
                    let detailText = Text(detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    #if os(tvOS)
                    // `.textSelection` is unavailable on tvOS.
                    detailText
                    #else
                    detailText.textSelection(.enabled)
                    #endif
                }
            }
        }
        .frame(maxWidth: 560)
        .padding(AetherDesign.Spacing.xl)
    }

    /// Calm, human-readable — no raw host or `NSURLErrorDomain`. The underlying
    /// reason lives behind the Details disclosure above.
    private var failureMessage: String {
        "Aether couldn't prepare the stream for \(item.title) yet. Check that the server is reachable, then try again."
    }
}
