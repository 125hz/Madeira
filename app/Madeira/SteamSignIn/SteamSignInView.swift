// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import CoreImage

@MainActor
private final class SteamSignInModel: ObservableObject {
    let flow = SteamSignInFlow()
    init() {
        flow.onChange = { [weak self] in self?.objectWillChange.send() }
    }
}

@MainActor
struct SteamSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SteamSignInModel()
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    @State private var codeType: SteamSignInGuard = .deviceCode

    private var flow: SteamSignInFlow { model.flow }
    private var codeMethods: [SteamSignInGuard] {
        flow.methods.filter { $0 == .emailCode || $0 == .deviceCode }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch flow.state {
                case .signedIn(let name):
                    Section("Signed in to Steam") {
                        Text(name).privacySensitive()
                        Button("Sign out", role: .destructive) { clearFields(); flow.signOut() }
                    }
                case .starting:
                    Section { ProgressView("Contacting Steam…"); cancelButton }
                case .waiting:
                    waitingSection
                case .signedOut:
                    credentialsSection
                case .failed(let error):
                    Section {
                        Text(error.errorDescription ?? "Sign-in failed.")
                            .accessibilityLabel(error.errorDescription ?? "Sign-in failed.")
                        if error == .storage || error == .invalidStoredCredentials {
                            Button("Retry Keychain") { flow.reload() }
                            Button("Remove saved sign-in", role: .destructive) { flow.signOut() }
                        }
                    }
                    credentialsSection
                }
                Section {
                    Text("Your account name and Steam refresh token are stored only in this device’s Keychain. Your password and Steam Guard codes are not saved.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Steam sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { clearFields(); flow.cancel(); dismiss() }
                }
            }
        }
        .onDisappear { clearFields(); flow.cancel() }
        .onChange(of: flow.state) { _, state in
            if state == .waiting { codeType = codeMethods.first ?? .deviceCode }
            if case .signedIn = state { clearFields() }
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Steam account name", text: $account)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
            SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .onSubmit { signIn() }
            Button("Sign in") { signIn() }
                .disabled(account.isEmpty || password.isEmpty || !SteamSignIn.isEnabled)
            Button("Sign in with QR") { clearFields(); flow.startQR() }
                .disabled(!SteamSignIn.isEnabled)
        }
    }

    private var waitingSection: some View {
        Section {
            if let url = flow.qrURL {
                if let qr = qrImage(url) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding(12)
                        .background(.white)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Steam sign-in QR code")
                        .privacySensitive()
                }
                Text("Scan this QR code with the Steam mobile app on another device and approve the sign-in. On this device, use account name and password instead.")
            } else if flow.methods.contains(.deviceConfirmation) {
                Text("Open the Steam mobile app and approve the Madeira sign-in, then return here.")
            } else if flow.methods.contains(.emailConfirmation) {
                Text("Approve the sign-in using the message sent by Steam, then return here.")
            }
            if !codeMethods.isEmpty {
                if codeMethods.count > 1 {
                    Picker("Code from", selection: $codeType) {
                        ForEach(codeMethods, id: \.rawValue) { method in
                            Text(method == .emailCode ? "Email" : "Steam app").tag(method)
                        }
                    }
                }
                Text(codeType == .emailCode ? "Enter the Steam Guard code sent to your email." : "Enter the Steam Guard code from the Steam mobile app.")
                SecureField("Steam Guard code", text: $code)
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit { submitCode() }
                Button("Submit code") { submitCode() }
                    .disabled(code.isEmpty || flow.submittingCode)
                if let error = flow.codeError { Text(error.errorDescription ?? "Check the code and try again.") }
            }
            ProgressView(flow.submittingCode ? "Checking code…" : "Waiting for Steam…")
            cancelButton
        }
    }

    private var cancelButton: some View {
        Button("Cancel sign-in", role: .cancel) { clearFields(); flow.cancel() }
    }

    private func signIn() {
        guard !account.isEmpty, !password.isEmpty else { return }
        flow.start(account: account, password: password)
        clearFields()
    }

    private func submitCode() {
        flow.submit(code: code, type: codeType)
        code = ""
    }

    private func clearFields() { account = ""; password = ""; code = "" }

    private func qrImage(_ value: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
