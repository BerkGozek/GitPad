import GitPadCore
import SwiftUI

/// Settings → Accounts.
struct AccountsSection: View {
    @Environment(AppModel.self) private var app
    @State private var showingAdd = false
    @State private var pendingRemoval: Account?

    var body: some View {
        Section {
            ForEach(app.accounts) { account in
                HStack {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(account.displayName)
                        Text("\(account.provider.displayName) · \(account.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { pendingRemoval = account }
                }
                .contextMenu {
                    Button("Remove Account…", systemImage: "trash", role: .destructive) { pendingRemoval = account }
                }
            }
            Button("Add Account…", systemImage: "plus") { showingAdd = true }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Tokens are stored only in this iPad's Keychain. They're never written into repository settings or shown again.")
        }
        .sheet(isPresented: $showingAdd) {
            AddAccountView()
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "account")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                if let pendingRemoval { app.removeAccount(pendingRemoval) }
                pendingRemoval = nil
            }
        } message: {
            Text("The token is deleted from this iPad. Repositories stay; private ones can't fetch or push until you add an account again. The token itself stays valid on the server; revoke it there if you no longer need it.")
        }
    }
}

struct AddAccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Pre-selects a host, e.g. when adding an account from the push screen.
    var suggestedHost: String?

    @State private var provider: HostingProvider = .github
    @State private var host = HostingProvider.github.defaultHost
    @State private var username = HostingProvider.github.defaultUsername
    @State private var token = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var allowUnverified = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Service", selection: $provider) {
                        ForEach(HostingProvider.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: provider) { _, new in
                        if suggestedHost == nil || provider != HostingProvider.guess(forHost: suggestedHost ?? "") {
                            host = new.defaultHost
                        }
                        username = new.defaultUsername
                    }
                    TextField("Host (e.g. git.example.com)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section {
                    SecureField("Personal access token", text: $token)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let url = provider.tokenCreationURL(host: host.isEmpty ? provider.defaultHost : host) {
                        Button("Create a Token on \(provider.displayName)…", systemImage: "safari") { openURL(url) }
                    }
                } header: {
                    Text("Token")
                } footer: {
                    Text(tokenHelp)
                }

                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("HTTPS Username")
                } footer: {
                    Text(usernameHelp)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        if allowUnverified {
                            Button("Save Without Checking") { save(displayName: nil) }
                        }
                    }
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isChecking {
                        ProgressView()
                    } else {
                        Button("Add", action: verifyAndSave)
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || host.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if let suggestedHost {
                    host = suggestedHost
                    provider = HostingProvider.guess(forHost: suggestedHost)
                    username = provider.defaultUsername
                }
            }
        }
    }

    private var tokenHelp: String {
        switch provider {
        case .github: "Fine-grained token: pick the repositories, then Repository permissions → Contents: Read and write. Classic tokens need the “repo” scope."
        case .gitlab: "Scopes: read_repository and write_repository."
        case .bitbucket: "Atlassian API token with Bitbucket repository read and write scopes."
        case .other: "A token or password your Git server accepts over HTTPS."
        }
    }

    private var usernameHelp: String {
        switch provider {
        case .github: "Any name works with a GitHub token; the default is fine."
        case .gitlab: "“oauth2” works with personal access tokens."
        case .bitbucket: "Bitbucket API tokens use the fixed username shown here."
        case .other: "Your username on that server."
        }
    }

    private func verifyAndSave() {
        errorMessage = nil
        allowUnverified = false
        isChecking = true
        let provider = provider
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let login = try await TokenValidator.identity(provider: provider, host: host, token: token)
                save(displayName: login)
            } catch let error as AccountError {
                errorMessage = error.localizedDescription
            } catch {
                // Couldn't reach the API (offline, self-hosted without API, …): let the user decide.
                errorMessage = "Couldn't check the token: \(Redactor.redact(error.localizedDescription, secrets: [token]))"
                allowUnverified = true
            }
            isChecking = false
        }
    }

    private func save(displayName: String?) {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        let name = displayName ?? (username.isEmpty || username == provider.defaultUsername ? host : username)
        let account = Account(provider: provider, host: host, username: username.trimmingCharacters(in: .whitespaces), displayName: name)
        do {
            try app.addAccount(account, token: token)
            dismiss()
        } catch {
            errorMessage = Redactor.redact(error.localizedDescription, secrets: [token])
        }
    }
}

/// Picker for the account a repository (or a clone) uses.
struct AccountPicker: View {
    let accounts: [Account]
    @Binding var selection: UUID?
    var noneLabel = "None (public access)"

    var body: some View {
        Picker("Account", selection: $selection) {
            Text(noneLabel).tag(UUID?.none)
            ForEach(accounts) { account in
                Text(account.displayName).tag(Optional(account.id))
            }
        }
    }
}
