import Foundation
import AetherCore

/// A `ByteSource` over an SMB file, reading byte ranges **synchronously** from
/// the localhost `SMBRangeProxy` (so it reuses the proxy's pooled, logged-in SMB
/// client — no per-read login). This lets the remux pipeline treat an SMB MKV
/// exactly like a memory-mapped local file: `MatroskaRemuxer(source:)` reads only
/// the bytes it touches and AVPlayer plays the rewrapped fMP4 (#476, Tier 1).
///
/// Blocking by design (the `ByteSource` contract is synchronous). The semaphore
/// bridge is safe because `URLSession` runs the request on its own threads, not
/// the caller's — but only call this off the main thread and off the Swift
/// concurrency cooperative pool (the remux build runs on a `DispatchQueue`, and
/// the resource-loader callback runs on its own serial queue).
final class SMBByteSource: ByteSource, @unchecked Sendable {
    private let proxyURL: URL
    let count: Int

    /// `nil` when the proxy can't report a length (file unreachable / not an SMB
    /// proxy URL) — the caller then can't remux and falls back to VLCKit.
    init?(proxyURL: URL) {
        self.proxyURL = proxyURL
        var head = URLRequest(url: proxyURL)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 60
        guard let (_, response) = Self.sync(head),
              let http = response as? HTTPURLResponse,
              let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
              length > 0
        else { return nil }
        self.count = length
    }

    func bytes(at offset: Int, length: Int) -> [UInt8] {
        guard offset >= 0, offset < count, length > 0 else { return [] }
        let want = min(length, count - offset)
        var out = [UInt8]()
        out.reserveCapacity(want)
        var pos = offset
        // The proxy caps each response (8 MB); loop until we have the full range
        // or hit a short read, so the `ByteSource` contract (full length except at
        // EOF) holds even when a request spans more than one proxy chunk.
        while out.count < want {
            let end = min(pos + (want - out.count), count) - 1
            var req = URLRequest(url: proxyURL)
            req.setValue("bytes=\(pos)-\(end)", forHTTPHeaderField: "Range")
            req.timeoutInterval = 60
            guard let (data, _) = Self.sync(req), let data, !data.isEmpty else { break }
            out.append(contentsOf: data)
            pos += data.count
        }
        return out
    }

    private static func sync(_ request: URLRequest) -> (Data?, URLResponse?)? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = (data, response)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }
}
