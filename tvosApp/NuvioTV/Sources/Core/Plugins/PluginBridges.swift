//
//  PluginBridges.swift
//  NuvioTV
//
//  Native halves of the plugin polyfills: the JS side lives in
//  Resources/Plugins/PluginPolyfills.js and calls these through `__*`
//  functions. Binary data crosses the bridge as hex, as on Android.
//

import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import SwiftSoup

// MARK: - Network

enum PluginNetworkBridge {
    private static let maxHeaderValueChars = 8 * 1024
    private static let requestTimeout: TimeInterval = 20
    private static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let followingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }()

    private static let manualRedirectSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    /// Synchronous on purpose: the plugin thread blocks while the request runs.
    static func fetch(url: String, method: String, headersJSON: String, body: String, followRedirects: Bool) -> String {
        guard let requestURL = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            return failure(url: url, message: "Invalid URL")
        }
        var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = method.uppercased()
        var headers = parseHeaders(headersJSON)
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers["User-Agent"] = defaultUserAgent
        }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if !body.isEmpty, request.httpMethod != "GET", request.httpMethod != "HEAD" {
            request.httpBody = Data(body.utf8)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        let session = followRedirects ? followingSession : manualRedirectSession
        let task = session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + requestTimeout + 5) == .timedOut {
            task.cancel()
            return failure(url: url, message: "Timed out")
        }

        guard let http = resultResponse as? HTTPURLResponse else {
            return failure(url: url, message: resultError?.localizedDescription ?? "Fetch failed")
        }
        var responseHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = (key as? String)?.lowercased() else { continue }
            var text = "\(value)"
            if text.count > maxHeaderValueChars { text = String(text.prefix(maxHeaderValueChars)) + "\n...[truncated]" }
            responseHeaders[name] = text
        }
        let data = resultData ?? Data()
        let bodyText = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        let payload: [String: Any] = [
            "ok": (200..<300).contains(http.statusCode),
            "status": http.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            "url": http.url?.absoluteString ?? url,
            "body": bodyText,
            "headers": responseHeaders,
        ]
        return json(payload)
    }

    static func parseURL(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString), let scheme = components.scheme else {
            return json([
                "protocol": "", "host": "", "hostname": "", "port": "",
                "pathname": "/", "search": "", "hash": "",
            ])
        }
        let hostname = components.host ?? ""
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let port = components.port.flatMap { $0 == defaultPort ? nil : String($0) } ?? ""
        let path = components.percentEncodedPath
        return json([
            "protocol": "\(scheme):",
            "host": port.isEmpty ? hostname : "\(hostname):\(port)",
            "hostname": hostname,
            "port": port,
            "pathname": path.isEmpty ? "/" : path,
            "search": components.percentEncodedQuery.map { "?\($0)" } ?? "",
            "hash": components.percentEncodedFragment.map { "#\($0)" } ?? "",
        ])
    }

    private static func parseHeaders(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object.compactMapValues { value in
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
    }

    private static func failure(url: String, message: String) -> String {
        json(["ok": false, "status": 0, "statusText": message, "url": url, "body": "", "headers": [String: String]()])
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - Crypto

enum PluginCryptoBridge {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(fromHex hex: String) -> Data {
        var cleaned = hex.filter(\.isHexDigit)
        if cleaned.count % 2 == 1 { cleaned = "0" + cleaned }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            data.append(UInt8(cleaned[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    static func base64Data(_ text: String) -> Data? {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized += "=" }
        return Data(base64Encoded: normalized)
    }

    static func randomBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private static func normalized(_ algorithm: String) -> String {
        algorithm.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func digest(_ algorithm: String, _ data: Data) -> Data {
        switch normalized(algorithm) {
        case "MD5": return Data(Insecure.MD5.hash(data: data))
        case "SHA1": return Data(Insecure.SHA1.hash(data: data))
        case "SHA384": return Data(SHA384.hash(data: data))
        case "SHA512": return Data(SHA512.hash(data: data))
        default: return Data(SHA256.hash(data: data))
        }
    }

    static func hmac(_ algorithm: String, key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        switch normalized(algorithm) {
        case "MD5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: symmetricKey))
        case "SHA1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetricKey))
        case "SHA384": return Data(HMAC<SHA384>.authenticationCode(for: data, using: symmetricKey))
        case "SHA512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: symmetricKey))
        default: return Data(HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey))
        }
    }

    static func pbkdf2(password: Data, salt: Data, iterations: Int, keySizeBits: Int, algorithm: String) -> Data {
        let prf: CCPseudoRandomAlgorithm
        switch normalized(algorithm) {
        case "SHA1": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case "SHA384": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case "SHA512": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        default: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        }
        let length = max(1, keySizeBits / 8)
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        prf, UInt32(max(1, iterations)),
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress, length
                    )
                }
            }
        }
        return status == Int32(kCCSuccess) ? derived : Data()
    }

    /// `mode` is AES-CBC, AES-ECB or AES-GCM, optionally suffixed -NoPadding.
    static func aes(encrypt: Bool, mode: String, key: Data, iv: Data, data: Data) -> Data {
        let upper = mode.uppercased()
        if upper.contains("GCM") {
            return aesGCM(encrypt: encrypt, key: key, iv: iv, data: data)
        }
        let isECB = upper.contains("ECB")
        let noPadding = upper.contains("NOPADDING")
        var options = CCOptions(0)
        if !noPadding { options |= CCOptions(kCCOptionPKCS7Padding) }
        if isECB { options |= CCOptions(kCCOptionECBMode) }

        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let ivBytes = iv.count >= kCCBlockSizeAES128 ? iv.prefix(kCCBlockSizeAES128) : Data(count: kCCBlockSizeAES128)
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    ivBytes.withUnsafeBytes { ivPointer in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBytes.baseAddress, key.count,
                            isECB ? nil : ivPointer.baseAddress,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return Data() }
        return output.prefix(moved)
    }

    /// WebCrypto layout: ciphertext followed by the 16-byte tag.
    private static func aesGCM(encrypt: Bool, key: Data, iv: Data, data: Data) -> Data {
        guard let nonce = try? AES.GCM.Nonce(data: iv) else { return Data() }
        let symmetricKey = SymmetricKey(data: key)
        if encrypt {
            guard let sealed = try? AES.GCM.seal(data, using: symmetricKey, nonce: nonce) else { return Data() }
            return sealed.ciphertext + sealed.tag
        }
        guard data.count >= 16,
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16)),
              let opened = try? AES.GCM.open(box, using: symmetricKey) else { return Data() }
        return opened
    }
}

