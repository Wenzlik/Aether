import Foundation

/// Turns a subtitle track's cues into the sample stream of a WebVTT-in-ISOBMFF
/// (`wvtt`) track (#476 P6). The WebVTT-in-MP4 mapping (ISO 14496-30 §7.5)
/// requires the samples to **tile the whole timeline with no gaps or overlaps**:
/// every instant is covered by exactly one sample, which is either a cue
/// (`vttc` → `payl`) or an empty placeholder (`vtte`). This builder takes the
/// sparse Matroska cues and fills the gaps between them with empty samples.
///
/// Cues are assumed non-overlapping (SRT — `S_TEXT/UTF8` — is sequential by
/// spec). Overlaps are resolved by clamping a cue's start to the end of the
/// previous one, so a cue fully shadowed by its predecessor is dropped; this is
/// a known simplification, fine for SubRip but not for ASS-style simultaneous
/// cues (which we don't carry anyway).
enum WebVTTSampleBuilder {

    /// A subtitle cue on the track's timeline (ticks in the track timescale).
    struct Cue: Sendable, Equatable {
        let startTicks: Int64
        let durationTicks: Int64
        /// The WebVTT cue payload (already converted from SRT, no timing line).
        let payload: String
    }

    /// Build the tiling sample list for `[0, totalDurationTicks)`.
    static func samples(cues: [Cue], totalDurationTicks: Int64) -> [FragmentedMP4Writer.Sample] {
        guard totalDurationTicks > 0 else { return [] }
        let sorted = cues.sorted { $0.startTicks < $1.startTicks }

        var samples: [FragmentedMP4Writer.Sample] = []
        var cursor: Int64 = 0

        for cue in sorted {
            let start = max(cue.startTicks, cursor)
            if start >= totalDurationTicks { break }
            let end = min(cue.startTicks + cue.durationTicks, totalDurationTicks)
            if end <= start { continue }   // zero-length after clamping → skip

            if start > cursor {
                samples.append(emptySample(duration: UInt32(clamping: start - cursor)))
            }
            samples.append(cueSample(payload: cue.payload, duration: UInt32(clamping: end - start)))
            cursor = end
        }

        // Trailing gap to the end of the movie.
        if cursor < totalDurationTicks {
            samples.append(emptySample(duration: UInt32(clamping: totalDurationTicks - cursor)))
        }
        return samples
    }

    // MARK: - WebVTT sample boxes (ISO 14496-30 §7.5)

    /// A presentation cue sample: a `vttc` VTTCueBox wrapping a `payl`
    /// CuePayloadBox with the UTF-8 cue text.
    private static func cueSample(payload: String, duration: UInt32) -> FragmentedMP4Writer.Sample {
        let payl = MP4Box.box("payl", Array(payload.utf8))
        let vttc = MP4Box.box("vttc", payl)
        return FragmentedMP4Writer.Sample(data: vttc, duration: duration,
                                          isKeyframe: true, compositionOffset: 0)
    }

    /// An empty placeholder sample (`vtte` VTTEmptyCueBox) — no cue is on screen.
    private static func emptySample(duration: UInt32) -> FragmentedMP4Writer.Sample {
        FragmentedMP4Writer.Sample(data: MP4Box.box("vtte", []), duration: duration,
                                   isKeyframe: true, compositionOffset: 0)
    }
}
