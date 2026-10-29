import SwiftUI

/// Sign-in / registration against the private WatchParty account server (replaces the Nuvio login).
struct WatchPartyLoginPanel: View {
    @ObservedObject private var account = WatchPartyAccount.shared
    /// Called after a successful sign-in on an empty account, or "continue without account".
    let onContinue: () -> Void

    @State private var isRegister = false
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(isRegister ? "Konto erstellen" : "Anmelden")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.white)
            Text("Mit deinem WatchParty-Konto sind Profile, Addons, Sammlungen, Live TV und dein Fortschritt auf allen Geräten gleich.")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                modeButton("Anmelden", selected: !isRegister) { isRegister = false; message = nil }
                modeButton("Konto erstellen", selected: isRegister) { isRegister = true; message = nil }
            }

            TextField("Benutzername", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Passwort", text: $password)
                .textContentType(isRegister ? .newPassword : .password)
            if isRegister {
                TextField("Einladungscode", text: $invite)
                    .autocorrectionDisabled()
            }

            if let message {
                Text(message)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                submit()
            } label: {
                Text(busy ? "Bitte warten …" : (isRegister ? "Konto erstellen" : "Anmelden"))
                    .frame(maxWidth: .infinity)
            }
            .disabled(busy || account.pendingRelaunch)

            Button {
                onContinue()
            } label: {
                Text("Ohne Konto fortfahren").frame(maxWidth: .infinity)
            }

            Text("Deine Daten liegen auf deinem privaten Server und sind durch dein Passwort geschützt.")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(40)
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: selected ? .bold : .regular))
                .foregroundColor(selected ? .white : .white.opacity(0.6))
        }
    }

    private func submit() {
        guard !busy else { return }
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !password.isEmpty else {
            show("Bitte Benutzername und Passwort eingeben.", error: true)
            return
        }
        busy = true
        Task {
            do {
                let outcome = isRegister
                    ? try await account.register(username: name, password: password, invite: invite)
                    : try await account.signIn(username: name, password: password)
                password = ""
                switch outcome {
                case .uploadedLocalData:
                    show("Angemeldet. Die Daten dieses Apple TV sind jetzt in deinem Konto.", error: false)
                    onContinue()
                case .relaunchRequired:
                    show("Konto-Daten geladen. Bitte WatchParty einmal schließen und neu öffnen, damit alles übernommen wird.", error: false)
                }
            } catch {
                show((error as? LocalizedError)?.errorDescription ?? "Fehler", error: true)
            }
            busy = false
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
