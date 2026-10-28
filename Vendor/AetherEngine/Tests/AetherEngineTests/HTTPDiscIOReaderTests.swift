// Remote disc-image IOReader over HTTP byte-range requests (#64 follow-up: network .iso playback).
// Pure helpers are unit-tested directly; read/seek correctness and disc detection over HTTP are
// tested against an in-process mock URLProtocol that serves byte ranges from fixture bytes, so no
// real network or server is involved.
import Foundation
import Testing
@testable import AetherEngine

// Serialized: the tests share MockRangeURLProtocol's static byte store keyed by URL; running them
// in parallel would let one test's fixture bytes answer another's request.
@Suite("HTTPDiscIOReader (#64 remote disc images)", .serialized, .offCooperativePool)
struct HTTPDiscIOReaderTests {

    // MARK: - Pure helpers

    @Test("Range header spans the requested half-open window inclusively")
    func rangeHeader() {
        #expect(HTTPDiscIOReader.rangeHeader(offset: 0, length: 1) == "bytes=0-0")
        #expect(HTTPDiscIOReader.rangeHeader(offset: 2048, length: 4096) == "bytes=2048-6143")
    }

    @Test("Content-Range total is parsed; unknown size (*) is nil")
    func contentRange() {
        #expect(HTTPDiscIOReader.parseContentRangeTotal("bytes 0-0/12345") == 12345)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("bytes 2048-6143/34960244736") == 34_960_244_736)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("bytes 0-0/*") == nil)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("garbage") == nil)
    }

