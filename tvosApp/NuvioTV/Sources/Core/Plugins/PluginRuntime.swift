//
//  PluginRuntime.swift
//  NuvioTV
//
//  Runs one scraper's `getStreams` in a fresh JavaScriptCore context, with the
//  same polyfills and native bridges the Android/iOS QuickJS runtime offers
//  (composeApp/.../features/plugins/runtime): fetch, URL, CryptoJS/WebCrypto,
//  TextEncoder and a cheerio subset. Each run gets its own VM on a background
//  queue, so native bridges may block (fetch is synchronous for the script).
//

import Foundation
import JavaScriptCore

enum PluginRuntime {
    /// Whole-run budget, as on Android.
    static let timeout: TimeInterval = 60

    static func execute(
        code: String,
        scraperId: String,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?,
        tmdbApiKey: String?
    ) async -> [PluginStreamResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let raw = PluginExecution(scraperId: scraperId, tmdbApiKey: tmdbApiKey).run(
                    code: code,
                    tmdbId: tmdbId,
                    mediaType: mediaType,
                    season: season,
                    episode: episode
                )
                continuation.resume(returning: parseResults(raw))
            }
        }
    }

    static let polyfillSource: String = {
        guard let url = Bundle.main.url(forResource: "PluginPolyfills", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("[Plugins] PluginPolyfills.js missing from bundle")
            return ""
        }
        return source
    }()

    // MARK: - Result parsing

    static func parseResults(_ raw: String?) -> [PluginStreamResult] {
        guard let raw, let data = raw.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return array.compactMap { element -> PluginStreamResult? in
            guard let item = element as? [String: Any] else { return nil }
            let url: String? = {
                if let value = item["url"] as? String { return value }
                if let nested = item["url"] as? [String: Any] { return nested["url"] as? String }
                return nil
            }()
            guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
            let subtitles = (item["subtitles"] as? [[String: Any]] ?? []).compactMap { sub -> PluginSubtitleResult? in
                guard let subURL = sub["url"] as? String, !subURL.isEmpty else { return nil }
                return PluginSubtitleResult(
                    url: subURL,
                    language: (sub["language"] as? String) ?? (sub["lang"] as? String) ?? "Unknown",
                    name: sub["name"] as? String
                )
            }
            return PluginStreamResult(
                title: string(item, "title") ?? string(item, "name") ?? "Unknown",
                name: string(item, "name"),
                url: url,
                quality: string(item, "quality"),
                size: string(item, "size"),
                language: string(item, "language"),
                provider: string(item, "provider"),
                infoHash: string(item, "infoHash"),
                headers: (item["headers"] as? [String: Any])?.compactMapValues { value in
                    if let text = value as? String { return text }
                    if let number = value as? NSNumber { return number.stringValue }
                    return nil
                }.nilIfEmpty,
                subtitles: subtitles
            )
        }
    }

    private static func string(_ item: [String: Any], _ key: String) -> String? {
        let value: String?
        if let text = item[key] as? String {
            value = text
        } else if let number = item[key] as? NSNumber {
            value = number.stringValue
        } else {
            value = nil
        }
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("[object") else { return nil }
        return value
    }
}

private extension Dictionary {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

// MARK: - One execution

/// Owns the JS context and every bridge for one `getStreams` call. Used from
/// a single background thread only.
private final class PluginExecution {
    private let scraperId: String
    private let tmdbApiKey: String?
    private var capturedResult: String?
    private let dom = PluginDomBridge()

    init(scraperId: String, tmdbApiKey: String?) {
        self.scraperId = scraperId
        self.tmdbApiKey = tmdbApiKey
    }

