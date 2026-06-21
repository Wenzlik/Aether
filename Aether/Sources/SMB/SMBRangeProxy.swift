import Foundation
import Network
import os

/// Localhost HTTP range-proxy for SMB playback (#213/#347).
///
/// VLCKit reads `smb://` via its internal libsmb2 module — every random-access
/// seek re-establishes an SMB session (negotiate + auth + tree-connect), adding
/// hundreds of ms of latency per seek. Routing VLC through a `127.0.0.1` HTTP
/// server gives it clean HTTP/1.1 range requests; the proxy translates those
/// into `SMBSession.read(share:path:offset:length:)` byte-range reads over the
/// existing pure-Swift SMB stack. MKV seeks that previously stalled 1–2 s over
/// SMB direct drop to near AVPlayer / Plex levels.
///
/// AVPlayer also benefits: `smb://` can't be opened by AVPlayer at all, but an
/// HTTP proxy URL with a `.mp4` extension plays natively with PiP and AirPlay.
///
/// **Lifecycle:** starts lazily on the first `register` call, runs for the
/// app's lifetime. Tokens are stable per SMB URL — replays reuse the same proxy
/// URL. Entries persist until `unregister` or `unregisterAll` is called.
///
/// **Security:** localhost-only listener + 32-char random hex token per URL;
/// no credentials appear in the HTTP URL.
actor SMBRangeProxy {
    static let shared = SMBRangeProxy()
    private init() {}

    // MARK: - Types

    struct Entry: Sendable {
        let connection: SMBConnection
        let share: String  // SMB share name, no slashes
        let path: String   // share-relative path, no leading slash
    }

    // MARK: - State

    private var tokensByURL: [String: String] = [:]  // smbURL.absoluteString → token
    private var entries:     [String: Entry]   = [:]  // token → Entry
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    // Accessible from nonisolated static helpers because Logger is Sendable and
    // static let is not isolated to the actor executor.
    static let log = Logger(subsystem: "cz.zmrhal.aether", category: "smb-proxy")

    // MARK: - Registration

    /// Register an SMB file and return a stable `http://127.0.0.1:<port>/<token>/<name>` URL.
    ///
    /// The token is stable per `smbURL`, so the same proxy URL is reused across
    /// replays. Returns `nil` only if the TCP listener failed to bind.
    func register(connection: SMBConnection, smbURL: URL) async -> URL? {
        let urlKey = smbURL.absoluteString
        let (share, path) = SMBSession.shareAndPath(from: smbURL)
        guard !share.isEmpty else { return nil }

        let token: String
        if let existing = tokensByURL[urlKey] {
            token = existing
        } else {
            token = Self.randomToken()
            tokensByURL[urlKey] = token
        }
        entries[token] = Entry(connection: connection, share: share, path: path)

        if listener == nil { await startListening() }
        guard port > 0 else { return nil }

        let name = smbURL.lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? smbURL.lastPathComponent
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(name)")
    }

    /// Remove the proxy entry for one SMB URL (e.g. when an item is deleted).
    func unregister(smbURL: URL) {
        guard let token = tokensByURL.removeValue(forKey: smbURL.absoluteString) else { return }
        entries.removeValue(forKey: token)
    }

    /// Remove all entries belonging to a connection (called when the user
    /// deletes an SMB server from Settings).
    func unregisterAll(connectionID: String) {
        let dead = entries.filter { $0.value.connection.id == connectionID }.map(\.key)
        dead.forEach { entries.removeValue(forKey: $0) }
        tokensByURL = tokensByURL.filter { entries[$0.value] != nil }
    }

    /// Look up the entry for a token — one cheap actor hop from the static handler.
    func entry(for token: String) -> Entry? { entries[token] }

    // MARK: - Server lifecycle

    private func startListening() async {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 0)
        guard let l = try? NWListener(using: params) else {
            Self.log.error("SMB proxy: NWListener init failed"); return
        }
        self.listener = l

        // AsyncStream gives Swift 6-safe "wait until ready" without a mutable
        // captured var (which would be flagged as a data race in Swift 6 mode).
        let (portStream, portCont) = AsyncStream<UInt16>.makeStream()
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let raw = l.port?.rawValue { portCont.yield(raw) }
                portCont.finish()
            case .failed(let err):
                Self.log.error("SMB proxy: listener failed: \(err, privacy: .public)")
                portCont.finish()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task.detached { await Self.handle(conn, proxy: self) }
        }
        l.start(queue: .global(qos: .utility))

        if let raw = await portStream.first(where: { _ in true }) {
            port = raw
            Self.log.info("SMB proxy on 127.0.0.1:\(raw, privacy: .public)")
        }
    }

    private static func randomToken() -> String {
        (0..<4).map { _ in String(format: "%08x", UInt32.random(in: 0...UInt32.max)) }.joined()
    }

    // MARK: - Request handling (static/nonisolated — runs fully concurrently)

    /// Handle one HTTP connection outside the actor so concurrent range requests
    /// from VLCKit never block each other on the actor's executor.
    nonisolated private static func handle(_ conn: NWConnection, proxy: SMBRangeProxy) async {
        conn.start(queue: .global(qos: .utility))
        defer { conn.cancel() }

        guard let data = await recv(conn), !data.isEmpty,
              let req = SMBHTTPRequest(rawData: data)
        else { await reply(conn, .init(status: 400)); return }

        // Path format: /<token>/<filename> — token is the first component.
        let token = req.path
            .split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""

        guard let entry = await proxy.entry(for: token) else {
            await reply(conn, .init(status: 404)); return
        }
        await serve(entry, request: req, on: conn)
    }

    nonisolated private static func serve(
        _ entry: Entry, request: SMBHTTPRequest, on conn: NWConnection
    ) async {
        // Fresh SMBSession per request — SMBClient is non-Sendable and must
        // not be shared across concurrent tasks.
        let session = SMBSession(connection: entry.connection)

        let fileSize: UInt64
        do { fileSize = try await session.fileSize(share: entry.share, path: entry.path) }
        catch {
            log.error("SMB proxy: fileSize: \(error, privacy: .public)")
            await reply(conn, .init(status: 503)); return
        }

        if request.method == "HEAD" {
            var r = SMBHTTPResponse(status: 200)
            r["Content-Length"] = "\(fileSize)"
            r["Accept-Ranges"] = "bytes"
            r["Content-Type"] = "application/octet-stream"
            await reply(conn, r); return
        }

        let (start, end) = request.range(fileSize: fileSize)
        let length = UInt32(clamping: end - start + 1)

        do {
            let body = try await session.read(share: entry.share, path: entry.path,
                                              offset: start, length: length)
            let actualEnd = start + UInt64(body.count) - 1
            let isPartial = request.hasRangeHeader
            var r = SMBHTTPResponse(status: isPartial ? 206 : 200, body: body)
            r["Content-Length"] = "\(body.count)"
            r["Content-Range"] = "bytes \(start)-\(actualEnd)/\(fileSize)"
            r["Accept-Ranges"] = "bytes"
            r["Content-Type"] = "application/octet-stream"
            await reply(conn, r)
        } catch {
            log.error("SMB proxy: read off=\(start, privacy: .public) len=\(length, privacy: .public): \(error, privacy: .public)")
            await reply(conn, .init(status: 500))
        }
    }

    // MARK: - Low-level I/O

    nonisolated private static func recv(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 4, maximumLength: 16_384) { data, _, _, _ in
                cont.resume(returning: data)
            }
        }
    }

    nonisolated private static func reply(_ conn: NWConnection, _ r: SMBHTTPResponse) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: r.bytes, completion: .contentProcessed { _ in cont.resume() })
        }
    }
}

