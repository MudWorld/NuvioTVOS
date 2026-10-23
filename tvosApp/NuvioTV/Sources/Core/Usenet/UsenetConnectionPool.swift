import Foundation
import OSLog

let usenetLog = Logger(subsystem: "com.nuvio.tv", category: "Usenet")

/// Token bucket for the optional speed cap: hands out bytes at a steady rate
/// with a small burst, so requests are spread out instead of fired at once.
struct UsenetTokenBucket {
    let bytesPerSecond: Double
    let capacity: Double
    private(set) var tokens: Double
    private var last: ContinuousClock.Instant

    init(megabitsPerSecond: Int, now: ContinuousClock.Instant) {
        bytesPerSecond = Double(max(1, megabitsPerSecond)) * 1_000_000 / 8
        capacity = max(1_048_576, bytesPerSecond / 2)
        tokens = capacity
        last = now
    }

    /// Takes `bytes` and returns how long the caller has to wait before using them.
    mutating func take(_ bytes: Int, now: ContinuousClock.Instant) -> Duration {
        let elapsed = now - last
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(capacity, tokens + max(0, seconds) * bytesPerSecond)
        last = now
        tokens -= Double(bytes)
        guard tokens < 0 else { return .zero }
        return .seconds(-tokens / bytesPerSecond)
    }
}

/// The speed cap shared by every connection of one stream.
actor UsenetRateLimiter {
    private var bucket: UsenetTokenBucket

    init?(megabitsPerSecond: Int) {
        guard megabitsPerSecond > 0 else { return nil }
        bucket = UsenetTokenBucket(megabitsPerSecond: megabitsPerSecond, now: .now)
    }

    func consume(_ bytes: Int) async throws {
        let wait = bucket.take(bytes, now: .now)
        if wait > .zero { try await Task.sleep(for: wait) }
    }
}

