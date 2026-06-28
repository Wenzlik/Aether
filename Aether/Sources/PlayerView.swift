import SwiftUI
import AVKit
import Combine
import AetherCore

/// Full-screen player. Deliberately bare: `AVPlayerViewController`'s native
/// transport owns Play/Pause, Seek, and the Audio / Subtitle media-options
/// picker (HLS renditions for transcode titles), and dismissal is the
/// platform's own gesture/control — swipe-down on iOS, Menu on tvOS, the
/// native Back action on visionOS — so Aether draws no custom player chrome of
/// its own. Primary audio / subtitle selection already happened on Detail.
///
/// On iOS the old top-leading ✕ was removed (#431): it sat on the very edge
/// AVKit uses for PiP / AirPlay and collided with them (and its own auto-hide
/// timer desynced from AVKit's). Swipe-down (#288) is the canonical dismiss;
/// a one-time, auto-fading hint makes it discoverable without leaving a
/// permanent overlay behind.
struct PlayerView: View {
    let item: MediaItem
    /// The source the item came from — resolves a fresh playback URL (new Plex
    /// transcode session) on open / retry, instead of replaying a stale one.
    let source: (any MediaSource)?
    /// Where playback should begin. `nil` resumes from the persisted point;
    /// `0` (or any explicit value) starts there, ignoring the saved resume.
    let startAt: Double?
    let onDismiss: () -> Void
    /// Called when Auto-Play-Next advances to a different episode *in place*, so
    /// the host Detail can re-point itself at the episode that's actually
    /// playing instead of the one the user pressed Play on (#315).
    let onAdvance: (MediaItem) -> Void
    /// Playback defaults — drives Skip Intro / Skip Credits (Button /
    /// Automatically / Off). `nil` falls back to "Show Button".
    let playbackPreferences: PlaybackPreferencesStore?
    @State private var viewModel: PlayerStateViewModel
    @State private var showFailureDetails = false
    @State private var showTrackPicker = false
    /// Mirrors AVKit's transport chrome visibility so our waveform button
    /// shows and hides in sync. Starts true; auto-hides 4 s after the last
    /// tap (same rhythm as AVKit's own timer). Cancelled while the track
    /// picker overlay is open so the button doesn't vanish mid-interaction.
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    /// Foreground/background — drives suspending the UI-refresh poll while
    /// backgrounded (audio keeps playing; we just stop the 500 ms CPU churn).
    /// The app session — marks the finished item watched on **every** connected
    /// source that has it, keeping cross-source titles in sync (#232 follow-up).
    @Environment(AppSession.self) private var appSession
    @Environment(\.scenePhase) private var scenePhase
    /// Segments already auto-skipped this session, so `.automatically` fires
    /// once per segment instead of on every time tick.
    @State private var autoSkipped: Set<String> = []
    /// The resolved next episode (Auto-Play-Next), fetched on open.
    @State private var nextItem: MediaItem?
    /// Seconds left on the "Next Episode" countdown; `nil` when not counting.
    @State private var countdownRemaining: Int?
    @State private var countdownTask: Task<Void, Never>?

