import Foundation

/// Converts a Matroska `S_TEXT/UTF8` (SubRip/SRT) cue's text into a WebVTT cue
/// **payload** for the fMP4 `wvtt` subtitle track (#476, P6).
///
/// Matroska stores only the cue *text* in the block (timing lives in the block
/// timestamp + duration, not in the payload), so this is a text-only transform —
/// no timestamp lines. SRT and WebVTT cue text are nearly identical; the
/// differences this handles:
/// - `<font …>` / `</font>`: WebVTT has no font tag — strip the tags, keep the
///   inner text. `<i>`/`<b>`/`<u>` are valid in WebVTT and pass through.
/// - CRLF → LF.
/// - A literal `-->` in the text would corrupt WebVTT parsing — escape it.
enum WebVTTConverter {

    /// Clean an SRT cue's text into a WebVTT cue payload.
    static func payload(fromSRT text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        s = stripFontTags(s)
        // `-->` is the WebVTT cue-timing arrow; it must not appear in a payload.
        s = s.replacingOccurrences(of: "-->", with: "→")
        // Trim trailing whitespace/newlines that SRT blocks often carry.
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove `<font …>` and `</font>` tags, keeping their inner text. Other tags
    /// (`<i>`, `<b>`, `<u>`) are left untouched.
    private static func stripFontTags(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == "<" {
                // Look at the tag name (after an optional '/').
                let afterBracket = input.index(after: i)
                var cursor = afterBracket
                if cursor < input.endIndex, input[cursor] == "/" { cursor = input.index(after: cursor) }
                let rest = input[cursor...].lowercased()
                if rest.hasPrefix("font"), let close = input[i...].firstIndex(of: ">") {
                    // Skip the whole <font …> / </font> tag.
                    i = input.index(after: close)
                    continue
                }
            }
            out.append(input[i])
            i = input.index(after: i)
        }
        return out
    }
}
