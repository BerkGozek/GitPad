import GitPadCore
import SwiftUI

struct CloneView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var progress: TransferProgress?
    @State private var errorMessage: String?
    @State private var cloneTask: Task<Void, Never>?
    @State private var accountID: UUID?
    @State private var showingAddAccount = false

    private var isCloning: Bool { cloneTask != nil }

    private var host: String? { AccountStore.host(of: urlText) }

    private var matchingAccounts: [Account] {
        guard let host else { return [] }
        return app.accounts.filter { $0.host == host }
    }

    private var canClone: Bool {
        !isCloning && URL(string: urlText.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/owner/repository.git", text: $urlText)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: urlText) { _, new in
                            if !nameEdited { name = app.store.suggestedName(for: new) }
                            // Pick the account automatically when exactly one matches the host.
                            if !matchingAccounts.contains(where: { $0.id == accountID }) {
                                accountID = matchingAccounts.count == 1 ? matchingAccounts[0].id : nil
                            }
                        }
                } header: {
                    Text("Repository URL")
                } footer: {
                    Text("HTTPS URLs from GitHub, GitLab, Bitbucket or any Git server.")
                }

                Section {
                    AccountPicker(accounts: matchingAccounts, selection: $accountID)
                    Button("Add Account…", systemImage: "plus") { showingAddAccount = true }
                } header: {
                    Text("Account")
                } footer: {
                    Text(matchingAccounts.isEmpty
                         ? "Public repositories need no account. For private ones, add an account for \(host ?? "the host") first."
                         : "Used for private repositories, and later for pushing.")
                }

                Section("Folder Name") {
                    // Only edits made in this field stop the name following the URL. (Using
                    // onChange(of: name) also caught our own updates, so typing a URL froze
                    // the name at its first character.)
                    TextField("Name", text: Binding(
                        get: { name },
                        set: { name = $0; nameEdited = !$0.isEmpty }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("clone-name")
                }

                if isCloning {
                    Section("Progress") {
                        if let progress, progress.total > 0 {
                            ProgressView(value: progress.fraction) {
                                Text(label(for: progress))
                            }
                        } else {
                            ProgressView("Connecting…")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Clone Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isCloning ? "Stop" : "Cancel", role: .cancel) {
                        if let cloneTask { cloneTask.cancel() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone", action: startClone)
                        .disabled(!canClone)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .interactiveDismissDisabled(isCloning)
            .sheet(isPresented: $showingAddAccount) {
                AddAccountView(suggestedHost: host)
            }
            .onChange(of: app.accounts) { _, _ in
                if accountID == nil, matchingAccounts.count == 1 { accountID = matchingAccounts[0].id }
            }
        }
    }

    private func label(for progress: TransferProgress) -> String {
        let counts = "\(progress.completed) of \(progress.total)"
        switch progress.phase {
        case .receiving:
            return "Receiving objects: \(counts) (\(ByteCountFormatter.string(fromByteCount: Int64(progress.bytes), countStyle: .file)))"
        case .resolving: return "Resolving deltas: \(counts)"
        case .checkingOut: return "Writing files: \(counts)"
        case .uploading: return "Uploading: \(counts)"
        case .done: return "Done"
        }
    }

    private func startClone() {
        errorMessage = nil
        progress = nil
        let url = urlText
        let folder = name
        let store = app.store
        let account = app.accounts.first { $0.id == accountID }
        let credentials = account.map { app.accountStore.credentialProvider(for: $0) }
        cloneTask = Task {
            do {
                let repository = try await store.clone(from: url, name: folder, credentials: credentials, progress: { value in
                    Task { @MainActor in progress = value }
                })
                if let account {
                    try? app.accountStore.assign(account.id, toRepository: repository.name)
                }
                app.didClone(repository)
                dismiss()
            } catch is CancellationError {
                errorMessage = "Clone stopped. Nothing was saved."
            } catch GitError.cancelled {
                errorMessage = "Clone stopped. Nothing was saved."
            } catch GitError.authenticationFailed {
                errorMessage = account == nil
                    ? "This repository is private or doesn't exist. Choose or add an account for \(host ?? "this host")."
                    : "The server rejected the account's token. Check that it hasn't expired and can read this repository."
            } catch {
                errorMessage = Redactor.redact(error.localizedDescription)
            }
            cloneTask = nil
        }
    }
}