    @Test("Disc-image URL detection gates the HTTP disc path")
    func discImageURL() {
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/movie.iso")!) == true)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/MOVIE.ISO")!) == true)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/disc.img")!) == true)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/video.mp4")!) == false)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/stream.m3u8")!) == false)
    }

    @Test("Read-ahead window grows on sequential continuation and resets otherwise")
    func adaptiveWindow() {
        // Sequential continuation (position == lastFetchEnd) doubles, capped at maxChunk.
        #expect(HTTPDiscIOReader.nextChunkSize(position: 4096, lastFetchEnd: 4096, current: 4096,
                                               base: 4096, maxChunk: 32768) == 8192)
        #expect(HTTPDiscIOReader.nextChunkSize(position: 8192, lastFetchEnd: 8192, current: 8192,
                                               base: 4096, maxChunk: 32768) == 16384)
        #expect(HTTPDiscIOReader.nextChunkSize(position: 99999, lastFetchEnd: 99999, current: 32768,
                                               base: 4096, maxChunk: 32768) == 32768)  // capped
        // A non-contiguous read (seek) resets to base.
        #expect(HTTPDiscIOReader.nextChunkSize(position: 200000, lastFetchEnd: 8192, current: 16384,
                                               base: 4096, maxChunk: 32768) == 4096)
        // No prior refill yet -> base.
        #expect(HTTPDiscIOReader.nextChunkSize(position: 0, lastFetchEnd: -1, current: 4096,
                                               base: 4096, maxChunk: 32768) == 4096)
    }

    // MARK: - Read / seek over a mock range server

    private func makeReader(_ bytes: [UInt8], base: Int = 4096, maxChunk: Int = 4096,
                            failFirst: Int = 0) -> HTTPDiscIOReader? {
        let url = URL(string: "http://disc.test/test.iso")!
        MockRangeURLProtocol.reset()
        MockRangeURLProtocol.bytesByURL[url.absoluteString] = Data(bytes)
        if failFirst > 0 { MockRangeURLProtocol.failFirstForURL[url.absoluteString] = failFirst }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRangeURLProtocol.self]
        return HTTPDiscIOReader(url: url, baseChunkSize: base, maxChunkSize: maxChunk,
                                requestTimeout: 5, sessionConfiguration: config)
    }

    private func readAt(_ reader: HTTPDiscIOReader, offset: Int64, count: Int) -> [UInt8]? {
        guard reader.seek(offset: offset, whence: SEEK_SET) == offset else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        let n = out.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32(count)) }
        return n == count ? out : nil
    }

    private func nonperiodicBytes(count: Int) -> [UInt8] {
        var state: UInt32 = 0x6D2B_79F5
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state >> 11)
        }
    }

    private func dataRequestCount(for url: String) -> Int {
        MockRangeURLProtocol.rangeRequests(for: url).filter { $0 != "bytes=0-0" }.count
    }

    @Test("AVSEEK_SIZE returns the total size from the range probe")
    func sizeProbe() {
        let r = makeReader([UInt8](0..<200))
        #expect(r != nil)
        #expect(r?.seek(offset: 0, whence: 65536) == 200)  // AVSEEK_SIZE
    }

    @Test("Sequential and random reads return the exact source bytes")
    func reads() throws {
        let src = (0..<10_000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))
        var out = [UInt8](repeating: 0, count: 6000)
        // sequential read across chunk boundaries (chunkSize 4096)
        let n1 = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 6000) }
        #expect(n1 > 0)
        #expect(Array(out[0..<Int(n1)]) == Array(src[0..<Int(n1)]))
        // random seek then read
        #expect(r.seek(offset: 8192, whence: SEEK_SET) == 8192)
        var out2 = [UInt8](repeating: 0, count: 100)
        let n2 = out2.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(n2 == 100)
        #expect(Array(out2[0..<100]) == Array(src[8192..<8292]))
    }

    @Test("Alternating small reads reuse two prior UDF-like windows")
    func alternatingSmallReadsReuseWindows() throws {
        let url = "http://disc.test/test.iso"
        let src = nonperiodicBytes(count: 7 * 1024 * 1024)
        let r = try #require(makeReader(src, base: 64 * 1024, maxChunk: 64 * 1024))
        let regionA = 600 * 1024
        let regionB = 6 * 1024 * 1024

        for i in 0..<24 {
            let region = i.isMultiple(of: 2) ? regionA : regionB
            let offset = region + (i / 2) * 2048
            let actual = try #require(readAt(r, offset: Int64(offset), count: 2048))
            #expect(actual == Array(src[offset..<(offset + 2048)]))
        }

        #expect(dataRequestCount(for: url) == 2)
        #expect(r.sourceBytesFetched == 2 * 64 * 1024)
    }

    @Test("Three-window LRU promotes an old window and evicts the least recently used")
    func smallWindowLRUPromotionAndEviction() throws {
        let url = "http://disc.test/test.iso"
        let src = nonperiodicBytes(count: 2 * 1024 * 1024)
        let r = try #require(makeReader(src, base: 64 * 1024, maxChunk: 64 * 1024))
        let windows = [100, 300, 500, 700, 900].map { $0 * 1024 }
        for offset in windows.prefix(4) {
            let actual = try #require(readAt(r, offset: Int64(offset), count: 2048))
            #expect(actual == Array(src[offset..<(offset + 2048)]))
        }

        // A is the oldest of the three parked windows. Promote it before E arrives; B should then
        // be evicted, while A remains reusable after another network refill.
        let promoted = windows[0]
        let actualA = try #require(readAt(r, offset: Int64(promoted), count: 2048))
        #expect(actualA == Array(src[promoted..<(promoted + 2048)]))
        let actualE = try #require(readAt(r, offset: Int64(windows[4]), count: 2048))
        #expect(actualE == Array(src[windows[4]..<(windows[4] + 2048)]))
        #expect(dataRequestCount(for: url) == 5)

        let rereadA = try #require(readAt(r, offset: Int64(promoted + 4096), count: 2048))
        #expect(rereadA == Array(src[(promoted + 4096)..<(promoted + 6144)]))
        #expect(dataRequestCount(for: url) == 5)

        let evictedB = windows[1]
        let rereadB = try #require(readAt(r, offset: Int64(evictedB), count: 2048))
        #expect(rereadB == Array(src[evictedB..<(evictedB + 2048)]))
        #expect(dataRequestCount(for: url) == 6)
    }

    @Test("A promoted small window permits adaptive growth at its cached frontier")
    func cachedFrontierContinuesAdaptiveReadAhead() throws {
        let url = "http://disc.test/test.iso"
        let src = nonperiodicBytes(count: 2 * 1024 * 1024)
        let base = 64 * 1024
        let r = try #require(makeReader(src, base: base, maxChunk: 256 * 1024))
        let start = 100 * 1024
        let other = 700 * 1024

        _ = try #require(readAt(r, offset: Int64(start), count: 2048))
        _ = try #require(readAt(r, offset: Int64(other), count: 2048))
        let promoted = start + 2048
        let prefix = try #require(readAt(r, offset: Int64(promoted), count: base - 2048))
        #expect(prefix == Array(src[promoted..<(start + base)]))

        let nextOffset = start + base
        let next = try #require(readAt(r, offset: Int64(nextOffset), count: 2048))
        #expect(next == Array(src[nextOffset..<(nextOffset + 2048)]))
        let ranges = MockRangeURLProtocol.rangeRequests(for: url)
        #expect(ranges.last == HTTPDiscIOReader.rangeHeader(offset: Int64(nextOffset), length: 2 * base))
        #expect(r.sourceBytesFetched == Int64(2 * base + 2 * base))
    }

    @Test("Cancel still allows cached reads and rejects a cache miss without another request")
    func cancellationAllowsCacheHitOnly() throws {
        let url = "http://disc.test/test.iso"
        let src = nonperiodicBytes(count: 2 * 1024 * 1024)
        let r = try #require(makeReader(src, base: 64 * 1024, maxChunk: 64 * 1024))
        let first = 100 * 1024
        let second = 500 * 1024
        _ = try #require(readAt(r, offset: Int64(first), count: 2048))
        _ = try #require(readAt(r, offset: Int64(second), count: 2048))
        r.cancel()

        let cached = try #require(readAt(r, offset: Int64(first + 2048), count: 2048))
        #expect(cached == Array(src[(first + 2048)..<(first + 4096)]))
        #expect(dataRequestCount(for: url) == 2)

        #expect(r.seek(offset: 900 * 1024, whence: SEEK_SET) == 900 * 1024)
        var out = [UInt8](repeating: 0, count: 2048)
        let miss = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 2048) }
        #expect(miss == -1)
        #expect(dataRequestCount(for: url) == 2)
    }

    @Test("A cached window ending at a warm-tail boundary hands off to resident bytes")
    func cachedWindowHandsOffToWarmTail() throws {
        let url = URL(string: "http://disc.test/test.iso")!
        let src = nonperiodicBytes(count: 3 * 1024 * 1024)
        let base = 64 * 1024
        let tailStart = 640 * 1024
        let tail = Array(src[tailStart..<(tailStart + 16 * 1024)])
        let prewarmed = PrewarmedSource(
            head: ResidentSpan(start: 0, data: Data()),
            tail: ResidentSpan(start: Int64(tailStart), data: Data(tail)),
            contentLength: Int64(src.count), requestHeaders: [:], resolvedURL: nil)

        MockRangeURLProtocol.reset()
        MockRangeURLProtocol.bytesByURL[url.absoluteString] = Data(src)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRangeURLProtocol.self]
        let reader = try #require(HTTPDiscIOReader(
            url: url, baseChunkSize: base, maxChunkSize: base,
            sessionConfiguration: config, prewarmed: prewarmed))
        defer { reader.close() }

        let firstStart = tailStart - base
        let otherStart = 1_500 * 1024
        let first = try #require(readAt(reader, offset: Int64(firstStart), count: 2048))
        #expect(first == Array(src[firstStart..<(firstStart + 2048)]))
        let other = try #require(readAt(reader, offset: Int64(otherStart), count: 2048))
        #expect(other == Array(src[otherStart..<(otherStart + 2048)]))

        // The first fetched window ends exactly where the warmed tail begins. Promote it after
        // displacing it with the other region, then consume continuously through the warm boundary.
        let promotedStart = firstStart + 2048
        #expect(reader.seek(offset: Int64(promotedStart), whence: SEEK_SET) == Int64(promotedStart))
        let requested = base - 2048 + 4096
        var actual: [UInt8] = []
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: requested)
        defer { out.deallocate() }
        while actual.count < requested {
            let n = reader.read(out, size: Int32(requested - actual.count))
            guard n > 0 else { break }
            actual.append(contentsOf: UnsafeBufferPointer(start: out, count: Int(n)))
        }
        let expected = Array(src[promotedStart..<(tailStart + 4096)])
        #expect(actual == expected)

        #expect(MockRangeURLProtocol.rangeRequests(for: url.absoluteString) == [
            HTTPDiscIOReader.rangeHeader(offset: Int64(firstStart), length: base),
            HTTPDiscIOReader.rangeHeader(offset: Int64(otherStart), length: base),
        ])
        #expect(reader.sourceBytesFetched == Int64(2 * base))
    }

    @Test("Adaptive windows larger than the base are not admitted to the LRU")
    func largeWindowIsNotCached() throws {
        let url = "http://disc.test/test.iso"
        let src = nonperiodicBytes(count: 2 * 1024 * 1024)
        let base = 64 * 1024
        let r = try #require(makeReader(src, base: base, maxChunk: 256 * 1024))
        let start = 100 * 1024
        let secondStart = start + base
        let thirdStart = secondStart + 2 * base

        _ = try #require(readAt(r, offset: Int64(start), count: base))
        _ = try #require(readAt(r, offset: Int64(secondStart), count: 2 * base))
        _ = try #require(readAt(r, offset: Int64(thirdStart), count: 4 * base))
        _ = try #require(readAt(r, offset: Int64(900 * 1024), count: 2048))
        #expect(dataRequestCount(for: url) == 4)

        let insideLargeWindow = start + 220 * 1024
        let actual = try #require(readAt(r, offset: Int64(insideLargeWindow), count: 2048))
        #expect(actual == Array(src[insideLargeWindow..<(insideLargeWindow + 2048)]))
        #expect(dataRequestCount(for: url) == 5)
    }

    @Test("Reading at EOF returns 0; seek past end then read is empty")
    func eof() throws {
        let r = try #require(makeReader([UInt8](repeating: 7, count: 50)))
        #expect(r.seek(offset: 50, whence: SEEK_SET) == 50)
        var out = [UInt8](repeating: 0, count: 16)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 16) }
        #expect(n == 0)
    }

    @Test("A transient request failure is retried")
    func retry() throws {
        let src = (0..<2000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))  // probe succeeds cleanly
        // Inject one network failure for the first read's range request; the retry must recover it.
        MockRangeURLProtocol.failFirstForURL["http://disc.test/test.iso"] = 1
        var out = [UInt8](repeating: 0, count: 100)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(n == 100)
        #expect(Array(out[0..<100]) == Array(src[0..<100]))
    }

    // audit NET-9: a 206 that claims a different start than what was requested must never be
    // accepted; the reader would otherwise place those bytes at `position` and corrupt whatever
    // structure or stream is read through it.
    @Test("A 206 whose Content-Range start does not match the request is refused, not served")
    func misrangedResponseIsRefused() throws {
        let src = (0..<2000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))  // the offset-0 probe is unaffected and succeeds
        MockRangeURLProtocol.misrangedFor.insert("http://disc.test/test.iso")
        #expect(r.seek(offset: 1000, whence: SEEK_SET) == 1000)
        var out = [UInt8](repeating: 0, count: 100)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(n == -1)
    }

    // audit NET-9: a proxy that falls back to a full 200 mid-session (cache miss, range
    // coalescing, a Range-stripping origin) must be treated as fatal for this reader, not read as
    // if byte 0 of the body were the requested offset.
    @Test("A 200 answer mid-session is refused, not served as if it started at the requested offset")
    func plain200MidSessionIsRefused() throws {
        let src = (0..<2000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))  // the offset-0 probe is unaffected and succeeds
        MockRangeURLProtocol.plain200AfterProbeFor.insert("http://disc.test/test.iso")
        #expect(r.seek(offset: 1000, whence: SEEK_SET) == 1000)
        var out = [UInt8](repeating: 0, count: 100)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(n == -1)
    }

    @Test("A server without range support fails init (caller falls back to streaming)")
    func noRangeSupport() {
        let url = URL(string: "http://disc.test/noRange.iso")!
        MockRangeURLProtocol.bytesByURL[url.absoluteString] = Data([1, 2, 3])
        MockRangeURLProtocol.disableRangeFor.insert(url.absoluteString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRangeURLProtocol.self]
        #expect(HTTPDiscIOReader(url: url, sessionConfiguration: config) == nil)
        MockRangeURLProtocol.disableRangeFor.remove(url.absoluteString)
    }

    // MARK: - Disc detection over HTTP

    @Test("DiscReader.wrap recognizes an ISO9660 disc read over HTTP")
    func discDetectionOverHTTP() throws {
        let disc = ISO9660Fixture.make(files: [
            .init(name: "VTS_01_1.VOB", length: 2048),
        ])
        let r = try #require(makeReader([UInt8](disc)))
        let wrapped = try DiscReader.wrap(r)
        #expect(wrapped != nil)
    }

    // MARK: - Source byte accounting

    @Test("The reader counts the bytes it pulled from the origin")
    func countsPulledBytes() throws {
        let src = (0..<200_000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))
        #expect(r.sourceBytesFetched == 0)
        var out = [UInt8](repeating: 0, count: 6000)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 6000) }
        #expect(n == 6000)
        // One refill at the 64 KiB floor covers the 6000 bytes read: the count is the transfer.
        #expect(r.sourceBytesFetched == 65_536)
        // A re-read inside the buffer pulls nothing new.
        #expect(r.seek(offset: 4500, whence: SEEK_SET) == 4500)
        _ = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(r.sourceBytesFetched == 65_536)
        // A seek out of the buffer refills, and that refill counts.
        #expect(r.seek(offset: 150_000, whence: SEEK_SET) == 150_000)
        _ = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(r.sourceBytesFetched == 65_536 + 50_000)
    }

    // A disc session reports `LiveTelemetry.demuxerBytesFetched` and the software-path throughput
    // from this counter. It read 0 for every custom source, so a remote disc image showed no source
    // bytes at all while the reader pulled the whole title.
    @Test("A remote disc reports the reader's bytes through its extent map and the demuxer bridge")
    func discBridgeReportsPulledBytes() throws {
        let disc = ISO9660Fixture.make(files: [
            .init(name: "VTS_01_1.VOB", length: 2048),
        ])
        let r = try #require(makeReader([UInt8](disc)))
        let wrapped = try #require(try DiscReader.wrap(r))
        let bridge = CustomIOReaderBridge(reader: wrapped.reader)
        #expect(r.sourceBytesFetched > 0)
        #expect(bridge.cumulativeBytesFetched == r.sourceBytesFetched)
    }

    @Test("A host's own reader still reports no source bytes")
    func hostReaderReportsNothing() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data(repeating: 1, count: 4096)))
        #expect(bridge.cumulativeBytesFetched == 0)
    }
}

