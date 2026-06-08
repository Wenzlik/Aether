import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the small, **token-free** device/build blocks that Aether's Support
/// flows attach to bug reports and feature requests. Never includes server
/// tokens, passwords, or any credential — only environment facts that help
/// reproduce an issue.
///
/// Cross-platform (compiles everywhere); the Support UI that uses it is gated to
/// the platforms that have a mail composer (iOS / iPadOS / visionOS).
enum SupportDiagnostics {
    /// Where bug reports, feature requests, and diagnostics are sent.
    static let supportEmail = "aether@zmrhal.cz"

    // MARK: - Identity

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Marketing version, e.g. "0.6.1".
    static var appVersion: String { infoString("CFBundleShortVersionString") ?? "—" }

    /// Build number (CFBundleVersion). "1" on local builds; meaningful on Xcode Cloud.
    static var buildNumber: String { infoString("CFBundleVersion") ?? "—" }

    /// Short git commit stamped into the build, or `nil` on un-stamped local builds.
    static var commit: String? {
        guard let commit = infoString("AetherGitCommit"), !commit.hasPrefix("dev") else { return nil }
        return commit
    }

    /// Prefer the commit (stamped every build) over the local-only build number.
    static var buildIdentifier: String { commit ?? buildNumber }

    /// Platform label. visionOS/tvOS are explicit; iOS distinguishes iPad.
    static var platformName: String {
        #if os(visionOS)
        return "visionOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #else
        return "macOS"
        #endif
    }

    /// Human OS version string, e.g. "Version 26.0 (Build ...)". From ProcessInfo
    /// so visionOS reports correctly (the Plex platform var reports iOS on Vision).
    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// Raw hardware model identifier, e.g. "iPhone16,2" / "RealityDevice14,1".
    /// On Simulator returns the simulated model when the environment exposes it,
    /// otherwise the host architecture.
    static func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            let pointer = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: pointer)
        }
    }

    // MARK: - Report blocks

    /// Full environment footer for a **bug report** — version, build, platform,
    /// device, OS, theme, timestamp. No sensitive data.
    static func bugReportFooter(theme: String, timestamp: Date = Date()) -> String {
        """
        ——————————————
        Aether \(appVersion) (\(buildIdentifier))
        Platform: \(platformName)
        Device: \(deviceModel())
        OS: \(osVersion)
        Theme: \(theme)
        Date: \(timestamp.ISO8601Format())
        """
    }

    /// Lighter footer for a **feature request** — app version, platform, device.
    static func featureRequestFooter() -> String {
        """
        ——————————————
        Aether \(appVersion) · \(platformName) · \(deviceModel())
        """
    }
}
