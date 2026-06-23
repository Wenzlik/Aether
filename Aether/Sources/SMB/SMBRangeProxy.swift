import Foundation
import Network
import os
import SMBClient

/// Localhost HTTP range-proxy for SMB playback (#213/#347).
///
/// VLCKit reads `smb://` via its internal libsmb2 module — every random-access
/// seek re-establishes an SMB session (negotiate + auth + tree-connect), adding
/// hundreds of ms of latency per seek. Routing VLC through a `127.0.0.1` HTTP
/// server gives it clean HTTP/1.1 range requests; the proxy translates those
/// into byte-range reads over the existing pure-Swift SMB stack. MKV seeks that
/// previously stalled 1–2 s over SMB direct drop to near AVPlayer / Plex levels.
///
/// **Persistent session:** one logged-in `SMBClient` is cached per
/// connection+share and reused for every range request of the playback (see
/// `sharedClient(for:)`). The earlier implementation built a fresh `SMBSession`
/// per HTTP request, so each range read paid a full negotiate + auth +
/// tree-connect (a new TCP session to :445) — that thrash kept VLCKit stuck in
/// buffering for tens of seconds on startup.
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

    private var tokensByURL:   [String: String] = [:]  // smbURL.absoluteString → token
    private var entries:       [String: Entry]  = [:]  // token → Entry
    private var fileSizeCache: [String: UInt64] = [:]  // token → cached file size
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
        fileSizeCache.removeValue(forKey: token)
    }

    /// Remove all entries belonging to a connection (called when the user
    /// deletes an SMB server from Settings).
    func unregisterAll(connectionID: String) {
        let dead = entries.filter { $0.value.connection.id == connectionID }.map(\.key)
        dead.forEach {
            entries.removeValue(forKey: $0)
            fileSizeCache.removeValue(forKey: $0)
        }
        tokensByURL = tokensByURL.filter { entries[$0.value] != nil }
        idleClients = idleClients.filter { !$0.key.hasPrefix("\(connectionID)|") }
    }

    /// Look up the entry and cached file size for a token.
    func lookup(token: String) -> (entry: Entry, cachedSize: UInt64?)? {
        guard let entry = entries[token] else { return nil }
        return (entry, fileSizeCache[token])
    }

    /// Cache the file size after a successful HEAD or first GET.
    func cacheFileSize(_ size: UInt64, for token: String) {
        fileSizeCache[token] = size
    }

    // MARK: - Pooled SMB clients

    /// Logged-in clients, idle and available for reuse, keyed by connection+share.
    /// `checkout` removes one (so it's owned by a single request), `checkin`
    /// returns it. A `SMBClient`'s `Session` mutates message-id/tree state with no
    /// internal locking, so it must never be touched by two requests at once —
    /// the pool guarantees that without a lock: a borrowed client isn't in the
    /// dictionary, so it can't be handed out again until checked back in.
    private var idleClients: [String: [ClientBox]] = [:]

    private func clientKey(_ entry: Entry) -> String { "\(entry.connection.id)|\(entry.share)" }

    /// Borrow a logged-in client for this connection+share. Reuses an idle one
    /// (no SMB handshake at all) or logs in + tree-connects a fresh one. Fresh
    /// logins happen only when no idle client is available — i.e. genuinely
    /// concurrent range reads — and those clients are pooled for reuse afterwards.
    func checkout(_ entry: Entry) async throws -> ClientBox {
        let key = clientKey(entry)
        if var pool = idleClients[key], let box = pool.popLast() {
            idleClients[key] = pool
            return box
        }
        let client = SMBClient(host: entry.connection.host)
        try await client.login(username: entry.connection.username ?? "",
                               password: entry.connection.password ?? "")
        try await client.connectShare(entry.share)
        return ClientBox(client)
    }

    /// Return a still-healthy client to the pool for reuse. A client that threw
    /// mid-request is intentionally NOT checked in — it's dropped so the next
    /// request logs in cleanly.
    func checkin(_ box: ClientBox, for entry: Entry) {
        idleClients[clientKey(entry), default: []].append(box)
    }

    private var warming: Set<String> = []

    /// Fire-and-forget: log in to `connection`+`share` in the background and park
    /// the client in the pool, so the first playback request doesn't pay the SMB
    /// login latency (~16s against some NAS boxes — the first Play would otherwise
    /// stall on it). Called when the SMB library loads, well before any Play.
    /// No-op if a client is already pooled or a warm-up is already in flight.
    func prewarm(connection: SMBConnection, share: String) {
        guard !share.isEmpty else { return }
        let entry = Entry(connection: connection, share: share, path: "")
        let key = clientKey(entry)
        guard idleClients[key]?.isEmpty ?? true, !warming.contains(key) else { return }
        warming.insert(key)
        Task {
            if let box = try? await checkout(entry) {
                checkin(box, for: entry)
                Self.log.info("SMB proxy pre-warmed \(key, privacy: .public)")
            }
            warming.remove(key)
        }
    }

    /// Holds a non-`Sendable` `SMBClient` and performs the actual reads. Marked
    /// `@unchecked Sendable` so it can cross the actor boundary; safety rests on
    /// the pool's exclusive-ownership invariant. The read helpers run in this
    /// (non-isolated) class, not on the actor, so `FileReader`'s nonisolated
    /// async members are reachable — exactly as the old per-request `SMBSession`.
    final class ClientBox: @unchecked Sendable {
        private let client: SMBClient
        init(_ client: SMBClient) { self.client = client }

        /// SMBClient paths are share-relative with no leading slash ("" = root).
        private static func relativePath(_ path: String) -> String {
            path.hasPrefix("/") ? String(path.dropFirst()) : path
        }

        func fileSize(path: String) async throws -> UInt64 {
            let reader = client.fileReader(path: Self.relativePath(path))
            let size = try await reader.fileSize
            try? await reader.close()
            return size
        }

        func read(path: String, offset: UInt64, length: UInt32) async throws -> Data {
            let reader = client.fileReader(path: Self.relativePath(path))
            let data = try await reader.read(offset: offset, length: length)
            try? await reader.close()
            return data
        }

        func fileSizeAndRead(path: String, offset: UInt64, length: UInt32)
        async throws -> (fileSize: UInt64, data: Data) {
            let reader = client.fileReader(path: Self.relativePath(path))
            let fileSize = try await reader.fileSize
            let data = try await reader.read(offset: offset, length: length)
            try? await reader.close()
            return (fileSize, data)
        }
    }

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

        guard let result = await proxy.lookup(token: token) else {
            await reply(conn, .init(status: 404)); return
        }
        await serve(result.entry, cachedFileSize: result.cachedSize,
                    token: token, proxy: proxy, request: req, on: conn)
    }

    // Cap per SMB read to avoid OOM on open-ended Range requests (e.g. bytes=0-)
    // for large MKV files. VLCKit handles 206 + Content-Range and issues follow-ups.
    private static let maxChunkBytes: UInt64 = 8 * 1024 * 1024

    nonisolated private static func serve(
        _ entry: Entry,
        cachedFileSize: UInt64?,
        token: String,
        proxy: SMBRangeProxy,
        request: SMBHTTPRequest,
        on conn: NWConnection
    ) async {
        // Borrow a pooled, already-logged-in client — no per-request SMB
        // handshake. The client is returned to the pool only on success; a
        // request that throws drops it so the next request reconnects cleanly.
        let box: ClientBox
        do {
            box = try await proxy.checkout(entry)
        } catch {
            log.error("SMB proxy login: \(error, privacy: .public)")
            await reply(conn, .init(status: 503)); return
        }

        do {
            // HEAD: return file size. The cache avoids even one SMB round-trip —
            // VLCKit typically sends HEAD before the first GET.
            if request.method == "HEAD" {
                let fileSize: UInt64
                if let cached = cachedFileSize {
                    fileSize = cached
                } else {
                    fileSize = try await box.fileSize(path: entry.path)
                    await proxy.cacheFileSize(fileSize, for: token)
                }
                await proxy.checkin(box, for: entry)
                var r = SMBHTTPResponse(status: 200)
                r["Content-Length"] = "\(fileSize)"
                r["Accept-Ranges"] = "bytes"
                r["Content-Type"] = "application/octet-stream"
                await reply(conn, r); return
            }

            // GET with known size — skip the extra fileSize round-trip.
            if let cached = cachedFileSize {
                let (start, rawEnd) = request.range(fileSize: cached)
                let cappedEnd = min(rawEnd, start + maxChunkBytes - 1)
                let length = UInt32(clamping: cappedEnd - start + 1)
                let body = try await box.read(path: entry.path, offset: start, length: length)
                await proxy.checkin(box, for: entry)
                await sendRangeResponse(body: body, start: start, fileSize: cached, on: conn)
            } else {
                // Size unknown — fetch size and the first chunk in one file open.
                let probe = request.range(fileSize: UInt64.max)
                let cappedEnd = min(probe.1, probe.0 + maxChunkBytes - 1)
                let length = UInt32(clamping: cappedEnd - probe.0 + 1)
                let (fileSize, body) = try await box.fileSizeAndRead(
                    path: entry.path, offset: probe.0, length: length)
                await proxy.cacheFileSize(fileSize, for: token)
                await proxy.checkin(box, for: entry)
                await sendRangeResponse(body: body, start: probe.0, fileSize: fileSize, on: conn)
            }
        } catch {
            // Broken session — drop it (no checkin) so the pool stays healthy.
            log.error("SMB proxy serve: \(error, privacy: .public)")
            await reply(conn, .init(status: 500))
        }
    }

    nonisolated private static func sendRangeResponse(
        body: Data, start: UInt64, fileSize: UInt64, on conn: NWConnection
    ) async {
        let actualEnd = start + UInt64(body.count) - 1
        let isComplete = start == 0 && actualEnd == fileSize - 1
        var r = SMBHTTPResponse(status: isComplete ? 200 : 206, body: body)
        r["Content-Length"] = "\(body.count)"
        r["Content-Range"] = "bytes \(start)-\(actualEnd)/\(fileSize)"
        r["Accept-Ranges"] = "bytes"
        r["Content-Type"] = "application/octet-stream"
        await reply(conn, r)
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
