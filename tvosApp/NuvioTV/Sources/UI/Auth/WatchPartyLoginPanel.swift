import SwiftUI

/// Sign-in / registration against the private WatchParty account server (replaces the Nuvio login).
/// Two ways in: a code that a signed-in iPad, iPhone or PC approves, or user name and password.
/// The code is preselected when an iPad or iPhone of this household was signed in recently.
struct WatchPartyLoginPanel: View {
    @ObservedObject private var account = WatchPartyAccount.shared
    /// Called after a successful sign-in on an empty account, or "continue without account".
    let onContinue: () -> Void

    private enum Mode { case code, password, register }

    @State private var mode: Mode = .password
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var codeLogin: WatchPartyAccount.CodeLogin?
    @State private var codeTask: Task<Void, Never>?
    @State private var modeChosen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(mode == .register ? "Konto erstellen" : "Anmelden")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.white)
            Text("Mit deinem WatchParty-Konto sind Profile, Addons, Sammlungen, Live TV und dein Fortschritt auf allen Geräten gleich.")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                modeButton("Mit Code", selected: mode == .code) { switchTo(.code) }
                modeButton("Mit Passwort", selected: mode == .password) { switchTo(.password) }
                modeButton("Konto erstellen", selected: mode == .register) { switchTo(.register) }
            }

            if mode == .code {
                codeSection
            } else {
                passwordSection
            }

            if let message {
                Text(message)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        .task { await prepareCode() }
        .onDisappear { codeTask?.cancel() }
    }

    // MARK: - Code

    @ViewBuilder
    private var codeSection: some View {
        if let login = codeLogin {
            HStack(alignment: .center, spacing: 36) {
                if !login.url.isEmpty, let qr = QRCode.image(from: login.url) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text(login.display)
                        .font(.system(size: 64, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("Auf iPad, iPhone oder PC: WatchParty → Einstellungen → Konto → „Fernseher anmelden“ und diesen Code eingeben.")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Oder den QR-Code mit dem Handy scannen und dort mit Benutzername und Passwort bestätigen.")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Wartet auf Bestätigung …")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        } else {
            HStack(spacing: 16) {
                ProgressView()
                Text("Code wird geladen …")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private func prepareCode() async {
        await loadCode()
        guard !modeChosen else { return }
        modeChosen = true
        if codeLogin?.suggestCode == true {
            mode = .code
            startPolling()
        }
    }

    private func loadCode() async {
        do {
            codeLogin = try await account.startCodeLogin()
        } catch {
            if mode == .code { show((error as? LocalizedError)?.errorDescription ?? "Fehler", error: true) }
        }
    }

    private func startPolling() {
        codeTask?.cancel()
        codeTask = Task { @MainActor in
            while !Task.isCancelled, mode == .code {
                if codeLogin == nil || Date() >= (codeLogin?.expiresAt ?? .distantPast) {
                    await loadCode()
                    if codeLogin == nil {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    }
                }
                guard let login = codeLogin else { continue }
                try? await Task.sleep(nanoseconds: UInt64(login.interval * 1_000_000_000))
                if Task.isCancelled || mode != .code { break }
                do {
                    if let outcome = try await account.pollCodeLogin(login) {
                        handle(outcome)
                        break
                    }
                } catch let error as WatchPartyAccount.AccountError where error.code == "code_expired" {
                    codeLogin = nil
                } catch let error as WatchPartyAccount.AccountError where error.code == "sync_sign_in_failed" {
                    show(error.errorDescription ?? "Fehler", error: true)
                    codeLogin = nil
                } catch {
                    // Network hiccup: keep waiting with the same code.
                }
            }
        }
    }

    // MARK: - Password

    @ViewBuilder
    private var passwordSection: some View {
        TextField("Benutzername", text: $username)
            .textContentType(.username)
            .autocorrectionDisabled()
        SecureField("Passwort", text: $password)
            .textContentType(mode == .register ? .newPassword : .password)
        if mode == .register {
            TextField("Einladungscode", text: $invite)
                .autocorrectionDisabled()
        }
        Button {
            submit()
        } label: {
            Text(busy ? "Bitte warten …" : (mode == .register ? "Konto erstellen" : "Anmelden"))
                .frame(maxWidth: .infinity)
        }
        .disabled(busy || account.pendingRelaunch)
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: selected ? .bold : .regular))
                .foregroundColor(selected ? .white : .white.opacity(0.6))
        }
    }

    private func switchTo(_ next: Mode) {
        modeChosen = true
        mode = next
        message = nil
        if next == .code {
            startPolling()
        } else {
            codeTask?.cancel()
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
                let outcome = mode == .register
                    ? try await account.register(username: name, password: password, invite: invite)
                    : try await account.signIn(username: name, password: password)
                password = ""
                handle(outcome)
            } catch {
                show((error as? LocalizedError)?.errorDescription ?? "Fehler", error: true)
            }
            busy = false
        }
    }

    private func handle(_ outcome: WatchPartyAccount.Outcome) {
        codeTask?.cancel()
        switch outcome {
        case .uploadedLocalData:
            show("Angemeldet. Die Daten dieses Apple TV sind jetzt in deinem Konto.", error: false)
            onContinue()
        case .relaunchRequired:
            show("Konto-Daten geladen. Bitte WatchParty einmal schließen und neu öffnen, damit alles übernommen wird.", error: false)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
