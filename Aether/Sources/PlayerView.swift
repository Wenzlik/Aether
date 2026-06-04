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
    @State private var viewModel: PlayerStateViewModel
    @State private var showFailureDetails = false

    /// Chrome auto-hide window — short, so controls don't linger over the video.
    private static let chromeIdleHide: Duration = .milliseconds(2500)

    #if os(iOS)
    @State private var isCloseVisible = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    /// visionOS only: auto-expand the system player so it docks into an open
    /// immersive space without a manual expand tap. Set by Cinema Mode.
    let preferExpanded: Bool

    init(
        item: MediaItem,
        source: (any MediaSource)?,
        session: PlaybackSession,
        startAt: Double? = nil,
        preferExpanded: Bool = false,
        onDismiss: @escaping () -> Void
    ) {
        self.item = item
        self.source = source
        self.startAt = startAt
        self.preferExpanded = preferExpanded
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
                    onDismiss: {
                        Task { await dismissPlayer() }
                    }
                )
                #if os(visionOS)
                .safeAreaPadding(.top, AetherDesign.Spacing.l)
                #else
                .ignoresSafeArea()
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
            #if os(iOS)
            if viewModel.player != nil { scheduleChromeHide() }
            #endif
        }
        .onDisappear {
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
            Task { await dismissPlayer() }
        }
        #if os(tvOS)
        .onExitCommand { Task { await dismissPlayer() } }
        #endif
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
