import GitPadCore
import SwiftUI

struct RepositoryView: View {
    @Bindable var model: RepositoryModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var tab: Tab = .files
    @State private var showingPush = false

    enum Tab: String, CaseIterable, Identifiable {
        case files = "Files", changes = "Changes", history = "History", branches = "Branches"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .files: "folder"
            case .changes: "plus.forwardslash.minus"
            case .history: "clock"
            case .branches: "arrow.triangle.branch"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let activity = model.activity {
                activityBanner(activity)
            }
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(label(for: tab), systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            switch tab {
            case .files: FileBrowserView(model: model, folder: model.repository.url)
            case .changes: ChangesView(model: model)
            case .history: HistoryView(model: model)
            case .branches: BranchesView(model: model)
            }
        }
        .navigationTitle(model.repository.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Fetch", systemImage: "arrow.down.circle") { model.fetch() }
                    .disabled(model.isBusy || model.remotes.isEmpty)
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Pull", systemImage: "arrow.down.to.line") { model.pull() }
                    .disabled(model.isBusy || model.remotes.isEmpty || model.head?.branch == nil)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button {
                    showingPush = true
                } label: {
                    Label(model.outgoing.isEmpty ? "Push" : "Push (\(model.outgoing.count))", systemImage: "arrow.up.to.line")
                }
                .badge(model.outgoing.count)
                .disabled(model.isBusy || model.remotes.isEmpty || model.head?.branch == nil)
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .help("Push commits (⇧⌘U)")
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                if let url = model.repository.url.filesAppURL {
                    Button("Show in Files", systemImage: "folder") { openURL(url) }
                }
            }
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Pick up edits made in other apps while GitPad was in the background.
            if phase == .active { Task { await model.refresh() } }
        }
        .sheet(isPresented: $showingPush) {
            PushView(model: model)
        }
        .alert("Push Rejected", isPresented: $model.pushNeedsPull) {
            Button("Pull Now") { model.pull() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("The remote has commits you don't have yet, so pushing would overwrite them. GitPad never force-pushes. Pull first (your commits are kept and merged), then push again.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let info = model.infoMessage {
                Text(info)
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect()
                    .padding(.bottom, 24)
                    .task(id: info) {
                        try? await Task.sleep(for: .seconds(2.5))
                        model.infoMessage = nil
                    }
            }
        }
    }

    private func label(for tab: Tab) -> String {
        if tab == .changes, !model.changes.isEmpty { return "Changes (\(model.changes.count))" }
        return tab.rawValue
    }

    private var header: some View {
        HStack(spacing: 16) {
            Label(model.head?.branch ?? (model.head?.isDetached == true ? "Detached HEAD" : "—"), systemImage: "arrow.triangle.branch")
                .font(.headline)
            if let branch = model.currentBranch, let upstream = branch.upstream {
                HStack(spacing: 6) {
                    Text(upstream).foregroundStyle(.secondary)
                    if let ahead = branch.ahead, ahead > 0 { Label("\(ahead)", systemImage: "arrow.up").help("\(ahead) commit(s) to push") }
                    if let behind = branch.behind, behind > 0 { Label("\(behind)", systemImage: "arrow.down").help("\(behind) commit(s) to pull") }
                }
                .font(.subheadline)
            }
            if model.state == .merging {
                Label("Merging", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
            }
            Spacer()
            if let host = model.remotes.first.flatMap({ URL(string: $0.url)?.host() }) {
                Label(host, systemImage: "network").font(.subheadline).foregroundStyle(.secondary)
            }
            if let lastFetch = model.lastFetch {
                Text("Fetched \(lastFetch, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func activityBanner(_ title: String) -> some View {
        HStack {
            if let progress = model.progress, progress.total > 0 {
                ProgressView(value: progress.fraction) { Text("\(title)… \(progress.completed)/\(progress.total)").font(.caption) }
            } else {
                ProgressView().controlSize(.small)
                Text("\(title)…").font(.callout)
                Spacer()
            }
            Button("Stop", role: .cancel) { model.cancelRunningOperation() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