    func run(code: String, tmdbId: String, mediaType: String, season: Int?, episode: Int?) -> String? {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else { return nil }
        let tag = scraperId
        context.exceptionHandler = { _, exception in
            print("[Plugins] \(tag) JS exception: \(exception?.toString() ?? "unknown")")
        }

        installHostFunctions(in: context)
        context.evaluateScript("""
            globalThis.SCRAPER_ID = \(Self.jsonLiteral(scraperId));
            globalThis.SCRAPER_SETTINGS = {};
            globalThis.TMDB_API_KEY = \(Self.jsonLiteral(tmdbApiKey ?? ""));
            """)
        context.evaluateScript(Self.timerPrelude)
        context.evaluateScript(PluginRuntime.polyfillSource)
        context.evaluateScript("""
            var module = { exports: {} };
            var exports = module.exports;
            (function() {
            \(code)
            })();
            """)

        let seasonArg = season.map(String.init) ?? "undefined"
        let episodeArg = episode.map(String.init) ?? "undefined"
        context.evaluateScript("""
            (async function() {
                try {
                    var getStreams = (module.exports && module.exports.getStreams) || globalThis.getStreams;
                    if (!getStreams) {
                        console.error("getStreams function not found on module.exports or globalThis");
                        __capture_result("[]");
                        return;
                    }
                    var result = await getStreams(\(Self.jsonLiteral(tmdbId)), \(Self.jsonLiteral(mediaType)), \(seasonArg), \(episodeArg));
                    __capture_result(JSON.stringify(result || []));
                } catch (e) {
                    console.error("getStreams error:", e && e.message ? e.message : e, e && e.stack ? e.stack : "");
                    __capture_result("[]");
                }
            })();
            """)

        // Promise jobs drain after each evaluateScript; timers need driving.
        let deadline = Date().addingTimeInterval(PluginRuntime.timeout)
        while capturedResult == nil, Date() < deadline {
            let wait = context.evaluateScript("__runTimers()")?.toDouble() ?? -1
            if capturedResult != nil { break }
            if wait < 0 || wait.isNaN {
                // Nothing scheduled and no result: the script dropped its promise.
                break
            }
            Thread.sleep(forTimeInterval: min(max(wait, 1), 50) / 1000)
        }
        if capturedResult == nil {
            print("[Plugins] \(tag) finished without a result")
        }
        dom.clear()
        return capturedResult
    }

    // MARK: Host functions