    #if os(iOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Live vertical offset while the user is swiping the player down to dismiss
    /// (#288). 0 when at rest; follows the finger during a deliberate downward
    /// drag, then either commits to dismiss or springs back.
    @State private var dragOffset: CGFloat = 0
    /// Whether to show the one-time "swipe down to close" discoverability hint
    /// (#431). Toggled true on the first-ever playback, then back to false after
    /// a couple of seconds; `hasSeenSwipeDownHint` keeps it one-time forever.
    @State private var showSwipeHint = false
    @State private var hintTask: Task<Void, Never>?
    @AppStorage("player.hasSeenSwipeDownHint") private var hasSeenSwipeDownHint = false
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
        onDismiss: @escaping () -> Void,
        onAdvance: @escaping (MediaItem) -> Void = { _ in }
    ) {
        self.item = item
        self.source = source
        self.startAt = startAt
        self.preferExpanded = preferExpanded
        self.redockToken = redockToken
        self.makeCinemaInfoControllers = makeCinemaInfoControllers
        self.playbackPreferences = playbackPreferences
        self.onDismiss = onDismiss
        self.onAdvance = onAdvance
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
                    contextualPromptTitle: contextualPlayerPrompt?.title,
                    onContextualPrompt: contextualPlayerPrompt?.action,
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
                .simultaneousGesture(TapGesture().onEnded { flashControls() })
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.85), value: dragOffset)
                #endif
            } else {
                ProgressView()
                    .tint(AetherDesign.Palette.textPrimary)
            }

            #if os(iOS)
            // Loading-only escape hatch (#431). While the stream is still
            // preparing there's no AVKit chrome on screen yet (and swipe-down is
            // bound to the player, which isn't shown), so a hanging "preparing"
            // would otherwise strand the user on a spinner. This ✕ is gone the
            // instant playback starts — so it never sits over AVKit's PiP /
            // AirPlay / zoom. Failure has its own Close in `playbackFailed`.
            if viewModel.player == nil, viewModel.state.status != .failed {
                loadingCloseButton
                    .zIndex(20)
            }

            // One-time swipe-down discoverability hint (#431). The old top-leading
            // ✕ used to live here during *playback*, but it collided with AVKit's
            // PiP / AirPlay on the same edge — swipe-down is now the only dismiss
            // once playing. The hint sits in the free centre of the frame (never
            // an AVKit-owned corner: leading = PiP/AirPlay, centre-top = title,
            // trailing = zoom, bottom = transport) and fades out on its own.
            if showSwipeHint {
                swipeDownHint
                    .zIndex(20)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            #endif

            skipOverlay
                .zIndex(25)

            nextEpisodeOverlay
                .zIndex(26)

            trackPickerButton
                .zIndex(27)

            // Track picker: rendered as a ZStack overlay instead of a .sheet
            // so it never triggers a UIKit presentation on the view that hosts
            // AVPlayerViewController — a modal presentation inside a fullscreen
            // player causes the player to be re-created on dismiss.
            if showTrackPicker {
                TrackPickerOverlay(
                    item: viewModel.state.item,
                    onPick: { audio, subtitle in
                        showTrackPicker = false
                        flashControls()
                        Task {
                            if let audio { await viewModel.switchAudioTrack(audio) }
                            if let subtitle { await viewModel.switchSubtitleTrack(subtitle.value) }
                        }
                    },
                    onDismiss: {
                        showTrackPicker = false
                        flashControls()
                    }
                )
                .zIndex(28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: viewModel.currentSeconds) { _, _ in
            autoSkipIfNeeded()
            updateNextEpisodePrompt()
        }
        .task {
            await viewModel.open(item, source: source, startAt: startAt)
            await loadNextItem()
            #if os(iOS)
            presentSwipeHintIfNeeded()
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
            hintTask?.cancel()
            #endif
        }
        // When the movie plays to its end, dismiss — so windowed playback
        // returns to Detail and, in Cinema Mode (visionOS), the immersive Dark
        // Theater closes instead of leaving the user in a black void. Runs on
        // the main actor (SwiftUI `onReceive`), so no data-race plumbing.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let current = viewModel.player?.currentItem,
                  (note.object as? AVPlayerItem) === current else { return }
            // Played to the end → finish: auto-advance if enabled, else mark
            // watched and dismiss.
            finishPlayback()
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
                // tvOS surfaces Skip Intro / Credits as a focusable native
                // contextual action (`contextualPlayerPrompt`) — a SwiftUI button
                // here can't take focus over the player VC (#529).
                #if !os(tvOS)
                if introMode == .button, let intro = activeIntro {
                    skipButton("Skip Intro", to: intro.end)
                } else if creditsMode == .button, let credits = activeCredits, countdownRemaining == nil {
                    // The Next Episode countdown card supersedes Skip Credits.
                    skipButton("Skip Credits", to: credits.end)
                }
                #endif
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

    /// tvOS only: the single transient prompt active right now, surfaced as a
    /// *focusable* native contextual action by `SystemVideoPlayer` — the SwiftUI
    /// buttons in `skipOverlay` / `nextEpisodeOverlay` can't take focus over the
    /// player VC on tvOS (#529). Precedence mirrors those overlays: Skip Intro,
    /// then the Up Next countdown, then Skip Credits. `nil` on every other
    /// platform, which keep their working SwiftUI overlays.
    private var contextualPlayerPrompt: (title: String, action: () -> Void)? {
        #if os(tvOS)
        if introMode == .button, let intro = activeIntro {
            return (String(localized: "Skip Intro"),
                    { Task { await viewModel.skip(toContentSeconds: intro.end) } })
        }
        if countdownRemaining != nil, nextItem != nil {
            return (String(localized: "Play Next Episode"),
                    { Task { await playNext() } })
        }
        if creditsMode == .button, let credits = activeCredits {
            return (String(localized: "Skip Credits"),
                    { Task { await viewModel.skip(toContentSeconds: credits.end) } })
        }
        return nil
        #else
        return nil
        #endif
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
                        // tvOS: the card is display-only — "Play Next Episode" is a
                        // focusable native contextual action (`contextualPlayerPrompt`),
                        // since a SwiftUI button can't take focus over the player VC
                        // (#529). iOS / visionOS keep the in-card buttons.
                        #if !os(tvOS)
                        HStack(spacing: AetherDesign.Spacing.s) {
                            AetherButton("Play Now", systemImage: "play.fill", role: .primary) {
                                Task { await playNext() }
                            }
                            AetherButton("Dismiss", role: .secondary) {
                                cancelCountdown()
                            }
                        }
                        .padding(.top, AetherDesign.Spacing.xs)
                        #endif
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
        // Clear the countdown UI, but do NOT cancel `countdownTask` — `playNext`
        // runs *inside* it (see `startCountdown`). `cancelCountdown()` would call
        // `countdownTask?.cancel()`, cancelling the very task we're executing in;
        // every `await` below then runs under a cancelled task, so the next
        // episode's resolve aborts with NSURLErrorCancelled (-999) on Plex's
        // `/transcode/universal/decision` request (#523).
        countdownTask = nil
        countdownRemaining = nil
        let finished = viewModel.state.item ?? item
        await appSession.markWatchedEverywhere(finished)
        autoSkipped = []
        nextItem = nil
        // Carry the session's audio/subtitle/quality choices onto the next
        // episode (language-matched), with the app defaults as the base —
        // episode 2 used to revert to the container's default track (#68).
        let configured = playbackPreferences?.appliedToNextEpisode(next, continuing: finished) ?? next
        // Tell the host Detail we've moved on, so dismissing later lands on the
        // episode that was actually playing, not the one Play was pressed on (#315).
        onAdvance(configured)
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
            // Credits are the terminal segment. Three cases (#314):
            //  • Auto-Play-Next will advance → let the Up Next countdown
            //    (`updateNextEpisodePrompt`) own the credits region. Seeking past
            //    them here would cancel that countdown *and* skip the watched
            //    write-back, which is exactly the reported bug.
            //  • No advance, credits run to the end → finish in place (mark
            //    watched + dismiss). A programmatic seek to EOF never posts
            //    `didPlayToEndTime`, so we must not lean on it to mark watched.
            //  • Credits somehow aren't terminal → fall back to a plain skip.
            if autoPlayNext, nextItem != nil {
                // countdown drives the advance — nothing to do here.
            } else if isTerminalSegment(credits) {
                finishPlayback()
            } else {
                Task { await viewModel.skip(toContentSeconds: credits.end) }
            }
        }
    }

    /// Whether `segment` runs to (within 5s of) the end of the item — i.e. the
    /// credits/outro with nothing meaningful after it. Unknown duration ⇒ treat
    /// as terminal, since auto-skipped credits effectively are. (#314)
    private func isTerminalSegment(_ segment: PlaybackSegment) -> Bool {
        guard let duration = viewModel.state.duration else { return true }
        let total = Double(duration.components.seconds)
        return total <= 0 || segment.end >= total - 5
    }

    /// End-of-playback handoff, shared by the natural play-to-end and the
    /// auto-skip-credits paths: advance to the next episode when Auto-Play-Next
    /// is on and one exists (`playNext` marks the finished one watched), else
    /// mark the finished episode watched and dismiss. (#314)
    private func finishPlayback() {
        if autoPlayNext, nextItem != nil {
            Task { await playNext() }
        } else {
            let finished = viewModel.state.item ?? item
            Task { await appSession.markWatchedEverywhere(finished) }
            Task { await dismissPlayer() }
        }
    }

    // MARK: - iOS dismiss (swipe-down + loading escape hatch)

    #if os(iOS)
    /// Top-leading ✕ shown **only while the stream is preparing** (no AVKit chrome
    /// on screen yet, so nothing to collide with) — the escape hatch for a hung
    /// "preparing" state. Disappears the moment playback starts (#431).
    private var loadingCloseButton: some View {
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

    /// The one-time discoverability hint for swipe-down-to-dismiss (#431).
    /// Centred — deliberately away from every AVKit-owned edge — with a downward
    /// chevron so the gesture reads at a glance. Non-interactive; it only informs.
    private var swipeDownHint: some View {
        VStack(spacing: AetherDesign.Spacing.xs) {
            Image(systemName: "chevron.down")
                .font(.system(size: 22, weight: .semibold))
            Text("Swipe down to close")
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.vertical, AetherDesign.Spacing.m)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 8)
        .accessibilityLabel("Swipe down to close the player")
    }

    /// Show the swipe-down hint exactly once, ever, fading it back out after a
    /// couple of seconds. Gated on real playback (not the loading / failure
    /// state) so it appears over video, and on `hasSeenSwipeDownHint` so a
    /// returning user never sees it again.
    private func presentSwipeHintIfNeeded() {
        guard !hasSeenSwipeDownHint, viewModel.player != nil else { return }
        hasSeenSwipeDownHint = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            showSwipeHint = true
        }
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                showSwipeHint = false
            }
        }
    }

    /// Downward swipe-to-dismiss (#288) — the canonical iOS dismiss (#431).
    /// Engages only on a clearly vertical, downward drag, so a horizontal scrub
    /// on AVKit's transport never moves the player; attached to the player via
    /// `simultaneousGesture` so the native controls keep all their touches.
    /// Commits only past a high threshold (or a fast flick) — a small/accidental
    /// drag springs back.
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
        presentSwipeHintIfNeeded()
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

    // MARK: - Track picker

    /// Small waveform button in the top-trailing corner (clear of AVKit's
    /// AirPlay/PiP corner on the leading side and the zoom control on the
    /// trailing side — we sit above the zoom button, so it's visible whenever
    /// the transport chrome is on screen and doesn't block any AVKit control).
    @ViewBuilder
    private var trackPickerButton: some View {
        #if !os(tvOS)
        let audioTracks = viewModel.state.item?.audioTracks ?? []
        let subtitleTracks = viewModel.state.item?.subtitleTracks ?? []
        if !audioTracks.isEmpty || !subtitleTracks.isEmpty {
            VStack {
                HStack {
                    Spacer()
                    Button {
                        hideControlsTask?.cancel()
                        withAnimation { showTrackPicker = true }
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, AetherDesign.Spacing.m)
                    .padding(.top, AetherDesign.Spacing.m)
                    .accessibilityLabel(
                        String(localized: "Audio & Subtitles",
                               comment: "Button that opens the audio/subtitle track picker during playback"))
                }
                Spacer()
            }
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        #endif
    }

    /// Show the waveform button and schedule auto-hide after 4 seconds,
    /// mirroring AVKit's transport chrome visibility rhythm.
    private func flashControls() {
        hideControlsTask?.cancel()
        controlsVisible = true
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { controlsVisible = false }
        }
    }
}

