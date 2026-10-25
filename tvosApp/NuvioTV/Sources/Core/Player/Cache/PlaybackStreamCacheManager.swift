import CryptoKit
import Foundation
import OSLog
import AetherEngine

struct StreamProbeResult: Sendable {
    let supportsRange: Bool
    let contentLength: Int64
    let etag: String?
    let lastModified: String?
    let resolvedURL: URL?

    init(
        supportsRange: Bool,
        contentLength: Int64,
        etag: String?,
        lastModified: String?,
        resolvedURL: URL? = nil
    ) {
        self.supportsRange = supportsRange
        self.contentLength = contentLength
        self.etag = etag
        self.lastModified = lastModified
        self.resolvedURL = resolvedURL
    }
}

/// Small, one-shot memo for the bounded Details range probe. It is independent
/// of the cache manager's active playback probe and server ownership.
final class PlaybackStreamRangeProbeMemo: @unchecked Sendable {
    private struct Header: Hashable, Sendable {
        let name: String
        let value: String
    }
    private struct Key: Hashable, Sendable {
        let url: String
        let headers: [Header]
        let profileID: String
        init(url: URL, headers: [String: String], profileID: String) {
            self.url = url.absoluteString
            self.headers = headers.map { Header(name: $0.key, value: $0.value) }
                .sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
            self.profileID = profileID
        }
    }
    private struct Entry {
        let key: Key
        let result: StreamProbeResult
        let token: UUID
        let expiresAt: TimeInterval
    }
    static let shared = PlaybackStreamRangeProbeMemo()
    static let defaultTTL: TimeInterval = 15
    static let defaultCapacity = 2
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []

    init(capacity: Int = defaultCapacity) { self.capacity = max(1, capacity) }

    @discardableResult
    func store(_ result: StreamProbeResult, url: URL, headers: [String: String],
               profileID: String, token: UUID, ttl: TimeInterval = defaultTTL) -> Bool {
        guard result.supportsRange, result.contentLength > 0, ttl.isFinite, ttl >= 0 else { return false }
        let key = Key(url: url, headers: headers, profileID: profileID)
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        purgeExpiredLocked(now: now)
        removeLocked(key)
        while entries.count >= capacity, let oldest = order.first { removeLocked(oldest) }
        entries[key] = Entry(key: key, result: result, token: token, expiresAt: now + ttl)
        order.append(key)
        return true
    }

    func take(url: URL, headers: [String: String], profileID: String) -> StreamProbeResult? {
        let key = Key(url: url, headers: headers, profileID: profileID)
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        removeLocked(key)
        return entry.expiresAt > ProcessInfo.processInfo.systemUptime ? entry.result : nil
    }

    func discard(token: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries.values.filter { $0.token == token }.map(\.key).forEach(removeLocked)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        purgeExpiredLocked(now: ProcessInfo.processInfo.systemUptime)
        return entries.count
    }

    private func purgeExpiredLocked(now: TimeInterval) {
        entries.values.filter { $0.expiresAt <= now }.map(\.key).forEach(removeLocked)
    }
    private func removeLocked(_ key: Key) {
        entries.removeValue(forKey: key)
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
    }
}

/// Immutable source details for a scrub preview. The proxy URL is deliberately omitted: previews
/// read complete files from disk, then use the original origin if the cache has a hole.
struct PlaybackStreamThumbnailSource: Sendable, Equatable {
    let cacheDirectory: URL
    let fileLength: Int64
    let chunkSize: Int64
    let sessionID: String
    let remoteURL: URL
    let originalHeaders: [String: String]
}

struct PlaybackStreamCacheContentRange: Sendable {
    let start: Int64
    let end: Int64
    let total: Int64?

