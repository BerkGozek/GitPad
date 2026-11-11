import GitPadCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showingClone = false
    @State private var showingSettings = false
    @State private var pendingDelete: LocalRepository?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $app.selection) {
                Section("Repositories") {
                    ForEach(app.repositories) { repository in
                        Label(repository.name, systemImage: "folder.badge.gearshape")
                            .tag(repository.id)
                            .contextMenu {
                                if let url = repository.url.filesAppURL {
                                    Button("Show in Files", systemImage: "folder") { openURL(url) }
                                }
                                Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = repository }
                            }
                    }
                }
            }
            .navigationTitle("GitPad")
            .overlay {
                if app.repositories.isEmpty {
                    ContentUnavailableView {
                        Label("No Repositories", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text("Clone a repository to get started.")
                    } actions: {
                        Button("Clone Repository") { showingClone = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clone", systemImage: "plus") { showingClone = true }
                        .help("Clone a repository (⇧⌘N)")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
        } detail: {
            if let selected = app.repositories.first(where: { $0.id == app.selection }) {
                RepositoryView(model: app.model(for: selected))
                    .id(selected.id)
            } else {
                ContentUnavailableView {
                    Label(app.repositories.isEmpty ? "No Repositories" : "Select a Repository", systemImage: "sidebar.left")
                } description: {
                    Text(app.repositories.isEmpty
                         ? "Clone a repository to get started."
                         : "Choose a repository from the sidebar, or clone a new one.")
                } actions: {
                    Button("Clone Repository", systemImage: "plus") { showingClone = true }
                        .buttonStyle(.borderedProminent)
                    if !app.repositories.isEmpty {
                        Button("Show Repositories", systemImage: "sidebar.left") { columnVisibility = .all }
                    }
                }
            }
        }
        .sheet(isPresented: $showingClone) {
            CloneView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete from This iPad", role: .destructive) {
                if let pendingDelete { app.delete(pendingDelete) }
                pendingDelete = nil
            }
        } message: {
            Text("This removes the folder from this iPad, including uncommitted changes and commits you haven't pushed. The remote is not affected.")
        }
        .alert("Error", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCloneSheet)) { _ in
            showingClone = true
        }
        .onChange(of: scenePhase) { _, phase in
            // Folders may have been added or removed in the Files app while we were away.
            if phase == .active { app.reloadRepositories() }
        }
    }
}
