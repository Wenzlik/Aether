import Foundation

/// Synthesises the `dac3` / `dec3` codec-configuration box **payload** for
/// AC-3 / E-AC-3 audio from the first coded frame (#476, Tier 1).
///
/// MKV carries no `CodecPrivate` for (E-)AC-3, so the MP4 sample entry's config
/// box must be derived from the bitstream syncframe itself (ETSI TS 102 366:
/// AC-3 §5.3 + `dac3` Annex F.4; E-AC-3 §E.1.2 + `dec3` Annex F.6). The caller
/// passes the bytes of the track's first frame; we read the fixed-position
/// header fields and emit the box payload (the box header/type is added by
/// `ProgressiveMP4Writer`).
///
/// Scope: plain AC-3, and the common single-independent-substream E-AC-3 (5.1
/// or fewer, full sample rate, no dependent substreams). Anything outside that —
/// DTS/TrueHD, half-rate E-AC-3, dependent substreams (Atmos/7.1 carriage),
/// multiple independent substreams — returns `nil`, so the remuxer bails and the
/// title falls back to VLCKit rather than producing a stream AVFoundation
/// can't decode.
enum AudioBitstreamConfig {
    /// Result of parsing one (E-)AC-3 syncframe.
    struct Parsed: Equatable {
        /// `dac3` / `dec3` box payload (no box header).
        var configBox: [UInt8]
        var channels: UInt16
        var sampleRate: UInt32
        /// Audio-media-timescale duration of one coded frame (1536 for AC-3;
        /// `numblks * 256` for E-AC-3). Sample timestamps are spaced by this.
        var samplesPerFrame: UInt32
    }

    /// `nfchans` per `acmod` (TS 102 366 Table 5.8). LFE is added separately.
    private static let acmodChannels: [UInt16] = [2, 1, 2, 3, 3, 4, 4, 5]

    static func parse(codec: AudioCodec, firstFrame: [UInt8]) -> Parsed? {
        switch codec {
        case .ac3:  return parseAC3(firstFrame)
        case .eac3: return parseEAC3(firstFrame)
        default:    return nil
        }
    }

    // MARK: - AC-3 (TS 102 366 §5.3 → dac3 Annex F.4)

    private static func parseAC3(_ frame: [UInt8]) -> Parsed? {
        var r = BitReader(frame)
        guard r.read(16) == 0x0B77 else { return nil }   // syncword
        _ = r.read(16)                                    // crc1
        guard let fscod = r.read(2) else { return nil }
        guard let frmsizecod = r.read(6) else { return nil }
        guard let bsid = r.read(5) else { return nil }
        guard bsid <= 8 else { return nil }               // >8 = (E-)AC-3, not plain AC-3
        guard let bsmod = r.read(3), let acmod = r.read(3) else { return nil }
        if (acmod & 0x1) != 0 && acmod != 0x1 { _ = r.read(2) }  // cmixlev
        if (acmod & 0x4) != 0 { _ = r.read(2) }                  // surmixlev
        if acmod == 0x2 { _ = r.read(2) }                        // dsurmod
        guard let lfeon = r.read(1) else { return nil }
        guard let rate = ac3SampleRate(fscod) else { return nil }

        // dac3: fscod(2) bsid(5) bsmod(3) acmod(3) lfeon(1) bit_rate_code(5) reserved(5)
        var b = BitWriter()
        b.write(fscod, 2); b.write(bsid, 5); b.write(bsmod, 3); b.write(acmod, 3)
        b.write(lfeon, 1); b.write(frmsizecod >> 1, 5); b.write(0, 5)
        return Parsed(configBox: b.bytes,
                      channels: channelCount(acmod, lfeon),
                      sampleRate: rate,
                      samplesPerFrame: 1536)
    }

    // MARK: - E-AC-3 (TS 102 366 §E.1.2 → dec3 Annex F.6)

