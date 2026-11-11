import GitPadCore
import QuickLook
import SwiftUI

/// Browses a folder of the working copy. `.git` is hidden so it can't be modified by accident.
struct FileBrowserView: View {
    let model: RepositoryModel
    let folder: URL
    @Environment(\.openURL) private var openURL
    @State private var entries: [Entry] = []
    @State private var previewURL: URL?
    @State private var path: [URL] = []

    struct Entry: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        let size: Int?
        let modified: Date?
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    var body: some View {
        NavigationStack(path: $path) {
            FolderList(model: model, folder: folder, previewURL: $previewURL)
                .navigationDestination(for: URL.self) { url in
                    FolderList(model: model, folder: url, previewURL: $previewURL)
                        .navigationTitle(url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .toolbar(.hidden, for: .navigationBar)
        }
        .quickLookPreview($previewURL)
    }
}

private struct FolderList: View {
    let model: RepositoryModel
    let folder: URL
    @Binding var previewURL: URL?
    @Environment(\.openURL) private var openURL
    @State private var entries: [FileBrowserView.Entry] = []
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(entries) { entry in
                row(entry)
            }
        }
        .overlay {
            if entries.isEmpty && loadError == nil {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .refreshable { await model.refresh(); load() }
        .onAppear(perform: load)
        .onChange(of: model.lastRefresh) { _, _ in load() }
    }

    @ViewBuilder
    private func row(_ entry: FileBrowserView.Entry) -> some View {
        let change = changeBadge(for: entry)
        Group {
            if entry.isFolder {
                NavigationLink(value: entry.url) {
                    rowContent(entry, change: change)
                }
            } else {
                Button { previewURL = entry.url } label: {
                    rowContent(entry, change: change)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            if !entry.isFolder {
                Button("Quick Look", systemImage: "eye") { previewURL = entry.url }
            }
            ShareLink(item: entry.url)
            if let url = entry.url.filesAppURL {
                Button("Show in Files", systemImage: "folder") { openURL(url) }
            }
        }
    }

    private func rowContent(_ entry: FileBrowserView.Entry, change: String?) -> some View {
        HStack {
            Image(systemName: entry.isFolder ? "folder.fill" : icon(for: entry.url))
                .foregroundStyle(entry.isFolder ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                HStack(spacing: 8) {
                    if let size = entry.size, !entry.isFolder {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    if let modified = entry.modified {
                        Text(modified, format: .dateTime.day().month().year().hour().minute())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let change {
                Text(change)
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(change == "U" ? .green : .orange)
                    .accessibilityLabel(change == "U" ? "Untracked" : "Modified")
            }
        }
        .contentShape(Rectangle())
    }

    private func load() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )
            entries = urls
                .filter { $0.lastPathComponent != ".git" && $0.lastPathComponent != ".DS_Store" }
                .map { url in
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    return .init(url: url, isFolder: values?.isDirectory ?? false, size: values?.fileSize, modified: values?.contentModificationDate)
                }
                .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// "M" when the file (or anything inside the folder) changed, "U" when untracked.
    private func changeBadge(for entry: FileBrowserView.Entry) -> String? {
        let root = model.repository.url.standardizedFileURL.path
        let full = entry.url.standardizedFileURL.path
        guard full.hasPrefix(root) else { return nil }
        let relative = String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let matches = model.changes.filter { entry.isFolder ? $0.path.hasPrefix(relative + "/") : $0.path == relative }
        guard !matches.isEmpty else { return nil }
        return matches.allSatisfy { $0.unstaged == .untracked } ? "U" : "M"
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "h", "m", "cpp", "java", "kt", "sh", "json", "yml", "yaml", "toml", "xml", "html", "css":
            "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rtf": "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "webp": "photo"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }
}