// MARK: - SMBHTTPRequest

/// Minimal HTTP/1.1 request parser — covers GET/HEAD + Range headers as
/// emitted by VLCKit and AVPlayer for range-based playback.
struct SMBHTTPRequest {
    let method: String  // "GET" or "HEAD"
    let path: String    // percent-encoded, e.g. "/abc123/Movie.mkv"
    private let rawRange: String?

    init?(rawData: Data) {
        guard let text = String(data: rawData, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        method = parts[0].uppercased()
        path = parts[1]
        rawRange = lines.dropFirst().compactMap { line -> String? in
            guard line.lowercased().hasPrefix("range:") else { return nil }
            return line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        }.first
    }

    var hasRangeHeader: Bool { rawRange != nil }

    /// Byte range from `Range: bytes=<start>-<end>`.
    /// Defaults to the full file when no Range header is present.
    func range(fileSize: UInt64) -> (start: UInt64, end: UInt64) {
        guard fileSize > 0 else { return (0, 0) }
        guard let raw = rawRange, raw.lowercased().hasPrefix("bytes=") else {
            return (0, fileSize - 1)
        }
        let spec = raw.dropFirst(6)  // strip "bytes="
        let parts = spec.split(separator: "-", maxSplits: 1).map(String.init)
        let start = parts.first.flatMap(UInt64.init) ?? 0
        let end   = parts.dropFirst().first.flatMap(UInt64.init) ?? (fileSize - 1)
        return (min(start, fileSize - 1), min(end, fileSize - 1))
    }
}

// MARK: - SMBHTTPResponse

/// Minimal HTTP/1.1 response builder.
struct SMBHTTPResponse {
    let status: Int
    private var headers: [String: String] = [:]
    let body: Data?

    init(status: Int, body: Data? = nil) { self.status = status; self.body = body }

    subscript(key: String) -> String? {
        get { headers[key] }
        set { headers[key] = newValue }
    }

    var bytes: Data {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 206: phrase = "Partial Content"
        case 400: phrase = "Bad Request"
        case 404: phrase = "Not Found"
        case 500: phrase = "Internal Server Error"
        case 503: phrase = "Service Unavailable"
        default:  phrase = "Unknown"
        }
        var text = "HTTP/1.1 \(status) \(phrase)\r\n"
        headers.forEach { text += "\($0): \($1)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body { data.append(body) }
        return data
    }
}