// MARK: - Track picker overlay

/// Full-ZStack overlay (not a UIKit sheet) that lets the user pick an audio
/// track or subtitle during playback. Rendered inside `PlayerView`'s own
/// ZStack so it never triggers a UIKit modal presentation — which would cause
/// `AVPlayerViewController` to be re-created on dismiss.
private struct TrackPickerOverlay: View {
    let item: MediaItem?
    struct SubtitleChoice { let value: MediaSubtitleTrack? }
    let onPick: (_ audio: MediaAudioTrack?, _ subtitle: SubtitleChoice?) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrim — tapping outside dismisses
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            // Panel
            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 36, height: 4)
                    .padding(.top, AetherDesign.Spacing.s)
                    .padding(.bottom, AetherDesign.Spacing.xs)

                HStack {
                    Text(String(localized: "Audio & Subtitles",
                                comment: "Navigation title for the track picker sheet"))
                        .font(AetherDesign.Typography.cardTitle)
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                    Spacer()
                    Button(String(localized: "Done",
                                  comment: "Dismiss the track picker sheet")) {
                        onDismiss()
                    }
                    .foregroundStyle(AetherDesign.Palette.accent)
                }
                .padding(.horizontal, AetherDesign.Spacing.m)
                .padding(.bottom, AetherDesign.Spacing.s)

                Divider()

                List {
                    if let item, !item.audioTracks.isEmpty {
                        Section {
                            ForEach(item.audioTracks) { track in
                                Button {
                                    onPick(track, nil)
                                } label: {
                                    Label {
                                        Text(track.displayTitle)
                                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                                    } icon: {
                                        if track.id == item.selectedAudioTrackID {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(AetherDesign.Palette.accent)
                                        } else {
                                            Color.clear.frame(width: 14)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Audio")
                        }
                    }

                    if let item, !item.subtitleTracks.isEmpty {
                        Section {
                            Button {
                                onPick(nil, SubtitleChoice(value: nil))
                            } label: {
                                Label {
                                    Text("Off").foregroundStyle(AetherDesign.Palette.textPrimary)
                                } icon: {
                                    if item.selectedSubtitleTrackID == nil {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(AetherDesign.Palette.accent)
                                    } else {
                                        Color.clear.frame(width: 14)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            ForEach(item.subtitleTracks) { track in
                                Button {
                                    onPick(nil, SubtitleChoice(value: track))
                                } label: {
                                    Label {
                                        Text(track.displayTitle)
                                            .foregroundStyle(AetherDesign.Palette.textPrimary)
                                    } icon: {
                                        if track.id == item.selectedSubtitleTrackID {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(AetherDesign.Palette.accent)
                                        } else {
                                            Color.clear.frame(width: 14)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Subtitles")
                        }
                    }
                }
                #if os(tvOS)
                .listStyle(.plain)
                #else
                .listStyle(.insetGrouped)
                #endif
                .frame(maxHeight: 400)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, AetherDesign.Spacing.s)
            .padding(.bottom, AetherDesign.Spacing.s)
        }
    }
}
