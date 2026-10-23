import Foundation

// Android contract: PartyChannel.kt, NuvioMedia/NuvioTV (GPL-3.0), f7e2a78.
enum WatchPartyChannelEvent {
    case message(name: String, payload: Data)
    case presence(joins: [String: WatchPartyPresence], leaves: Set<String>)
    case disconnected
}

enum WatchPartyChannelError: Error { case disconnected, invalidPayload }

/// One instance belongs to one connection attempt. Never reuse it after close.
@MainActor
protocol WatchPartyChannel: AnyObject {
    var isConnected: Bool { get }
    func open(partyID: String, memberID: String,
              receive: @escaping @MainActor (WatchPartyChannelEvent) -> Void) async throws
    func send(event: String, payload: Data) async throws
    func track(_ presence: WatchPartyPresence) async throws
    func refreshAuth() async throws
    /// Synchronously closes admission and clears this client's pending sends.
    func close()
}

enum WatchPartyChannelContract {
    static let events = ["state", "state_request", "status", "control", "member_joined",
                         "member_left", "ended", "media", "stream", "chat"]

    static func realtimeURL(configuration: ServerConfiguration) throws -> URL {
        guard !configuration.publishableKey.isEmpty,
              var c = URLComponents(string: configuration.normalizedBackendURL),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil else { throw WatchPartyAPIError.invalidConfiguration }
        c.scheme = scheme
        c.path += "/realtime/v1"
        c.queryItems = [URLQueryItem(name: "nuvio_realtime", value: "1")]
        guard let url = c.url else { throw WatchPartyAPIError.invalidConfiguration }
        return url // The SDK adds /websocket, apikey, vsn and the realtime: topic prefix.
    }
}
