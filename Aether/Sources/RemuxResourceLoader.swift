import Foundation
import AVFoundation
import AetherCore
import os

/// Plays a local Matroska file through AVPlayer by remuxing it to fragmented
/// MP4 on the fly (#476, Tier 1). AVPlayer can't open `.mkv`, so we hand it a
/// custom-scheme `AVURLAsset` and feed the bytes via an
/// `AVAssetResourceLoaderDelegate`: every byte range AVPlayer asks for is served
/// from `MatroskaRemuxer`, which rewraps the MKV's H.264/HEVC + AAC elementary
/// streams into fMP4 without re-encoding.
///
/// The source file is memory-mapped, and only the byte ranges AVPlayer requests
/// are remuxed (via the stream index), so even a multi-GB rip stays off the heap.
///
/// > Built and structurally complete; **playback must be verified on a real
/// > device** — AVPlayer is particular about fMP4 conformance, and the simulator
/// > doesn't exercise the same decode path.
final class RemuxedLocalAsset {
    /// Custom scheme so AVFoundation routes loading through our delegate rather
    /// than trying to open the file itself.
    static let scheme = "aether-remux"

    let asset: AVURLAsset
    private let delegate: ResourceLoaderDelegate
    private let queue = DispatchQueue(label: "cz.zmrhal.aether.remux.loader", qos: .userInitiated)

    /// Build an asset for a local `.mkv`. Returns `nil` if the file isn't a
    /// Matroska we can remux (no packageable H.264/HEVC + AAC track) — the
    /// caller then falls back to another engine.
    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let remuxer = MatroskaRemuxer(data: data) else { return nil }

        // A stable custom-scheme URL; the path is cosmetic (helps AVPlayer pick
        // the .mp4 demuxer via the extension).
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "local"
        components.path = "/" + fileURL.deletingPathExtension().lastPathComponent + ".mp4"
        guard let url = components.url else { return nil }

        self.delegate = ResourceLoaderDelegate(remuxer: remuxer)
        self.asset = AVURLAsset(url: url)
        self.asset.resourceLoader.setDelegate(delegate, queue: queue)
    }

    // MARK: - Delegate

    private final class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
        /// Cached byte reader — builds the index once and reuses generated
        /// segments across the many overlapping range requests AVPlayer makes
        /// (regenerating per request stalled playback for seconds → black screen).
        /// Built lazily off the main-actor construction path; the serial loader
        /// queue makes the lazy init race-free.
        private let remuxer: MatroskaRemuxer
        private lazy var reader = RemuxByteReader(remuxer)
        private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "remux.loader")

        /// Cap per `respond(with:)` so an open-ended request doesn't allocate the
        /// whole remuxed stream at once.
        private static let chunkBytes = 4 * 1024 * 1024

        init(remuxer: MatroskaRemuxer) {
            self.remuxer = remuxer
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            let start = Date()
            if let info = loadingRequest.contentInformationRequest {
                // Fragmented MP4. Byte-range access is what makes seeking work.
                info.contentType = "public.mpeg-4"
                info.contentLength = Int64(reader.contentLength)
                info.isByteRangeAccessSupported = true
                Self.log.info("content-info length=\(info.contentLength) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
            }

            if let dataRequest = loadingRequest.dataRequest {
                let offset = dataRequest.currentOffset
                let length = dataRequest.requestedLength
                serve(dataRequest)
                Self.log.debug("serve off=\(offset) len=\(length) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
            }
            loadingRequest.finishLoading()
            return true
        }

        /// Serve **one** bounded chunk and return. AVPlayer asks for the whole
        /// remaining file in `requestedLength` (gigabytes); trying to satisfy that
        /// in one synchronous callback blocked the loader for seconds → black
        /// screen. Responding with a chunk and finishing lets AVFoundation issue
        /// a follow-up request for the rest (its documented incremental pattern),
        /// so each callback is fast and playback starts after the first chunks.
        private func serve(_ dataRequest: AVAssetResourceLoadingDataRequest) {
            let offset = Int(dataRequest.currentOffset)
            let wanted = Int(dataRequest.requestedOffset) + dataRequest.requestedLength - offset
            let length = min(Self.chunkBytes, max(0, wanted))
            guard length > 0 else { return }
            let bytes = reader.read(offset: offset, length: length)
            if !bytes.isEmpty { dataRequest.respond(with: Data(bytes)) }
        }
    }
}