/// In-process URLProtocol that answers `Range` requests from `bytesByURL`, returning 206 + a
/// `Content-Range` header, so HTTPDiscIOReader can be exercised without a real server.
final class MockRangeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytesByURL: [String: Data] = [:]
    nonisolated(unsafe) static var disableRangeFor: Set<String> = []
    /// Number of leading requests per URL that should fail with a network error (retry testing).
    nonisolated(unsafe) static var failFirstForURL: [String: Int] = [:]
    /// audit NET-9: any request at a non-zero offset gets a 206 that claims to start at 0 (a
    /// mis-ranged response) instead of the requested offset, with junk bytes so a caller that
    /// trusted it would read garbage rather than the source.
    nonisolated(unsafe) static var misrangedFor: Set<String> = []
    /// audit NET-9: any request at a non-zero offset gets a full 200 instead of a 206 (a
    /// Range-ignoring proxy or a cache-miss fallback), body starting at byte 0 of the source.
    nonisolated(unsafe) static var plain200AfterProbeFor: Set<String> = []
    private static let rangeRequestLock = NSLock()
    nonisolated(unsafe) private static var rangeRequestsByURL: [String: [String]] = [:]

    static func reset() {
        bytesByURL = [:]; disableRangeFor = []; failFirstForURL = [:]
        misrangedFor = []; plain200AfterProbeFor = []
        rangeRequestLock.lock(); rangeRequestsByURL = [:]; rangeRequestLock.unlock()
    }

    static func rangeRequests(for url: String) -> [String] {
        rangeRequestLock.lock(); defer { rangeRequestLock.unlock() }
        return rangeRequestsByURL[url] ?? []
    }

    private static func recordRangeRequest(_ range: String, for url: String) {
        rangeRequestLock.lock(); defer { rangeRequestLock.unlock() }
        rangeRequestsByURL[url, default: []].append(range)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let data = Self.bytesByURL[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        if let range = request.value(forHTTPHeaderField: "Range") {
            Self.recordRangeRequest(range, for: url.absoluteString)
        }
        if let remaining = Self.failFirstForURL[url.absoluteString], remaining > 0 {
            Self.failFirstForURL[url.absoluteString] = remaining - 1
            // A clean 503 (rather than a transport error) completes the task and exercises the
            // reader's non-2xx -> retry path without URLProtocol failure-handling quirks.
            let resp = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "0"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let total = data.count
        let rangeOnly = !Self.disableRangeFor.contains(url.absoluteString)
        var lower = 0, upper = total - 1, status = 200
        var headers: [String: String] = ["Content-Type": "application/octet-stream"]
        if rangeOnly, let rv = request.value(forHTTPHeaderField: "Range"),
           rv.hasPrefix("bytes=") {
            let parts = rv.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            lower = Int(parts.first ?? "0") ?? 0
            upper = (parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1)
            upper = min(upper, total - 1)
            status = 206
            headers["Content-Range"] = "bytes \(lower)-\(upper)/\(total)"
        }
        var slice = (lower <= upper && lower < total) ? data.subdata(in: lower..<(upper + 1)) : Data()
        if lower > 0, status == 206, Self.misrangedFor.contains(url.absoluteString) {
            headers["Content-Range"] = "bytes 0-\(slice.count - 1)/\(total)"
            slice = Data(repeating: 0xEE, count: slice.count)
        }
        if lower > 0, status == 206, Self.plain200AfterProbeFor.contains(url.absoluteString) {
            status = 200
            headers["Content-Range"] = nil
            slice = data
        }
        headers["Content-Length"] = String(slice.count)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }
}