// MARK: - DOM (cheerio subset)

/// Element handles for the cheerio polyfill, backed by SwiftSoup.
final class PluginDomBridge {
    private var documents: [String: SwiftSoup.Document] = [:]
    private var elements: [String: SwiftSoup.Element] = [:]
    private var counter = 0
    private let containsRegex = try? NSRegularExpression(pattern: #":contains\(["']([^"']+)["']\)"#)

    func install(in context: JSContext, define: (String, Any) -> Void) {
        let load: @convention(block) () -> String = { [weak self] in
            guard let self else { return "" }
            let html = Self.argument(0) ?? ""
            self.counter += 1
            let id = "doc_\(self.counter)_\(Int.random(in: 0..<Int(Int32.max)))"
            self.documents[id] = (try? SwiftSoup.parse(html)) ?? SwiftSoup.Document("")
            return id
        }
        define("__cheerio_load", load)

        let select: @convention(block) () -> String = { [weak self] in
            guard let self, let doc = self.documents[Self.argument(0) ?? ""] else { return "[]" }
            let docId = Self.argument(0) ?? ""
            let selector = self.normalizedSelector(Self.argument(1) ?? "")
            guard !selector.isEmpty, let found = try? doc.select(selector) else { return "[]" }
            return self.register(found.array(), prefix: docId)
        }
        define("__cheerio_select", select)

        let find: @convention(block) () -> String = { [weak self] in
            guard let self, let element = self.elements[Self.argument(1) ?? ""] else { return "[]" }
            let selector = self.normalizedSelector(Self.argument(2) ?? "")
            guard !selector.isEmpty, let found = try? element.select(selector) else { return "[]" }
            return self.register(found.array(), prefix: "\(Self.argument(0) ?? ""):find")
        }
        define("__cheerio_find", find)

        let text: @convention(block) () -> String = { [weak self] in
            guard let self else { return "" }
            return (Self.argument(1) ?? "")
                .split(separator: ",")
                .compactMap { self.elements[String($0)] }
                .compactMap { try? $0.text() }
                .joined(separator: " ")
        }
        define("__cheerio_text", text)

        let html: @convention(block) () -> String = { [weak self] in
            guard let self else { return "" }
            let elementId = Self.argument(1) ?? ""
            if elementId.isEmpty {
                return (try? self.documents[Self.argument(0) ?? ""]?.html()) ?? ""
            }
            return (try? self.elements[elementId]?.html()) ?? ""
        }
        define("__cheerio_html", html)

        let innerHTML: @convention(block) () -> String = { [weak self] in
            (try? self?.elements[Self.argument(1) ?? ""]?.html()) ?? ""
        }
        define("__cheerio_inner_html", innerHTML)

        let attr: @convention(block) () -> String = { [weak self] in
            guard let element = self?.elements[Self.argument(1) ?? ""] else { return "__UNDEFINED__" }
            let name = Self.argument(2) ?? ""
            guard element.hasAttr(name), let value = try? element.attr(name), !value.isEmpty else { return "__UNDEFINED__" }
            return value
        }
        define("__cheerio_attr", attr)

        let next: @convention(block) () -> String = { [weak self] in
            guard let self, let element = self.elements[Self.argument(1) ?? ""],
                  let sibling = try? element.nextElementSibling() else { return "__NONE__" }
            return self.register(sibling, id: "\(Self.argument(0) ?? ""):next:\(ObjectIdentifier(sibling).hashValue)")
        }
        define("__cheerio_next", next)

        let prev: @convention(block) () -> String = { [weak self] in
            guard let self, let element = self.elements[Self.argument(1) ?? ""],
                  let sibling = try? element.previousElementSibling() else { return "__NONE__" }
            return self.register(sibling, id: "\(Self.argument(0) ?? ""):prev:\(ObjectIdentifier(sibling).hashValue)")
        }
        define("__cheerio_prev", prev)
    }

    func clear() {
        documents.removeAll()
        elements.removeAll()
    }

    private func normalizedSelector(_ selector: String) -> String {
        guard let containsRegex else { return selector }
        let range = NSRange(selector.startIndex..., in: selector)
        return containsRegex.stringByReplacingMatches(in: selector, range: range, withTemplate: ":contains($1)")
    }

    private func register(_ found: [SwiftSoup.Element], prefix: String) -> String {
        let ids = found.enumerated().map { index, element in
            register(element, id: "\(prefix):\(index):\(ObjectIdentifier(element).hashValue)")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ids),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    @discardableResult
    private func register(_ element: SwiftSoup.Element, id: String) -> String {
        elements[id] = element
        return id
    }

    private static func argument(_ index: Int) -> String? {
        let args = (JSContext.currentArguments() as? [JSValue]) ?? []
        guard index < args.count, !args[index].isUndefined, !args[index].isNull else { return nil }
        return args[index].toString()
    }
}
