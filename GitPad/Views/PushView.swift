import GitPadCore
import SwiftUI

/// Shows what a push will send, and with which account, before pushing.
struct PushView: View {
    @Bindable var model: RepositoryModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddAccount = false
    @State private var accountID: UUID?

    private var branch: String { model.head?.branch ?? "?" }
    private var destination: String {
        model.currentBranch?.upstream ?? "\(model.primaryRemote?.name ?? "origin")/\(branch) (new branch on the remote)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Branch", value: branch)
                    LabeledContent("To", value: destination)
                    if let url = model.primaryRemote?.url {
                        LabeledContent("Remote", value: url)
                    }
                }

                Section {
                    if model.candidateAccounts.isEmpty {
                        Label("No account for \(model.remoteHost ?? "this server").", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    } else {
                        AccountPicker(accounts: model.candidateAccounts, selection: $accountID, noneLabel: "Choose…")
                            .onChange(of: accountID) { _, new in model.selectedAccountID = new }
                    }
                    Button("Add Account…", systemImage: "plus") { showingAddAccount = true }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Pushing always needs an account, even for public repositories.")
                }

                Section("Commits to Push (\(model.outgoing.count))") {
                    if model.outgoing.isEmpty {
                        Text("Nothing to push. Commit changes first.").foregroundStyle(.secondary)
                    }
                    ForEach(model.outgoing) { commit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.summary)
                            Text("\(commit.shortID) · \(commit.authorName)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !model.changes.isEmpty {
                    Section {
                        Label("\(model.changes.count) uncommitted change(s) won't be pushed.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Push")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Push") {
                        model.push()
                        dismiss()
                    }
                    .disabled(model.outgoing.isEmpty || accountID == nil || model.isBusy)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .sheet(isPresented: $showingAddAccount) {
                AddAccountView(suggestedHost: model.remoteHost)
            }
            .onAppear { accountID = model.selectedAccountID }
            .onChange(of: app.accounts) { _, _ in
                // A freshly added account for this host becomes the choice automatically.
                if accountID == nil { accountID = model.selectedAccountID ?? model.candidateAccounts.first?.id }
                model.selectedAccountID = accountID
            }
        }
    }
}