    private static func parseEAC3(_ frame: [UInt8]) -> Parsed? {
        var r = BitReader(frame)
        guard r.read(16) == 0x0B77 else { return nil }    // syncword
        guard let strmtyp = r.read(2) else { return nil }
        guard strmtyp == 0 else { return nil }            // only independent stream type 0
        _ = r.read(3)                                     // substreamid
        guard let frmsiz = r.read(11) else { return nil }
        guard let fscod = r.read(2) else { return nil }
        guard fscod != 3 else { return nil }              // half sample-rate (fscod2) → bail to VLC
        guard let numblkscod = r.read(2) else { return nil }
        guard let acmod = r.read(3), let lfeon = r.read(1) else { return nil }
        guard let bsid = r.read(5) else { return nil }
        guard bsid > 10, bsid <= 16 else { return nil }   // E-AC-3 bsid is 16
        guard let rate = ac3SampleRate(fscod) else { return nil }

        let numblks = [1, 2, 3, 6][numblkscod]
        let samplesPerFrame = UInt32(numblks * 256)
        let frameBytes = (frmsiz + 1) * 2
        // Nominal bitrate (kbit/s) for dec3.data_rate, derived from this frame.
        let dataRate = min(UInt32(frameBytes) * 8 * rate / (samplesPerFrame * 1000), 8191)

        // dec3: data_rate(13) num_ind_sub(3) then, per independent substream:
        //   fscod(2) bsid(5) reserved(1) asvc(1) bsmod(3) acmod(3) lfeon(1)
        //   reserved(3) num_dep_sub(4) [reserved(1) when num_dep_sub == 0]
        var b = BitWriter()
        b.write(Int(dataRate), 13)
        b.write(0, 3)                 // num_ind_sub - 1 (single substream)
        b.write(fscod, 2); b.write(bsid, 5)
        b.write(0, 1)                 // reserved
        b.write(0, 1)                 // asvc
        b.write(0, 3)                 // bsmod (informational; complete main)
        b.write(acmod, 3); b.write(lfeon, 1)
        b.write(0, 3)                 // reserved
        b.write(0, 4)                 // num_dep_sub = 0
        b.write(0, 1)                 // reserved (num_dep_sub == 0)
        return Parsed(configBox: b.bytes,
                      channels: channelCount(acmod, lfeon),
                      sampleRate: rate,
                      samplesPerFrame: samplesPerFrame)
    }

    // MARK: - Field helpers

    private static func ac3SampleRate(_ fscod: Int) -> UInt32? {
        switch fscod {
        case 0: return 48_000
        case 1: return 44_100
        case 2: return 32_000
        default: return nil
        }
    }

    private static func channelCount(_ acmod: Int, _ lfeon: Int) -> UInt16 {
        guard acmod < acmodChannels.count else { return 2 }
        return acmodChannels[acmod] + UInt16(lfeon)
    }
}

// MARK: - Bit I/O (big-endian, MSB-first)

/// Minimal MSB-first bit reader over a byte buffer. Returns `nil` once the
/// buffer is exhausted so malformed/short frames decline rather than crash.
private struct BitReader {
    private let bytes: [UInt8]
    private var bitPos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int? {
        guard count > 0, bitPos + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            let byte = bytes[bitPos >> 3]
            let bit = (Int(byte) >> (7 - (bitPos & 7))) & 1
            value = (value << 1) | bit
            bitPos += 1
        }
        return value
    }
}

/// Minimal MSB-first bit writer that packs into whole bytes (final partial byte
/// is zero-padded). All (E-)AC-3 config boxes here are byte-aligned by design.
private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var bitsFilled = 0

    mutating func write(_ value: Int, _ count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) {
            let bit = UInt8((value >> i) & 1)
            current = (current << 1) | bit
            bitsFilled += 1
            if bitsFilled == 8 {
                bytes.append(current)
                current = 0
                bitsFilled = 0
            }
        }
    }
}