/// Long-lived authenticated NNTP connections to one or more providers.
///
/// Each server gets up to its `maxConnections`. An article is tried on the
/// servers in order: a missing article (430) moves on to the next server, a
/// dropped connection is replaced and retried, a rejected login stops.
actor UsenetConnectionPool {
    private struct ServerState {
        let config: UsenetServerConfig
        var idle: [UsenetNNTPConnection] = []
        var open = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private var servers: [ServerState]
    private var closed = false
    private let limiter: UsenetRateLimiter?

    /// Connections across all servers, the limit for concurrent fetches.
    nonisolated let totalConnections: Int
    /// The speed cap in Mbit/s, 0 for none.
    nonisolated let speedLimitMbps: Int

    init(servers: [UsenetServerConfig], speedLimitMbps: Int = 0) {
        self.servers = servers.map { ServerState(config: $0) }
        self.totalConnections = max(1, servers.reduce(0) { $0 + $1.maxConnections })
        self.speedLimitMbps = max(0, speedLimitMbps)
        self.limiter = UsenetRateLimiter(megabitsPerSecond: speedLimitMbps)
    }

    enum FetchOutcome: Sendable {
        case body(Data)
        /// No server has the article (taken down or never fully posted).
        case missing
    }

    /// Fetches an article body, trying every server before giving up.
    /// `paced` fetches (playback) wait for the speed cap; start-up fetches don't.
    func fetch(messageID: String, expectedBytes: Int = 0, paced: Bool = false) async throws -> FetchOutcome {
        if paced, let limiter, expectedBytes > 0 {
            try await limiter.consume(expectedBytes)
        }
        switch try await run(messageID: messageID, statOnly: false) {
        case .body(let body): return .body(body)
        case .exists, .missing: return .missing
        }
    }

    /// Whether any server still has the article (`STAT`, nothing downloaded).
    func exists(messageID: String) async throws -> Bool {
        switch try await run(messageID: messageID, statOnly: true) {
        case .exists, .body: return true
        case .missing: return false
        }
    }

    struct Stats: Equatable, Sendable {
        var busyConnections = 0
        var openConnections = 0
        var totalConnections = 0
        /// Articles a later server had after the first one didn't.
        var fallbackArticles = 0
        var primaryHost = ""
        var serverCount = 0
    }

    func stats() -> Stats {
        Stats(
            busyConnections: servers.reduce(0) { $0 + max(0, $1.open - $1.idle.count) },
            openConnections: servers.reduce(0) { $0 + $1.open },
            totalConnections: totalConnections,
            fallbackArticles: fallbackArticles,
            primaryHost: servers.first?.config.host ?? "",
            serverCount: servers.count
        )
    }

    private var fallbackArticles = 0

    private enum Answer {
        case body(Data)
        case exists
        case missing
    }

    private func run(messageID: String, statOnly: Bool) async throws -> Answer {
        var authError: UsenetNNTPError?
        for index in servers.indices {
            var attempt = 0
            while attempt < 3 {
                attempt += 1
                try Task.checkCancellation()
                let connection: UsenetNNTPConnection
                do {
                    connection = try await acquire(index)
                } catch let error as UsenetNNTPError {
                    if case .authenticationFailed = error { authError = error; break }
                    if error.isTransient, attempt < 3 { continue }
                    break
                }
                do {
                    if statOnly {
                        let found = try await connection.stat(messageID: messageID)
                        release(connection, to: index)
                        if found { return .exists }
                        attempt = 3          // next server
                    } else {
                        let body = try await connection.fetchBody(messageID: messageID)
                        release(connection, to: index)
                        if index > 0 { fallbackArticles += 1 }
                        return .body(body)
                    }
                } catch let error as UsenetNNTPError {
                    switch error {
                    case .articleUnavailable:
                        release(connection, to: index)
                        attempt = 3          // next server
                    case .authenticationFailed:
                        discard(connection, from: index)
                        authError = error
                        attempt = 3
                    default:
                        discard(connection, from: index)
                        if !error.isTransient { attempt = 3 }
                    }
                } catch {
                    discard(connection, from: index)
                    throw error
                }
            }
        }
        if let authError {
            throw UsenetError.serverRejected(Self.describe(authError))
        }
        return .missing
    }

    func shutdown() {
        closed = true
        for index in servers.indices {
            let connections = servers[index].idle
            servers[index].idle = []
            servers[index].open = 0
            let waiters = servers[index].waiters
            servers[index].waiters = []
            waiters.forEach { $0.resume() }
            Task { for connection in connections { await connection.close() } }
        }
    }

    // MARK: - Connections

    private func acquire(_ index: Int) async throws -> UsenetNNTPConnection {
        while true {
            guard !closed else { throw CancellationError() }
            if let connection = servers[index].idle.popLast() {
                if await connection.isClosed {
                    servers[index].open -= 1
                    continue
                }
                return connection
            }
            if servers[index].open < servers[index].config.maxConnections {
                servers[index].open += 1
                let connection = UsenetNNTPConnection(config: servers[index].config)
                do {
                    try await connection.open()
                    return connection
                } catch {
                    servers[index].open -= 1
                    wakeOne(index)
                    throw error
                }
            }
            await withCheckedContinuation { continuation in
                servers[index].waiters.append(continuation)
            }
        }
    }

    private func release(_ connection: UsenetNNTPConnection, to index: Int) {
        guard !closed else {
            Task { await connection.close() }
            return
        }
        servers[index].idle.append(connection)
        wakeOne(index)
    }

    private func discard(_ connection: UsenetNNTPConnection, from index: Int) {
        Task { await connection.close() }
        servers[index].open = max(0, servers[index].open - 1)
        wakeOne(index)
    }

    private func wakeOne(_ index: Int) {
        guard !servers[index].waiters.isEmpty else { return }
        servers[index].waiters.removeFirst().resume()
    }

    static func describe(_ error: UsenetNNTPError) -> String {
        switch error {
        case .authenticationFailed(let code):
            return L10n.format("usenet_error_auth", fallback: "Your Usenet server rejected the login (%d).", code)
        case .badGreeting(let code):
            return L10n.format("usenet_error_greeting", fallback: "The Usenet server refused the connection (%d).", code)
        case .connectionFailed(let message):
            return L10n.format("usenet_error_connect", fallback: "Couldn't connect to the Usenet server: %@", message)
        case .timeout:
            return L10n.string("usenet_error_timeout", fallback: "The Usenet server didn't answer in time.")
        default:
            return L10n.string("usenet_error_generic", fallback: "The Usenet server returned an error.")
        }
    }
}
