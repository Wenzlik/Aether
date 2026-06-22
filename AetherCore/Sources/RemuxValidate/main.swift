import Foundation
import AetherCore

// Dev CLI (#476): remux a prefix of a real .mkv to fMP4 and write it out, so the
// output can be checked with ffprobe / AVFoundation off-device.
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
