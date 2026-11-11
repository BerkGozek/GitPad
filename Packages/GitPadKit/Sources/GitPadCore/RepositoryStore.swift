import Foundation
import GitKit

/// A working copy stored by GitPad.
public struct LocalRepository: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL) {
        self.url = url
    }
}

public enum StoreError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case nameTaken(String)
    case notInStore

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "'\(name)' can't be used as a folder name."
        case .nameTaken(let name): "A repository named '\(name)' already exists."
        case .notInStore: "That folder isn't managed by GitPad."
        }
    }
}

/// Where repositories live on disk.
///
/// Working copies are in `Documents/Repositories/<name>`. With `UIFileSharingEnabled` and
/// `LSSupportsOpeningDocumentsInPlace`, the app's Documents folder appears in
/// Files → On My iPad → GitPad, so other apps can open and edit these files in place.
///
/// Clones are first written to a staging folder in Application Support (same volume, invisible
/// in Files) and moved into `Repositories/` only after they finish. A cancelled or interrupted
/// clone therefore never shows up as a half-finished repository.
public final class RepositoryStore: Sendable {
    public let repositoriesURL: URL
    let stagingURL: URL

    public init(repositoriesURL: URL, stagingURL: URL) {
        self.repositoriesURL = repositoriesURL
        self.stagingURL = stagingURL
    }

    /// The store used by the app.
    public static func live() -> RepositoryStore {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RepositoryStore(
            repositoriesURL: documents.appendingPathComponent("Repositories", isDirectory: true),
            stagingURL: support.appendingPathComponent("IncomingClones", isDirectory: true)
        )
    }

    /// Creates folders and removes leftovers of clones interrupted by the app being killed.
    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: repositoriesURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: stagingURL.path) {
            try fm.removeItem(at: stagingURL)
        }
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    }

    /// Folders in `Repositories/` that contain a `.git` folder, sorted by name.
    public func list() throws -> [LocalRepository] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: repositoriesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(".git").path) }
            .map { LocalRepository(url: $0.standardizedFileURL) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "https://github.com/apple/swift.git" → "swift"
    public func suggestedName(for remoteURL: String) -> String {
        var trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        var last = trimmed.split(separator: "/").last.map(String.init) ?? ""
        if last.hasSuffix(".git") { last.removeLast(4) }
        if let colon = last.lastIndex(of: ":") { last = String(last[last.index(after: colon)...]) }
        return last
    }

    /// Validates a folder name for a new repository. Returns the trimmed name.
    public func validateNewName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.hasPrefix("."),
              !trimmed.contains("/"), !trimmed.contains(":"), trimmed.count <= 200 else {
            throw StoreError.invalidName(trimmed)
        }
        if FileManager.default.fileExists(atPath: repositoriesURL.appendingPathComponent(trimmed).path) {
            throw StoreError.nameTaken(trimmed)
        }
        return trimmed
    }

    /// Clones into staging, then moves the finished working copy into `Repositories/<name>`.
    public func clone(
        from remoteURL: String,
        name: String,
        credentials: CredentialProvider? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> LocalRepository {
        let finalName = try validateNewName(name)
        let fm = FileManager.default
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let stagingFolder = stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: stagingFolder) }

        let staged = stagingFolder.appendingPathComponent(finalName, isDirectory: true)
        let trimmedURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await GitRepository.clone(from: trimmedURL, to: staged, credentials: credentials, progress: progress)
        try Task.checkCancellation()

        // Re-check in case another clone with the same name finished meanwhile.
        _ = try validateNewName(finalName)
        let destination = repositoriesURL.appendingPathComponent(finalName, isDirectory: true)
        try fm.moveItem(at: staged, to: destination)
        return LocalRepository(url: destination.standardizedFileURL)
    }

    /// Permanently deletes a working copy (including uncommitted and unpushed work).
    /// The UI must confirm first and say what will be lost.
    public func delete(_ repository: LocalRepository) throws {
        let parent = repository.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard parent.path == repositoriesURL.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw StoreError.notInStore
        }
        try FileManager.default.removeItem(at: repository.url)
    }
}
