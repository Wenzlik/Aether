import Foundation
import AVFoundation
import AetherCore

// Dev CLI (#476): remux a .mkv prefix to fMP4 and validate with AVFoundation,
// OR inspect an existing .mp4/.m4v (skip remux) to compare against references.
//
//   swift run RemuxValidate <input.mkv> <output.mp4> [clusterLimit]
//   swift run RemuxValidate <existing.mp4>            # inspect-only

/// Dump what AVFoundation (the iOS AVPlayer family) sees for a file.
func inspect(_ url: URL) async {
    let asset = AVURLAsset(url: url)
    let playable = (try? await asset.load(.isPlayable)) ?? false
    let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? -1
    print("AVFoundation: isPlayable=\(playable) duration=\(String(format: "%.2f", duration))s")

    for characteristic in [AVMediaCharacteristic.audible, .legible] {
        if let group = try? await asset.loadMediaSelectionGroup(for: characteristic) {
            let opts = group.options.map { "\($0.displayName) [\($0.extendedLanguageTag ?? "?")]" }
            print("  selection \(characteristic.rawValue): \(opts.isEmpty ? "(empty group)" : opts.joined(separator: ", "))")
        } else {
            print("  selection \(characteristic.rawValue): (no group)")
        }
    }

    for mediaType in [AVMediaType.video, .audio] {
        guard let track = try? await asset.loadTracks(withMediaType: mediaType).first else {
            print("  \(mediaType.rawValue): (none)"); continue
        }
        let lang = (try? await track.load(.extendedLanguageTag)) ?? "?"
        guard let reader = try? AVAssetReader(asset: asset) else { continue }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var decoded = 0
        while decoded < 30, let s = out.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(s) > 0 { decoded += 1 } }
        let status = reader.status == .failed ? "FAILED: \(reader.error?.localizedDescription ?? "?")" : "ok"
        print("  \(mediaType.rawValue) lang=\(lang ?? "nil"): decoded \(decoded) buffers — \(status)")
        reader.cancelReading()
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: RemuxValidate <input.mkv> <output.mp4> [clusterLimit] | <existing.mp4>\n".utf8))
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])

// Inspect-only mode for an existing MP4 (reference comparison).
if ["mp4", "m4v", "mov"].contains(inputURL.pathExtension.lowercased()) {
    await inspect(inputURL)
    exit(0)
}

guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: RemuxValidate <input.mkv> <output.mp4> [clusterLimit]\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: args[2])
let clusterLimit = args.count >= 4 ? (Int(args[3]) ?? 30) : 30

guard let data = try? Data(contentsOf: inputURL, options: .mappedIfSafe) else {
    FileHandle.standardError.write(Data("could not read \(inputURL.path)\n".utf8))
    exit(1)
}
guard let remuxer = MatroskaRemuxer(data: data) else {
    FileHandle.standardError.write(Data("not remuxable (no packageable track)\n".utf8))
    exit(1)
}

print("tracks:")
for t in remuxer.tracks {
    let codec = t.videoCodec.map { "\($0)" } ?? t.audioCodec.map { "\($0)" } ?? "?"
    print("  #\(t.trackID) \(t.kind) codec=\(codec) \(t.width)x\(t.height) ch=\(t.channels) rate=\(t.sampleRate) lang=\(t.language ?? "nil") configBytes=\(t.codecConfig.count)")
}

// Progressive (non-fragmented) output — the path AVPlayer seeks (full moov
// sample tables). Read the whole thing through the on-demand reader.
let reader = remuxer.progressiveReader()
let out = reader.read(offset: 0, length: reader.contentLength)
try Data(out).write(to: outputURL)
print("wrote \(out.count) bytes (progressive, contentLength=\(reader.contentLength)) → \(outputURL.path)")
_ = clusterLimit

await inspect(outputURL)