    private func installHostFunctions(in context: JSContext) {
        let tag = scraperId
        let console = JSValue(newObjectIn: context)
        for level in ["log", "info", "debug", "warn", "error"] {
            let log: @convention(block) () -> Void = {
                let message = Self.arguments().map { $0.toString() ?? "" }.joined(separator: " ")
                print("[Plugins] \(tag) \(level): \(message)")
            }
            console?.setObject(log, forKeyedSubscript: level as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let capture: @convention(block) () -> Void = { [weak self] in
            self?.capturedResult = Self.argument(0) ?? "[]"
        }
        define("__capture_result", capture, in: context)

        let fetch: @convention(block) () -> String = {
            let args = Self.arguments()
            let followRedirects = args.count > 4 && !args[4].isUndefined ? args[4].toBool() : true
            return PluginNetworkBridge.fetch(
                url: Self.argument(0) ?? "",
                method: Self.argument(1) ?? "GET",
                headersJSON: Self.argument(2) ?? "{}",
                body: Self.argument(3) ?? "",
                followRedirects: followRedirects
            )
        }
        define("__native_fetch", fetch, in: context)

        let parseURL: @convention(block) () -> String = {
            PluginNetworkBridge.parseURL(Self.argument(0) ?? "")
        }
        define("__parse_url", parseURL, in: context)

        installCrypto(in: context)
        dom.install(in: context, define: { name, block in self.define(name, block, in: context) })
    }

    private func installCrypto(in context: JSContext) {
        let randomHex: @convention(block) () -> String = {
            let length = Int(Self.arguments().first?.toInt32() ?? 0)
            return PluginCryptoBridge.hex(PluginCryptoBridge.randomBytes(max(0, length)))
        }
        define("__crypto_get_random_values_hex", randomHex, in: context)

        let digestRaw: @convention(block) () -> String = {
            let data = PluginCryptoBridge.bytes(fromHex: Self.argument(1) ?? "")
            return PluginCryptoBridge.hex(PluginCryptoBridge.digest(Self.argument(0) ?? "SHA256", data))
        }
        define("__crypto_digest_hex_raw", digestRaw, in: context)

        let hmacRaw: @convention(block) () -> String = {
            let key = PluginCryptoBridge.bytes(fromHex: Self.argument(1) ?? "")
            let data = PluginCryptoBridge.bytes(fromHex: Self.argument(2) ?? "")
            return PluginCryptoBridge.hex(PluginCryptoBridge.hmac(Self.argument(0) ?? "SHA256", key: key, data: data))
        }
        define("__crypto_hmac_hex_raw", hmacRaw, in: context)

        let pbkdf2: @convention(block) () -> String = {
            let args = Self.arguments()
            let password = PluginCryptoBridge.bytes(fromHex: Self.argument(0) ?? "")
            let salt = PluginCryptoBridge.bytes(fromHex: Self.argument(1) ?? "")
            let iterations = args.count > 2 && !args[2].isUndefined ? Int(args[2].toInt32()) : 1000
            let keyBits = args.count > 3 && !args[3].isUndefined ? Int(args[3].toInt32()) : 256
            return PluginCryptoBridge.hex(PluginCryptoBridge.pbkdf2(
                password: password, salt: salt, iterations: iterations,
                keySizeBits: keyBits, algorithm: Self.argument(4) ?? "SHA256"
            ))
        }
        define("__crypto_pbkdf2_hex", pbkdf2, in: context)

        for encrypt in [true, false] {
            let aes: @convention(block) () -> String = {
                let key = PluginCryptoBridge.bytes(fromHex: Self.argument(1) ?? "")
                let iv = PluginCryptoBridge.bytes(fromHex: Self.argument(2) ?? "")
                let data = PluginCryptoBridge.bytes(fromHex: Self.argument(3) ?? "")
                let output = PluginCryptoBridge.aes(
                    encrypt: encrypt, mode: Self.argument(0) ?? "AES-CBC", key: key, iv: iv, data: data
                )
                return PluginCryptoBridge.hex(output)
            }
            define(encrypt ? "__crypto_aes_encrypt_hex" : "__crypto_aes_decrypt_hex", aes, in: context)
        }

        // Signatures are not available on tvOS; scripts get a JS error instead.
        let sign: @convention(block) () -> String = { "" }
        define("__crypto_sign_hex", sign, in: context)
        let verify: @convention(block) () -> Bool = { false }
        define("__crypto_verify_hex", verify, in: context)

        let digestText: @convention(block) () -> String = {
            PluginCryptoBridge.hex(PluginCryptoBridge.digest(Self.argument(0) ?? "SHA256", Data((Self.argument(1) ?? "").utf8)))
        }
        define("__crypto_digest_hex", digestText, in: context)

        let hmacText: @convention(block) () -> String = {
            PluginCryptoBridge.hex(PluginCryptoBridge.hmac(
                Self.argument(0) ?? "SHA256",
                key: Data((Self.argument(1) ?? "").utf8),
                data: Data((Self.argument(2) ?? "").utf8)
            ))
        }
        define("__crypto_hmac_hex", hmacText, in: context)

        let base64Encode: @convention(block) () -> String = {
            Data((Self.argument(0) ?? "").utf8).base64EncodedString()
        }
        define("__crypto_base64_encode", base64Encode, in: context)

        let base64Decode: @convention(block) () -> String = {
            guard let data = PluginCryptoBridge.base64Data(Self.argument(0) ?? "") else { return "" }
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        define("__crypto_base64_decode", base64Decode, in: context)

        let utf8ToHex: @convention(block) () -> String = {
            PluginCryptoBridge.hex(Data((Self.argument(0) ?? "").utf8))
        }
        define("__crypto_utf8_to_hex", utf8ToHex, in: context)

        let hexToUtf8: @convention(block) () -> String = {
            let data = PluginCryptoBridge.bytes(fromHex: Self.argument(0) ?? "")
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        define("__crypto_hex_to_utf8", hexToUtf8, in: context)
    }

    private func define(_ name: String, _ block: Any, in context: JSContext) {
        context.setObject(block, forKeyedSubscript: name as NSString)
    }

    // MARK: Helpers

    static func arguments() -> [JSValue] {
        (JSContext.currentArguments() as? [JSValue]) ?? []
    }

    /// String argument, `nil` for missing / undefined / null.
    static func argument(_ index: Int) -> String? {
        let args = arguments()
        guard index < args.count else { return nil }
        let value = args[index]
        if value.isUndefined || value.isNull { return nil }
        return value.toString()
    }

    static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    /// JavaScriptCore has no timers; scripts' setTimeout/setInterval are kept
    /// in JS and driven by the host loop through `__runTimers()`.
    static let timerPrelude = """
        var __timers = [];
        var __timerSeq = 0;
        globalThis.setTimeout = function(fn, ms) {
            var args = Array.prototype.slice.call(arguments, 2);
            var id = ++__timerSeq;
            __timers.push({ id: id, fn: fn, args: args, at: Date.now() + (Number(ms) || 0) });
            return id;
        };
        globalThis.setInterval = function(fn, ms) {
            var args = Array.prototype.slice.call(arguments, 2);
            var id = ++__timerSeq;
            var every = Math.max(Number(ms) || 0, 10);
            __timers.push({ id: id, fn: fn, args: args, at: Date.now() + every, every: every });
            return id;
        };
        globalThis.clearTimeout = globalThis.clearInterval = function(id) {
            __timers = __timers.filter(function(t) { return t.id !== id; });
        };
        globalThis.queueMicrotask = function(fn) { Promise.resolve().then(fn); };
        globalThis.__runTimers = function() {
            var now = Date.now();
            var due = __timers.filter(function(t) { return t.at <= now; });
            __timers = __timers.filter(function(t) { return t.at > now; });
            due.forEach(function(t) {
                try { if (typeof t.fn === 'function') t.fn.apply(null, t.args); } catch (e) { console.error('timer error', e); }
                if (t.every) { t.at = Date.now() + t.every; __timers.push(t); }
            });
            if (!__timers.length) return -1;
            var next = Math.min.apply(null, __timers.map(function(t) { return t.at; }));
            return Math.max(0, next - Date.now());
        };
        """
}