    static func parse(_ contentRange: String) -> PlaybackStreamCacheContentRange? {
        let value = contentRange.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = value.split(separator: " ", omittingEmptySubsequences: false)
        guard components.count == 2, components[0].lowercased() == "bytes" else { return nil }

        let rangeAndTotal = components[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = decimalInt64(bounds[0]),
              let end = decimalInt64(bounds[1]),
              start <= end else { return nil }

        let total: Int64?
        if rangeAndTotal[1] == "*" {
            total = nil
        } else {
            guard let parsedTotal = decimalInt64(rangeAndTotal[1]), parsedTotal > end else { return nil }
            total = parsedTotal
        }
        return PlaybackStreamCacheContentRange(start: start, end: end, total: total)
    }

    private static func decimalInt64(_ value: Substring) -> Int64? {
        guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int64(value)
    }
}

enum PlaybackStreamCacheRedirectPolicy {
    static func redirectedRequest(
        _ request: URLRequest,
        response: HTTPURLResponse,
        originalURL: URL?,
        range: String?,
        customHeaders: [String: String]
    ) -> URLRequest {
        var updated = request
        if response.url != nil, sameOrigin(originalURL, request.url) {
            for (name, value) in customHeaders {
                updated.setValue(value, forHTTPHeaderField: name)
            }
        } else {
            for name in customHeaders.keys {
                updated.setValue(nil, forHTTPHeaderField: name)
            }
        }
        if let range {
            updated.setValue(range, forHTTPHeaderField: "Range")
        }
        return updated
    }

    private static func sameOrigin(_ source: URL?, _ destination: URL?) -> Bool {
        guard let source, let destination,
              let sourceScheme = source.scheme?.lowercased(),
              let destinationScheme = destination.scheme?.lowercased(),
              let sourceHost = source.host?.lowercased(),
              let destinationHost = destination.host?.lowercased(),
              sourceScheme == destinationScheme,
              sourceHost == destinationHost,
              let sourcePort = effectivePort(for: source, scheme: sourceScheme),
              let destinationPort = effectivePort(for: destination, scheme: destinationScheme) else {
            return false
        }
        return sourcePort == destinationPort
    }

    private static func effectivePort(for url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

private final class RangeProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let originalURL: URL
    private let customHeaders: [String: String]
    private let expectedRange: Range<Int64>?
    private let lock = NSLock()
    private var storedResolvedURL: URL?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse)?, Error>?
    private var task: URLSessionDataTask?
    private var finished = false

    var resolvedURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedResolvedURL
    }

    init(originalURL: URL, customHeaders: [String: String], expectedRange: Range<Int64>?) {
        self.originalURL = originalURL
        self.customHeaders = customHeaders
        self.expectedRange = expectedRange
    }

