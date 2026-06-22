import Foundation
import AVFoundation
import AetherCore

// Dev CLI (#476): remux a prefix of a real .mkv to fMP4, write it out, and
// validate the result with **AVFoundation** (the real iOS playback engine's
// family) — not just ffmpeg.
//
//   swift run RemuxValidate <input.mkv> <output.mp4> [clusterLimit]

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: RemuxValidate <input.mkv> <output.mp4> [clusterLimit]\n".utf8))
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
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
    print("  #\(t.trackID) \(t.kind) codec=\(codec) \(t.width)x\(t.height) ch=\(t.channels) rate=\(t.sampleRate) configBytes=\(t.codecConfig.count)")
}

let out = remuxer.remuxPrefix(clusterLimit: clusterLimit)
try Data(out).write(to: outputURL)
print("wrote \(out.count) bytes (\(clusterLimit) clusters) → \(outputURL.path)")

// MARK: - AVFoundation validation (the iOS AVPlayer family)

let asset = AVURLAsset(url: outputURL)
let playable = (try? await asset.load(.isPlayable)) ?? false
let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? -1
print("AVFoundation: isPlayable=\(playable) duration=\(String(format: "%.2f", duration))s")

for mediaType in [AVMediaType.video, .audio] {
    guard let track = try? await asset.loadTracks(withMediaType: mediaType).first else {
        print("  \(mediaType.rawValue): (none)")
        continue
    }
    // Decode the first samples through AVAssetReader — proves AVFoundation can
    // actually parse + decode the elementary stream, not just open the file.
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var decoded = 0
    while decoded < 30, let sample = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(sample) > 0 { decoded += 1 }
    }
    let status = reader.status == .failed ? "FAILED: \(reader.error?.localizedDescription ?? "?")" : "ok"
    print("  \(mediaType.rawValue): decoded \(decoded) sample buffers — \(status)")
    reader.cancelReading()
}
