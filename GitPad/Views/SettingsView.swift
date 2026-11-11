import GitPadCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppModel.self) private var app
    @AppStorage(CommitIdentity.nameKey) private var name = ""
    @AppStorage(CommitIdentity.emailKey) private var email = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Commit Author")
                } footer: {
                    Text("Used as the author of commits you make on this iPad. Use the email your Git host knows, so commits link to your account.")
                }

                Section {
                    LabeledContent("Location", value: "On My iPad › GitPad › Repositories")
                    if let url = app.store.repositoriesURL.filesAppURL {
                        Button("Open in Files", systemImage: "folder") { openURL(url) }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Repositories are stored in the app's folder. Deleting GitPad from this iPad deletes them too, including anything not pushed.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("libgit2", value: libgit2Version())
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
