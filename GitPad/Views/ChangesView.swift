import GitPadCore
import SwiftUI

struct ChangesView: View {
    @Bindable var model: RepositoryModel
    @State private var message = ""
    @State private var diffTarget: DiffTarget?
    @State private var confirmAbort = false
    @FocusState private var messageFocused: Bool

    struct DiffTarget: Identifiable {
        let change: FileChange
        let staged: Bool
        var id: String { change.path + (staged ? "#staged" : "#unstaged") }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if model.state == .merging {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Merge in progress", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundStyle(.orange)
                            Text(model.conflicts.isEmpty
                                 ? "All conflicts are resolved. Commit to finish the merge."
                                 : "Open each conflicted file in an editor (Show in Files), keep the lines you want and remove the <<<<<<< ======= >>>>>>> markers. Then stage it here to mark it resolved.")
                                .font(.callout)
                            Button("Abort Merge…", role: .destructive) { confirmAbort = true }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    if model.stagedChanges.isEmpty {
                        Text("Nothing staged").foregroundStyle(.secondary)
                    }
                    ForEach(model.stagedChanges) { change in
                        ChangeRow(change: change, kind: change.staged)
                            .contentShape(Rectangle())
                            .onTapGesture { diffTarget = DiffTarget(change: change, staged: true) }
                            .swipeActions { Button("Unstage") { Task { await model.unstage([change.path]) } }.tint(.orange) }
                            .contextMenu {
                                Button("Unstage", systemImage: "minus.circle") { Task { await model.unstage([change.path]) } }
                                Button("Show Diff", systemImage: "plus.forwardslash.minus") { diffTarget = DiffTarget(change: change, staged: true) }
                            }
                    }
                } header: {
                    HStack {
                        Text("Staged (\(model.stagedChanges.count))")
                        Spacer()
                        if !model.stagedChanges.isEmpty {
                            Button("Unstage All") { Task { await model.unstage(model.stagedChanges.map(\.path)) } }.font(.caption)
                        }
                    }
                }

                Section {
                    if model.unstagedChanges.isEmpty {
                        Text("No changes in the working copy").foregroundStyle(.secondary)
                    }
                    ForEach(model.unstagedChanges) { change in
                        ChangeRow(change: change, kind: change.isConflicted ? nil : change.unstaged)
                            .contentShape(Rectangle())
                            .onTapGesture { diffTarget = DiffTarget(change: change, staged: false) }
                            .swipeActions {
                                Button(change.isConflicted ? "Mark Resolved" : "Stage") { Task { await model.stage([change.path]) } }.tint(.green)
                            }
                            .contextMenu {
                                Button(change.isConflicted ? "Mark Resolved" : "Stage", systemImage: "plus.circle") { Task { await model.stage([change.path]) } }
                                Button("Show Diff", systemImage: "plus.forwardslash.minus") { diffTarget = DiffTarget(change: change, staged: false) }
                                let url = model.repository.url.appendingPathComponent(change.path)
                                if FileManager.default.fileExists(atPath: url.path) {
                                    ShareLink(item: url)
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Changes (\(model.unstagedChanges.count))")
                        Spacer()
                        if !model.unstagedChanges.isEmpty {
                            Button("Stage All") { Task { await model.stageAll() } }.font(.caption)
                        }
                    }
                }
            }
            .refreshable { await model.refresh() }

            commitBar
        }
        .sheet(item: $diffTarget) { target in
            DiffView(model: model, change: target.change, staged: target.staged)
        }
        .confirmationDialog("Abort the merge?", isPresented: $confirmAbort, titleVisibility: .visible) {
            Button("Abort Merge", role: .destructive) { Task { await model.abortMerge() } }
        } message: {
            Text("Files go back to how they were before the pull. Edits you made while resolving conflicts are lost.")
        }
    }

    private var commitBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom) {
                TextField("Commit message", text: $message, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($messageFocused)
                Button("Commit") {
                    Task {
                        if await model.commit(message: message) {
                            message = ""
                            messageFocused = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (model.stagedChanges.isEmpty && model.state != .merging)
                          || !model.conflicts.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

private struct ChangeRow: View {
    let change: FileChange
    let kind: ChangeKind?

    var body: some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading) {
                Text((change.path as NSString).lastPathComponent)
                let folder = (change.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(change.isConflicted ? "Conflict" : (kind?.rawValue.capitalized ?? ""))
                .font(.caption)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if change.isConflicted { return "exclamationmark.triangle.fill" }
        switch kind {
        case .added, .untracked: return "plus.square"
        case .deleted: return "minus.square"
        case .renamed: return "arrow.right.square"
        default: return "pencil.line"
        }
    }

    private var color: Color {
        if change.isConflicted { return .red }
        switch kind {
        case .added, .untracked: return .green
        case .deleted: return .red
        default: return .orange
        }
    }
}

struct DiffView: View {
    let model: RepositoryModel
    let change: FileChange
    let staged: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                if let text {
                    if text.isEmpty {
                        Text("No textual changes (binary file or mode change).").foregroundStyle(.secondary).padding()
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                Text(String(line).isEmpty ? " " : String(line))
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .background(background(for: line))
                            }
                        }
                        .textSelection(.enabled)
                    }
                } else {
                    ProgressView().padding()
                }
            }
            .navigationTitle(change.path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { text = await model.diff(for: change, staged: staged) }
        }
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return .green.opacity(0.15) }
        if line.hasPrefix("-") { return .red.opacity(0.15) }
        if line.hasPrefix("@@") { return .blue.opacity(0.1) }
        return .clear
    }
}
