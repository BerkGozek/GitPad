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

    private var isCloning: Bool { cloneTask != nil }

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
                        }
                } header: {
                    Text("Repository URL")
                } footer: {
                    Text("HTTPS URLs from GitHub, GitLab, Bitbucket or any Git server. Private repositories need an account, which comes in the next update.")
                }

                Section("Folder Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: name) { _, _ in nameEdited = true }
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
        cloneTask = Task {
            do {
                let repository = try await store.clone(from: url, name: folder, progress: { value in
                    Task { @MainActor in progress = value }
                })
                app.didClone(repository)
                dismiss()
            } catch is CancellationError {
                errorMessage = "Clone stopped. Nothing was saved."
            } catch GitError.cancelled {
                errorMessage = "Clone stopped. Nothing was saved."
            } catch {
                errorMessage = Redactor.redact(error.localizedDescription)
            }
            cloneTask = nil
        }
    }
}
