import GitPadCore
import SwiftUI

struct HistoryView: View {
    let model: RepositoryModel

    var body: some View {
        List(model.commits) { commit in
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.summary).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 8) {
                    Text(commit.shortID).font(.caption.monospaced())
                    Text(commit.authorName)
                    Text(commit.date, format: .relative(presentation: .named))
                    if commit.parentIDs.count > 1 {
                        Label("Merge", systemImage: "arrow.triangle.merge").labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .contextMenu {
                Button("Copy Commit ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = commit.id }
            }
        }
        .overlay {
            if model.commits.isEmpty { ContentUnavailableView("No Commits Yet", systemImage: "clock") }
        }
        .refreshable { await model.refresh() }
    }
}

struct BranchesView: View {
    let model: RepositoryModel
    @State private var showingNewBranch = false
    @State private var newBranchName = ""
    @State private var newBranchStart: String?

    var body: some View {
        List {
            Section("Local") {
                ForEach(model.branches.filter { !$0.isRemote }) { branch in
                    HStack {
                        Image(systemName: branch.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch")
                            .foregroundStyle(branch.isHead ? Color.accentColor : .secondary)
                        VStack(alignment: .leading) {
                            Text(branch.name).fontWeight(branch.isHead ? .semibold : .regular)
                            if let upstream = branch.upstream {
                                Text(trackingText(branch, upstream: upstream)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !branch.isHead {
                            Button("Switch") { Task { await model.checkout(branch: branch.name) } }
                                .buttonStyle(.bordered)
                                .disabled(model.isBusy)
                        }
                    }
                    .contextMenu {
                        Button("New Branch from Here…", systemImage: "plus") {
                            newBranchStart = branch.name
                            showingNewBranch = true
                        }
                    }
                }
            }
            Section {
                ForEach(model.branches.filter(\.isRemote)) { branch in
                    HStack {
                        Image(systemName: "network").foregroundStyle(.secondary)
                        Text(branch.name)
                        Spacer()
                        let localName = branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch.name
                        if !model.branches.contains(where: { !$0.isRemote && $0.name == localName }) {
                            Button("Check Out") {
                                Task { await model.createBranch(named: localName, from: branch.name, switchTo: true) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isBusy)
                        }
                    }
                }
            } header: {
                Text("Remote")
            } footer: {
                Text("Switching branches never overwrites uncommitted changes. If it would, GitPad stops and tells you instead.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("New Branch", systemImage: "plus") {
                    newBranchStart = nil
                    showingNewBranch = true
                }
                .disabled(model.head?.isUnborn ?? true)
            }
        }
        .alert("New Branch", isPresented: $showingNewBranch) {
            TextField("Branch name", text: $newBranchName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create and Switch") {
                let name = newBranchName.trimmingCharacters(in: .whitespaces)
                newBranchName = ""
                Task { await model.createBranch(named: name, from: newBranchStart, switchTo: true) }
            }
            Button("Cancel", role: .cancel) { newBranchName = "" }
        } message: {
            Text("Starts from \(newBranchStart ?? model.head?.branch ?? "the current commit").")
        }
        .refreshable { await model.refresh() }
    }

    private func trackingText(_ branch: BranchInfo, upstream: String) -> String {
        var parts = ["tracks \(upstream)"]
        if let ahead = branch.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = branch.behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " · ")
    }
}
