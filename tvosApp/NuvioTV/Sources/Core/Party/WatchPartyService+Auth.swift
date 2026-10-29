import Foundation
import Combine

struct WatchPartyProfileIdentity {
    let id: String
    let name: String
    var avatarURL: String? = nil
    var avatarColor: String? = nil
}

extension WatchPartyService {
    /// The root supplies the selected profile and the existing stable installation device ID.
    /// Construct once outside view bodies. Call invalidateContext before every profile/backend switch.
    static func authenticated(authManager: AuthManager, deviceID: String,
                              profile: @escaping @MainActor () -> WatchPartyProfileIdentity?) -> WatchPartyService {
        let provider: WatchPartyAPI.SessionProvider = { [weak authManager] in
            await authManager?.validSessionForSync()
        }
        let service = WatchPartyService(environment: { [weak authManager] in
            guard let authManager, !authManager.sessionNeedsReauthentication,
                  case let .fullAccount(userID, _) = authManager.authState,
                  !userID.isEmpty, !deviceID.isEmpty, let profile = profile(), !profile.id.isEmpty,
                  profile.id == ProfileSettings.activeProfileID else { return nil }
            let configuration = AuthConfig.currentConfiguration
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let avatar = profile.avatarURL.flatMap { raw -> String? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count <= 2048,
                      let url = URL(string: trimmed),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http",
                      url.host != nil else { return nil }
                return trimmed
            }
            let color = profile.avatarColor.flatMap { value in
                value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil ? value : nil
            }
            return WatchPartyEnvironment(configuration: configuration, userID: userID, profileID: profile.id,
                                         identity: WatchPartyIdentity(deviceID: deviceID,
                                                                      displayName: name.isEmpty ? "WatchParty" : String(name.prefix(40)),
                                                                      avatarURL: avatar, avatarColor: color))
        }, makeRemote: { environment, context, validator in
            WatchPartyAPI(configuration: environment.configuration, context: context,
                          sessionProvider: provider, isCurrent: validator)
        }, makeSession: { remote, environment, context, validator in
            WatchPartySession(remote: remote, context: context, deviceID: environment.identity.deviceID,
                              isCurrent: validator, makeChannel: {
                WatchPartyRealtimeChannel(configuration: environment.configuration, context: context,
                                          sessionProvider: provider, isCurrent: validator)
            })
        })
        // AuthManager is @MainActor and publishes synchronously on that actor. Invalidate on the
        // emission itself, including logout→same-account login, rather than queueing a delayed Task.
        service.authObservation = Publishers.CombineLatest(authManager.$authState, authManager.$sessionNeedsReauthentication)
            .map { state, needsReauthentication -> String? in
            guard !needsReauthentication else { return nil }
            if case let .fullAccount(userID, _) = state { return userID }
            return nil
        }.removeDuplicates().dropFirst().sink { [weak service] _ in
            MainActor.assumeIsolated { service?.invalidateContext() }
        }
        return service
    }
}
