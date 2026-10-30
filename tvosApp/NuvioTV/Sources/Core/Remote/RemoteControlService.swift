import Combine
import CryptoKit
import Foundation
import Network
import UIKit

/// Lets the WatchParty iPad app control this Apple TV over the local network.
///
/// The TV advertises `_watchparty._tcp` as "<name> #<id>". `<id>` is derived from the secret of
/// the signed-in account (server section `remote.key`), so the iPad only lists TVs of its own
/// account. Every command carries an HMAC over a per-connection nonce and a counter: without the
/// secret nothing can be sent, and nothing can be replayed. No data is exchanged, only commands
/// and the playback state.
@MainActor
final class RemoteControlService {
    static let shared = RemoteControlService()
    static let serviceType = "_watchparty._tcp"

    /// Set by `PlayerView` while a player is on screen.
    weak var player: PlayerViewModel?
    /// Set by the app shell; starts a Live TV channel exactly like picking it in the Live TV tab.
    var playLiveChannel: ((LiveTVChannel) -> Void)?

    @MainActor
    private final class Client {
        let connection: NWConnection
        let nonce: String = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        var authenticated = false
        var lastCounter = 0
        var buffer = Data()

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private var clients: [ObjectIdentifier: Client] = [:]
    private var listener: NWListener?
    private var key: SymmetricKey?
    private var stateTimer: Timer?
    private var accountObserver: AnyCancellable?
    private var starting = false

    /// Starts and stops the service together with the account session.
    func observeAccount() {
        guard accountObserver == nil else { return }
        accountObserver = WatchPartyAccount.shared.$session.sink { [weak self] session in
            Task { @MainActor in
                if session != nil { await self?.startIfNeeded() } else { self?.stop() }
            }
        }
    }

    private func startIfNeeded() async {
        guard listener == nil, !starting else { return }
        starting = true
        defer { starting = false }
        guard let secret = await WatchPartyAccount.shared.remoteKey() else { return }
        key = SymmetricKey(data: Data(secret.utf8))
        let identifier = Self.accountIdentifier(secret)
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: "\(String(UIDevice.current.name.prefix(30))) #\(identifier)", type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed = state else { return }
                Task { @MainActor in
                    self?.stop()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    await self?.startIfNeeded()
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            return
        }
        stateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushState() }
        }
    }

    private func stop() {
        stateTimer?.invalidate()
        stateTimer = nil
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.connection.cancel() }
        clients.removeAll()
        key = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard clients.count < 4 else {
            connection.cancel()
            return
        }
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let client else { return }
            switch state {
            case .ready:
                Task { @MainActor in
                    self?.send(["hello": "watchparty", "name": UIDevice.current.name, "nonce": client.nonce], to: client)
                    self?.receive(client)
                }
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(client) }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func drop(_ client: Client) {
        clients[ObjectIdentifier(client)] = nil
        client.connection.cancel()
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak client] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                if let data { client.buffer.append(data) }
                self.drain(client)
                if isComplete || error != nil {
                    self.drop(client)
                } else if self.clients[ObjectIdentifier(client)] != nil {
                    self.receive(client)
                }
            }
        }
    }

    private func drain(_ client: Client) {
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = Data(client.buffer[client.buffer.startIndex..<newline])
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            handle(line, from: client)
            if clients[ObjectIdentifier(client)] == nil { return }
        }
        if client.buffer.count > 65_536 { drop(client) }
    }

    // MARK: - Commands

    private func handle(_ line: Data, from client: Client) {
        guard let key,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let counter = object["c"] as? Int,
              let body = object["body"] as? String,
              let mac = object["mac"] as? String,
              counter > client.lastCounter,
              let macData = Self.hexData(mac),
              HMAC<SHA256>.isValidAuthenticationCode(
                macData,
                authenticating: Data("\(client.nonce)|\(counter)|\(body)".utf8),
                using: key
              ) else {
            drop(client)
            return
        }
        client.lastCounter = counter
        client.authenticated = true

        guard let command = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = command["cmd"] as? String else {
            send(["re": counter, "ok": false], to: client)
            return
        }
        let ok = perform(name, command)
        send(["re": counter, "ok": ok, "state": stateSnapshot()], to: client)
    }

    private func perform(_ name: String, _ command: [String: Any]) -> Bool {
        switch name {
        case "state":
            return true
        case "toggle":
            guard let player else { return false }
            player.togglePlayPause()
            return true
        case "play":
            guard let player else { return false }
            player.play()
            return true
        case "pause":
            guard let player else { return false }
            player.pause()
            return true
        case "seekBy":
            guard let player, !player.isLiveStream, let delta = Self.number(command["s"]) else { return false }
            player.seek(to: max(0, player.time.current + delta))
            return true
        case "seekTo":
            guard let player, !player.isLiveStream, let seconds = Self.number(command["s"]) else { return false }
            player.seek(to: max(0, seconds))
            return true
        case "playLive":
            guard let playLiveChannel,
                  let name = command["name"] as? String, !name.isEmpty,
                  let urlString = command["url"] as? String,
                  let url = URL(string: urlString),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
            let channel = LiveTVChannel(
                id: "iptv:remote-" + Self.accountIdentifier(urlString),
                name: name,
                group: (command["group"] as? String) ?? "",
                logoURL: command["logo"] as? String,
                streamURL: urlString,
                playlistURL: "remote"
            )
            playLiveChannel(channel)
            return true
        default:
            return false
        }
    }

    // MARK: - State

    private func stateSnapshot() -> [String: Any] {
        guard let player else { return ["hasPlayer": false] }
        let status: String
        switch player.status {
        case .playing: status = "playing"
        case .paused: status = "paused"
        case .buffering: status = "buffering"
        case .ended: status = "ended"
        case .idle: status = "idle"
        case .error: status = "error"
        }
        return [
            "hasPlayer": true,
            "title": player.title,
            "subtitle": player.subtitle,
            "position": Self.finite(player.time.current),
            "duration": Self.finite(player.time.duration),
            "live": player.isLiveStream,
            "status": status,
        ]
    }

    private func pushState() {
        guard !clients.isEmpty else { return }
        let snapshot = ["state": stateSnapshot()]
        for client in clients.values where client.authenticated {
            send(snapshot, to: client)
        }
    }

    private func send(_ object: [String: Any], to client: Client) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        client.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Helpers

    private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double.isFinite ? double : nil }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    nonisolated static func accountIdentifier(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(("watchparty-remote|" + text).utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func hexData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