    func load(in session: URLSession, request: URLRequest) async throws -> (Data, HTTPURLResponse)? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                task.delegate = self
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        lock.unlock()
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let updated = PlaybackStreamCacheRedirectPolicy.redirectedRequest(
            request,
            response: response,
            originalURL: originalURL,
            range: expectedRange.map { "bytes=\($0.lowerBound)-\($0.upperBound - 1)" },
            customHeaders: customHeaders
        )
        lock.lock()
        storedResolvedURL = updated.url
        lock.unlock()
        completionHandler(updated)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(returning: nil)
            return
        }

        let valid: Bool
        if let expectedRange {
            if http.statusCode == 206,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let parsedRange = PlaybackStreamCacheContentRange.parse(contentRange),
               parsedRange.start == expectedRange.lowerBound,
               parsedRange.end == expectedRange.upperBound - 1,
               let total = parsedRange.total,
               total > parsedRange.end,
               http.expectedContentLength < 0 || http.expectedContentLength == expectedRange.count {
                valid = true
            } else {
                valid = false
            }
        } else {
            valid = http.statusCode == 200 || http.statusCode == 206
        }
        guard valid else {
            completionHandler(.cancel)
            finish(returning: nil)
            dataTask.cancel()
            return
        }

        lock.lock()
        self.response = http
        storedResolvedURL = http.url
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let expectedBodyLength = expectedRange.map { Int($0.count) } ?? 0
        let exceedsExpectedBody = body.count + data.count > expectedBodyLength
        if !exceedsExpectedBody { body.append(data) }
        let task = self.task
        lock.unlock()

        if exceedsExpectedBody {
            finish(returning: nil)
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(throwing: error)
            return
        }
        lock.lock()
        let result: (Data, HTTPURLResponse)?
        let expectedBodyLength = expectedRange.map { Int($0.count) } ?? 0
        if body.count == expectedBodyLength, let response {
            result = (body, response)
        } else {
            result = nil
        }
        lock.unlock()
        finish(returning: result)
    }

    private func finish(returning result: (Data, HTTPURLResponse)?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    private func finish(throwing error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

/// Manages active HTTP stream disk cache servers for playback sessions.
actor PlaybackStreamCacheManager {
    static let shared = PlaybackStreamCacheManager()
    static let defaultProbePreparationBudget: TimeInterval = 5

    private struct ActiveProbe {
        let id: UUID
        let sessionToken: String?
        let task: Task<StreamProbeResult, Never>
    }

    private let serverStopper: @Sendable (PlaybackStreamCacheServer) async -> Void
    private var activeServer: PlaybackStreamCacheServer?
    private var activeSessionURL: URL?
    private(set) var activeSessionToken: String?
    private var pendingSessionToken: String?
    private var activeProbe: ActiveProbe?

    var hasActiveServer: Bool {
        activeServer != nil
    }

    init(
        serverStopper: @escaping @Sendable (PlaybackStreamCacheServer) async -> Void = { server in
            await server.stop()
        }
    ) {
        self.serverStopper = serverStopper
    }

    /// Checks if a remote stream supports HTTP Range requests and resolves its total file length and HTTP validators.
    func probeRangeSupport(
        url: URL,
        headers: [String: String] = [:],
        sessionConfiguration: URLSessionConfiguration? = nil,
        preparationBudget: TimeInterval = PlaybackStreamCacheManager.defaultProbePreparationBudget
    ) async -> StreamProbeResult {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return StreamProbeResult(supportsRange: false, contentLength: 0, etag: nil, lastModified: nil)
        }

        let session = sessionConfiguration.map { URLSession(configuration: $0) } ?? URLSession.shared
        let result = await performRangeProbe(
            url: url, headers: headers, session: session, preparationBudget: preparationBudget
        )
        guard !Task.isCancelled else {
            return StreamProbeResult(supportsRange: false, contentLength: 0, etag: nil, lastModified: nil)
        }
        return result
    }

    /// Independent Details-time probe; never joins or replaces `activeProbe`.
    @discardableResult
    func warmRangeProbeMemo(url: URL, headers: [String: String], profileID: String, token: UUID,
                            sessionConfiguration: URLSessionConfiguration? = nil,
                            preparationBudget: TimeInterval = PlaybackStreamCacheManager.defaultProbePreparationBudget) async -> Bool {
        guard !Task.isCancelled else { return false }
        let probe = await probeRangeSupport(url: url, headers: headers,
                                            sessionConfiguration: sessionConfiguration,
                                            preparationBudget: preparationBudget)
        guard !Task.isCancelled else { Self.discardRangeProbeMemo(token: token); return false }
        guard PlaybackStreamRangeProbeMemo.shared.store(probe, url: url, headers: headers,
                                                         profileID: profileID, token: token) else { return false }
        diskCacheLog.info("Cache probe warm outcome=ready length=\(probe.contentLength)")
        return true
    }

    nonisolated static func discardRangeProbeMemo(token: UUID) {
        PlaybackStreamRangeProbeMemo.shared.discard(token: token)
    }

    private func performRangeProbe(
        url: URL, headers: [String: String], session: URLSession, preparationBudget: TimeInterval
    ) async -> StreamProbeResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let budget = preparationBudget.isFinite
            ? max(0, preparationBudget)
            : Self.defaultProbePreparationBudget
        func remainingBudget() -> TimeInterval {
            max(0, budget - (ProcessInfo.processInfo.systemUptime - startedAt))
        }
        func elapsedMilliseconds() -> Int {
            Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        }

        let rangeDelegate = RangeProbeDelegate(originalURL: url, customHeaders: headers, expectedRange: 0..<2)
        var rangeRequest = URLRequest(url: url)
        rangeRequest.httpMethod = "GET"
        for (name, value) in headers { rangeRequest.setValue(value, forHTTPHeaderField: name) }
        rangeRequest.setValue("bytes=0-1", forHTTPHeaderField: "Range")

        guard let (data, http) = await loadProbeResponse(
            delegate: rangeDelegate, session: session, request: rangeRequest, timeout: remainingBudget()
        ), let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let parsedRange = PlaybackStreamCacheContentRange.parse(contentRange),
           parsedRange.start == 0, parsedRange.end == 1,
           let total = parsedRange.total, total >= 2, data.count == 2 else {
            diskCacheLog.warning("Cache probe phase=range outcome=failed elapsed_ms=\(elapsedMilliseconds())")
            return StreamProbeResult(supportsRange: false, contentLength: 0, etag: nil, lastModified: nil)
        }

        var etag = Self.nonemptyHeader("ETag", in: http)
        var lastModified = Self.nonemptyHeader("Last-Modified", in: http)
        diskCacheLog.info("Cache probe phase=range outcome=success elapsed_ms=\(elapsedMilliseconds())")

        // A valid byte-range response proves support. HEAD is only a bounded,
        // optional metadata fallback when the range response has no validator.
        if etag == nil, lastModified == nil {
            if Task.isCancelled {
                return StreamProbeResult(supportsRange: false, contentLength: 0, etag: nil, lastModified: nil)
            } else if remainingBudget() > 0 {
                let headDelegate = RangeProbeDelegate(originalURL: url, customHeaders: headers, expectedRange: nil)
                var headRequest = URLRequest(url: url)
                headRequest.httpMethod = "HEAD"
                for (name, value) in headers { headRequest.setValue(value, forHTTPHeaderField: name) }
                if let (_, headResponse) = await loadProbeResponse(
                    delegate: headDelegate, session: session, request: headRequest, timeout: remainingBudget()
                ), Self.headLengthMatches(headResponse, expectedLength: total) {
                    etag = Self.nonemptyHeader("ETag", in: headResponse)
                    lastModified = Self.nonemptyHeader("Last-Modified", in: headResponse)
                    diskCacheLog.info("Cache probe phase=head outcome=success elapsed_ms=\(elapsedMilliseconds())")
                } else {
                    diskCacheLog.info("Cache probe phase=head outcome=failed elapsed_ms=\(elapsedMilliseconds())")
                }
            } else {
                diskCacheLog.info("Cache probe phase=head outcome=budget_exhausted elapsed_ms=\(elapsedMilliseconds())")
            }
        } else {
            diskCacheLog.info("Cache probe phase=head outcome=skipped_validators elapsed_ms=\(elapsedMilliseconds())")
        }

        return StreamProbeResult(
            supportsRange: true, contentLength: total, etag: etag,
            lastModified: lastModified, resolvedURL: rangeDelegate.resolvedURL ?? http.url
        )
    }

    private func loadProbeResponse(
        delegate: RangeProbeDelegate, session: URLSession, request: URLRequest, timeout: TimeInterval
    ) async -> (Data, HTTPURLResponse)? {
        guard timeout > 0 else {
            delegate.cancel()
            return nil
        }
        let nanoseconds = UInt64(min(timeout, 3_600) * 1_000_000_000)
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                delegate.cancel()
            } catch {}
        }
        defer { timeoutTask.cancel() }
        return try? await delegate.load(in: session, request: request)
    }

    private static func nonemptyHeader(_ name: String, in response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func headLengthMatches(_ response: HTTPURLResponse, expectedLength: Int64) -> Bool {
        guard let value = response.value(forHTTPHeaderField: "Content-Length") else { return true }
        guard let length = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return length == expectedLength
    }

    private func trackRangeProbe(
        url: URL, headers: [String: String], sessionConfiguration: URLSessionConfiguration?,
        preparationBudget: TimeInterval, sessionToken: String
    ) async -> StreamProbeResult {
        let session = sessionConfiguration.map { URLSession(configuration: $0) } ?? URLSession.shared
        let id = UUID()
        let task = Task<StreamProbeResult, Never> { [weak self] in
            guard let self else {
                return StreamProbeResult(supportsRange: false, contentLength: 0, etag: nil, lastModified: nil)
            }
            return await self.performRangeProbe(
                url: url, headers: headers, session: session, preparationBudget: preparationBudget
            )
        }
        let previousProbe = activeProbe
        activeProbe = ActiveProbe(id: id, sessionToken: sessionToken, task: task)
        previousProbe?.task.cancel()

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if activeProbe?.id == id { activeProbe = nil }
        return result
    }

    /// Reuse is scoped to the exact request URL and its validator snapshot. A title,
    /// filename, Last-Modified date, or ETag shared by different resources is not
    /// proof that their bytes are interchangeable. Renewed URLs remain isolated until
    /// the source supplies a trusted immutable file identity.
    private func resolveVerifiedSession(
        for remoteURL: URL,
        probe: StreamProbeResult,
        headers: [String: String],
        cacheFileIdentity: PlaybackCacheFileIdentity?,
        canonicalMediaKey: String?,
        filename: String?,
        cacheRoot: URL
    ) -> (sessionID: String, manifest: PlaybackStreamManifest) {
        let requestIdentityKey = Self.requestIdentityKey(
            for: remoteURL, headers: headers, probe: probe
        )
        if let cacheFileIdentity {
            let identity = "\(cacheFileIdentity.cacheKey):\(probe.contentLength)"
            let hash = SHA256.hash(data: Data(identity.utf8))
            let candidate = "content_v1_" + hash.prefix(16).map { String(format: "%02x", $0) }.joined()
            let directory = cacheRoot.appendingPathComponent(candidate, isDirectory: true)
            if var existing = PlaybackStreamDiskCache.readManifest(in: directory),
               existing.sessionID == candidate,
               existing.fileLength == probe.contentLength,
               existing.cacheFileIdentity == cacheFileIdentity.cacheKey {
                existing.requestIdentityKey = requestIdentityKey
                existing.etag = probe.etag
                existing.lastModified = probe.lastModified
                existing.normalizedURLPath = remoteURL.absoluteString.components(separatedBy: "?")[0].components(separatedBy: "#")[0]
                existing.lastAccessedAt = Date()
                PlaybackStreamDiskCache.writeManifest(existing, to: directory)
                return (candidate, existing)
            }
            let chosenID = FileManager.default.fileExists(atPath: directory.path)
                ? candidate + "_" + UUID().uuidString : candidate
            return (chosenID, PlaybackStreamManifest(
                sessionID: chosenID, fileLength: probe.contentLength, etag: probe.etag,
                lastModified: probe.lastModified, canonicalMediaKey: canonicalMediaKey,
                cacheFileIdentity: cacheFileIdentity.cacheKey, requestIdentityKey: requestIdentityKey,
                filename: filename ?? remoteURL.lastPathComponent,
                normalizedURLPath: remoteURL.absoluteString.components(separatedBy: "?")[0].components(separatedBy: "#")[0],
                createdAt: Date(), lastAccessedAt: Date()
            ))
        }

        // Preserve validators verbatim, including weak prefixes. They can invalidate
        // an exact-URL entry, but are never treated as a cross-resource content hash.
        let candidate = requestIdentityKey
        // Version the namespace to avoid trusting caches created by heuristic URL matching.
        let directory = cacheRoot.appendingPathComponent(candidate, isDirectory: true)
        if var existing = PlaybackStreamDiskCache.readManifest(in: directory),
           existing.sessionID == candidate,
           existing.fileLength == probe.contentLength,
           existing.etag == probe.etag,
           existing.lastModified == probe.lastModified,
           (existing.requestIdentityKey == requestIdentityKey || existing.requestIdentityKey == nil) {
            existing.lastAccessedAt = Date()
            PlaybackStreamDiskCache.writeManifest(existing, to: directory)
            return (candidate, existing)
        }

        // A typed identity may have created the content namespace before a later
        // exact-URL reopen loses torrent metadata. Reuse only a manifest carrying
        // the complete exact request signature and matching validators/length.
        if !FileManager.default.fileExists(atPath: directory.path),
           let entries = try? FileManager.default.contentsOfDirectory(
                at: cacheRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
           ) {
            for entry in entries {
                guard var existing = PlaybackStreamDiskCache.readManifest(in: entry),
                      entry.lastPathComponent == existing.sessionID,
                      existing.requestIdentityKey == requestIdentityKey,
                      existing.fileLength == probe.contentLength,
                      existing.etag == probe.etag,
                      existing.lastModified == probe.lastModified else { continue }
                existing.lastAccessedAt = Date()
                PlaybackStreamDiskCache.writeManifest(existing, to: entry)
                return (existing.sessionID, existing)
            }
        }

        // A missing/corrupt manifest cannot authorize reuse of orphaned chunks.
        let chosenID = FileManager.default.fileExists(atPath: directory.path)
            ? candidate + "_" + UUID().uuidString
            : candidate
        let manifest = PlaybackStreamManifest(
            sessionID: chosenID,
            fileLength: probe.contentLength,
            etag: probe.etag,
            lastModified: probe.lastModified,
            canonicalMediaKey: canonicalMediaKey,
            cacheFileIdentity: nil,
            requestIdentityKey: requestIdentityKey,
            filename: filename ?? remoteURL.lastPathComponent,
            normalizedURLPath: remoteURL.absoluteString.components(separatedBy: "?")[0].components(separatedBy: "#")[0],
            createdAt: Date(),
            lastAccessedAt: Date()
        )
        return (chosenID, manifest)
    }

    private static func requestIdentityKey(
        for remoteURL: URL, headers: [String: String], probe: StreamProbeResult
    ) -> String {
        var identity: [String?] = [remoteURL.absoluteString, String(probe.contentLength), probe.etag, probe.lastModified]
        for key in headers.keys.sorted() {
            identity.append(key.lowercased())
            identity.append(headers[key])
        }
        // Without an upstream validator, the same request can return different
        // bytes of the same length. Isolate this load from persisted URL caches.
        // Trusted immutable file identities still reuse their content namespace.
        if probe.etag == nil, probe.lastModified == nil {
            identity.append(UUID().uuidString)
        }
        let identityData = (try? JSONEncoder().encode(identity)) ?? Data(remoteURL.absoluteString.utf8)
        let hash = SHA256.hash(data: identityData)
        return "url_v2_" + hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Prepares a hybrid disk cache server for a remote stream URL if Range requests are supported and caching is enabled.
    func prepareCacheServer(
        for remoteURL: URL,
        headers: [String: String] = [:],
        sessionToken: String = UUID().uuidString,
        cacheProfileIDOverride: String? = nil,
        canonicalMediaKey: String? = nil,
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        filename: String? = nil,
        durationSeconds: Double? = nil,
        customLimitGB: Int? = nil,
        targetLeadSeconds: Double? = nil,
        cacheRoot: URL? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        freeSpaceProvider: PlaybackStreamDiskCache.FreeSpaceProvider? = nil,
        preparationBudget: TimeInterval = PlaybackStreamCacheManager.defaultProbePreparationBudget
    ) async -> URL? {
        pendingSessionToken = sessionToken
        guard !Task.isCancelled else {
            if pendingSessionToken == sessionToken { pendingSessionToken = nil }
            return nil
        }
        let profileID = cacheProfileIDOverride ?? ProfileSettings.activeProfileID ?? ""
        let probe: StreamProbeResult
        if let memo = PlaybackStreamRangeProbeMemo.shared.take(url: remoteURL, headers: headers, profileID: profileID) {
            probe = memo
            diskCacheLog.info("Cache probe outcome=reused warm memo length=\(memo.contentLength)")
        } else {
            probe = await trackRangeProbe(
                url: remoteURL, headers: headers, sessionConfiguration: sessionConfiguration,
                preparationBudget: preparationBudget, sessionToken: sessionToken
            )
        }
        guard !Task.isCancelled else {
            if pendingSessionToken == sessionToken { pendingSessionToken = nil }
            return nil
        }
        guard pendingSessionToken == sessionToken else {
            diskCacheLog.info("Cache preparation outcome=superseded origin=\(AddonTransportUrls.diagnosticDescription(for: remoteURL))")
            return nil
        }
        guard probe.supportsRange, (probe.contentLength > 10 * 1024 * 1024 || cacheRoot != nil) else {
            diskCacheLog.info("Cache preparation outcome=range_unsupported")
            pendingSessionToken = nil
            return nil
        }

        let storedLimit = ProfileSettings.current.integer(forKey: SettingsKey.hybridDiskCacheLimitGB)
        let limitGB = min(50, max(5, customLimitGB ?? (storedLimit > 0 ? storedLimit : 20)))
        let limitBytes = Int64(limitGB) * 1024 * 1024 * 1024

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = cacheRoot ?? caches.appendingPathComponent("PlaybackStreamCache", isDirectory: true)

        let (sessionID, manifest) = resolveVerifiedSession(
            for: remoteURL,
            probe: probe,
            headers: headers,
            cacheFileIdentity: cacheFileIdentity,
            canonicalMediaKey: canonicalMediaKey,
            filename: filename,
            cacheRoot: root
        )

        let server = PlaybackStreamCacheServer(
            remoteURL: remoteURL,
            fileLength: probe.contentLength,
            customHeaders: headers,
            sessionID: sessionID,
            maxDiskCacheSizeBytes: limitBytes,
            targetLeadSeconds: targetLeadSeconds ?? 600.0,
            cacheRoot: root,
            manifest: manifest,
            sessionConfiguration: sessionConfiguration,
            maxBatchChunks: 16,
            freeSpaceProvider: freeSpaceProvider
        )
        if let durationSeconds, durationSeconds > 0 {
            await server.updateTimeline(playheadOffset: 0, durationSeconds: durationSeconds)
            guard !Task.isCancelled, pendingSessionToken == sessionToken else {
                diskCacheLog.info("Cache preparation outcome=superseded_after_timeline origin=\(AddonTransportUrls.diagnosticDescription(for: remoteURL))")
                await discardPreparedServer(server, sessionToken: sessionToken, wasPublished: false)
                return nil
            }
        }

        do {
            let localURL = try await server.start()
            guard !Task.isCancelled, pendingSessionToken == sessionToken else {
                diskCacheLog.info("Cache preparation outcome=superseded_after_start origin=\(AddonTransportUrls.diagnosticDescription(for: remoteURL))")
                await discardPreparedServer(server, sessionToken: sessionToken, wasPublished: false)
                return nil
            }

            // Publish the new owner before awaiting old-server cleanup. stop() can suspend
            // while pending writes flush, so no manager state can be mutated after that await.
            let oldServer = activeServer
            activeServer = server
            activeSessionURL = remoteURL
            activeSessionToken = sessionToken
            pendingSessionToken = nil

            if let oldServer, oldServer !== server {
                let oldProxyURL = await oldServer.localURL
                AetherEngine.discardPrewarmedSource(url: oldProxyURL)
                await serverStopper(oldServer)
                guard !Task.isCancelled else {
                    diskCacheLog.info("Cache preparation outcome=cancelled_after_old_server_stop origin=\(AddonTransportUrls.diagnosticDescription(for: remoteURL))")
                    await discardPreparedServer(server, sessionToken: sessionToken, wasPublished: true)
                    return nil
                }
                guard activeServer === server, activeSessionToken == sessionToken else {
                    diskCacheLog.info("Cache preparation outcome=superseded_after_old_server_stop origin=\(AddonTransportUrls.diagnosticDescription(for: remoteURL))")
                    return nil
                }
            }
            guard activeServer === server, activeSessionToken == sessionToken else {
                diskCacheLog.info("Cache preparation outcome=superseded_before_return")
                return nil
            }
            if AetherEngine.isPrewarmed(url: remoteURL) {
                if AetherEngine.transferPrewarmedSource(from: remoteURL, to: localURL, httpHeaders: headers,
                                                        expectedContentLength: probe.contentLength) {
                    diskCacheLog.info("Cache startup warm remapped to local proxy")
                } else {
                    diskCacheLog.info("Cache startup warm declined: request mismatch")
                }
            }
            diskCacheLog.notice("Hybrid Disk Cache engaged for origin=\(AddonTransportUrls.diagnosticDescription(for: remoteURL)) [session=\(sessionID)] -> \(localURL.absoluteString)")
            return localURL
        } catch {
            if pendingSessionToken == sessionToken {
                pendingSessionToken = nil
            }
            await serverStopper(server)
            diskCacheLog.error("Failed to start PlaybackStreamCacheServer origin=\(AddonTransportUrls.diagnosticDescription(for: remoteURL, error: error))")
            return nil
        }
    }

    func stopSession(token: String?) async {
        await stopActiveSession(token: token)
    }

    func stopActiveSession(token: String? = nil) async {
        if let token,
           pendingSessionToken != token,
           activeSessionToken != token {
            diskCacheLog.info("Ignoring stop request for non-active cache session token \(token) (active is \(self.activeSessionToken ?? "nil"), pending is \(self.pendingSessionToken ?? "nil"))")
            return
        }

        if token == nil || pendingSessionToken == token {
            pendingSessionToken = nil
            cancelActiveProbe(forSessionToken: token)
        }

        let serverToStop: PlaybackStreamCacheServer?
        if token == nil || activeSessionToken == token {
            serverToStop = activeServer
            activeServer = nil
            activeSessionURL = nil
            activeSessionToken = nil
        } else {
            serverToStop = nil
        }

        if let serverToStop {
            let proxyURL = await serverToStop.localURL
            AetherEngine.discardPrewarmedSource(url: proxyURL)
            await serverStopper(serverToStop)
        }
    }

    private func cancelActiveProbe(forSessionToken token: String?) {
        guard let probe = activeProbe,
              token == nil || probe.sessionToken == token else { return }
        activeProbe = nil
        probe.task.cancel()
    }

    private func discardPreparedServer(
        _ server: PlaybackStreamCacheServer, sessionToken: String, wasPublished: Bool
    ) async {
        let ownsActiveServer = activeServer === server && activeSessionToken == sessionToken
        if ownsActiveServer {
            activeServer = nil
            activeSessionURL = nil
            activeSessionToken = nil
        }
        if pendingSessionToken == sessionToken { pendingSessionToken = nil }
        // A successor takes responsibility for stopping the server it replaces.
        if !wasPublished || ownsActiveServer {
            let proxyURL = await server.localURL
            AetherEngine.discardPrewarmedSource(url: proxyURL)
            await serverStopper(server)
        }
    }

    func currentCachedFraction() async -> Double {
        if let server = activeServer {
            return await server.cachedFraction()
        }
        return 0
    }

    func activeStreamMetrics() async -> (cachedBytes: Int64, totalBytes: Int64)? {
        guard let server = activeServer else { return nil }
        let total = await server.fileLength
        let cached = await server.currentCachedBytes
        return (cachedBytes: cached, totalBytes: total)
    }

    func activeConcurrencyMetrics() async -> (active: Int, currentMax: Int, configuredMax: Int)? {
        guard let server = activeServer else { return nil }
        return await server.concurrencyMetrics
    }

    /// Resolve a playback proxy URL to its immutable disk/origin source only while that exact
    /// server and manager session still own it. The server performs the port/token URL comparison.
    func thumbnailSource(for playbackURL: URL) async -> PlaybackStreamThumbnailSource? {
        guard let server = activeServer, let sessionToken = activeSessionToken,
              await server.matchesActivePlaybackURL(playbackURL),
              activeServer === server, activeSessionToken == sessionToken,
              let descriptor = await server.thumbnailSourceDescriptor(),
              activeServer === server, activeSessionToken == sessionToken else { return nil }
        return descriptor
    }

    func currentCachedRanges() async -> [Range<Int64>] {
        if let server = activeServer {
            return await server.cachedByteRanges()
        }
        return []
    }

    func notifySeek(for sourceURL: URL, playheadSeconds: Double, totalDuration: Double) async {
        guard let server = activeServer,
              activeSessionURL == sourceURL || sourceURL.host == "127.0.0.1" || sourceURL.host == "localhost" || activeSessionURL == nil,
              totalDuration.isFinite, totalDuration > 0, playheadSeconds.isFinite else { return }
        let fraction = min(1, max(0, playheadSeconds / totalDuration))
        let length = await server.fileLength
        let offset = fraction >= 1 ? length : Int64(fraction * Double(length))
        await server.updateTimeline(playheadOffset: offset, durationSeconds: totalDuration, isSeek: true)
    }

    func updateTimeline(playheadSeconds: Double, totalDuration: Double) async {
        guard let server = activeServer, totalDuration > 0, playheadSeconds >= 0 else { return }
        let totalBytes = await server.fileLength
        guard totalBytes > 0 else { return }
        let playheadByte = min(totalBytes, max(0, Int64((playheadSeconds / totalDuration) * Double(totalBytes))))
        await server.updateTimeline(playheadOffset: playheadByte, durationSeconds: totalDuration)
    }

    func contiguousCachedForwardSeconds(playheadSeconds: Double, totalDuration: Double) async -> Double {
        guard let server = activeServer, totalDuration > 0, playheadSeconds >= 0 else { return 0 }
        let totalBytes = await server.fileLength
        guard totalBytes > 0 else { return 0 }
        let playheadByte = min(totalBytes, max(0, Int64((playheadSeconds / totalDuration) * Double(totalBytes))))
        await server.updateTimeline(playheadOffset: playheadByte, durationSeconds: totalDuration)
        let bytesAhead = await server.contiguousCachedBytesAhead(of: playheadByte)
        guard bytesAhead > 0 else { return 0 }
        let fractionAhead = Double(bytesAhead) / Double(totalBytes)
        return fractionAhead * totalDuration
    }
}
