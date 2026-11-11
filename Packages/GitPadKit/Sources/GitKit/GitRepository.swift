import Foundation
import libgit2

/// One open Git repository.
///
/// libgit2 repository handles must not be used from several threads at once, so each repository
/// is an actor. Its executor is a private serial dispatch queue rather than Swift's cooperative
/// thread pool: libgit2 calls block (a clone can take minutes), and blocking the cooperative pool
/// would stall unrelated async work in the app.
public actor GitRepository {
    private let queue: DispatchSerialQueue
    nonisolated(unsafe) let handle: OpaquePointer

    /// Working directory (the folder that contains `.git`).
    public nonisolated let workingDirectory: URL

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private init(handle: OpaquePointer, workingDirectory: URL) {
        self.handle = handle
        self.workingDirectory = workingDirectory
        self.queue = DispatchSerialQueue(label: "GitPad.repository.\(workingDirectory.lastPathComponent)", qos: .userInitiated)
    }

    deinit {
        git_repository_free(handle)
    }

    // MARK: - Opening

    /// Opens an existing non-bare repository at exactly `url` (no searching parent folders).
    public init(openingAt url: URL) throws {
        LibGit2.ensureInitialized()
        var repo: OpaquePointer?
        let code = git_repository_open_ext(&repo, url.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        if code < 0 {
            throw GitError.invalidRepository(GitError.from(code: code, context: nil).localizedDescription)
        }
        guard let repo else { throw GitError.invalidRepository(url.lastPathComponent) }
        guard git_repository_is_bare(repo) == 0, let workdir = git_repository_workdir(repo) else {
            git_repository_free(repo)
            throw GitError.invalidRepository("bare repositories can't be opened as a working copy")
        }
        self.init(handle: repo, workingDirectory: URL(fileURLWithPath: String(cString: workdir), isDirectory: true).standardizedFileURL)
    }

    /// Creates a new repository (used for "New repository" and in tests).
    /// Returns nil for bare repositories, which have no working copy to manage.
    @discardableResult
    public static func create(at url: URL, bare: Bool = false, initialBranch: String = "main") throws -> GitRepository? {
        LibGit2.ensureInitialized()
        var options = git_repository_init_options()
        try LibGit2.check(git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)))
        options.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue | (bare ? GIT_REPOSITORY_INIT_BARE.rawValue : 0)
        var repo: OpaquePointer?
        try initialBranch.withCString { branch in
            options.initial_head = branch
            try LibGit2.check(git_repository_init_ext(&repo, url.path, &options))
        }
        git_repository_free(repo)
        return bare ? nil : try GitRepository(openingAt: url)
    }

    /// Clones `remoteURL` into `destination` (which must not exist or be empty).
    ///
    /// Runs on a background dispatch queue. Cancelling the calling task stops the transfer at
    /// the next progress callback; the caller is responsible for deleting the partial folder
    /// (`RepositoryStore` clones into a staging folder for exactly this reason).
    public static func clone(
        from remoteURL: String,
        to destination: URL,
        branch: String? = nil,
        credentials: CredentialProvider? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> GitRepository {
        LibGit2.ensureInitialized()
        let context = OperationContext(credentials: credentials, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try performClone(remoteURL: remoteURL, destination: destination, branch: branch, context: context)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            context.cancel()
        }
        progress?(TransferProgress(phase: .done, completed: 1, total: 1, bytes: 0))
        return try GitRepository(openingAt: destination)
    }

    private static func performClone(remoteURL: String, destination: URL, branch: String?, context: OperationContext) throws {
        var options = git_clone_options()
        try LibGit2.check(git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)))
        context.install(into: &options.fetch_opts.callbacks)
        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        context.install(into: &options.checkout_opts)

        var repo: OpaquePointer?
        let code: Int32 = if let branch {
            branch.withCString { cBranch in
                options.checkout_branch = cBranch
                return git_clone(&repo, remoteURL, destination.path, &options)
            }
        } else {
            git_clone(&repo, remoteURL, destination.path, &options)
        }
        git_repository_free(repo)
        try LibGit2.check(code, context: context)
        if context.isCancelled { throw GitError.cancelled }
    }

    // MARK: - Shared helpers for extensions

    /// Runs a network operation with cancellation + callbacks wired up.
    func withOperation<R>(
        credentials: CredentialProvider?,
        progress: ProgressHandler?,
        _ body: (OperationContext) throws -> R
    ) async throws -> R {
        let context = OperationContext(credentials: credentials, progress: progress)
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw GitError.cancelled }
            return try body(context)
        } onCancel: {
            context.cancel()
        }
    }

    func lookupCommit(_ oid: git_oid) throws -> OpaquePointer {
        var oid = oid
        var commit: OpaquePointer?
        try LibGit2.check(git_commit_lookup(&commit, handle, &oid))
        return commit!
    }

    /// HEAD's commit, or nil for an unborn branch.
    func headCommit() throws -> OpaquePointer? {
        var oid = git_oid()
        let code = git_reference_name_to_id(&oid, handle, "HEAD")
        if code == GIT_ENOTFOUND.rawValue || code == GIT_EUNBORNBRANCH.rawValue { return nil }
        try LibGit2.check(code)
        return try lookupCommit(oid)
    }

    /// Opens the index, re-reading it from disk so changes made by another app are picked up.
    /// The caller must `git_index_free` it.
    func openIndex() throws -> OpaquePointer {
        var index: OpaquePointer?
        try LibGit2.check(git_repository_index(&index, handle))
        let code = git_index_read(index, 0)
        if code < 0 {
            git_index_free(index)
            try LibGit2.check(code)
        }
        return index!
    }

    func withIndex<R>(_ body: (OpaquePointer) throws -> R) throws -> R {
        let index = try openIndex()
        defer { git_index_free(index) }
        return try body(index)
    }

    // MARK: - Basic info

    /// Checks that `.git` is readable and HEAD resolves (or is a valid unborn branch).
    public func verifyIntegrity() throws {
        _ = try head()
        _ = try withIndex { _ in true }
    }

    public func head() throws -> HeadInfo {
        let unborn = git_repository_head_unborn(handle) == 1
        let detached = git_repository_head_detached(handle) == 1
        if unborn {
            var ref: OpaquePointer?
            try LibGit2.check(git_reference_lookup(&ref, handle, "HEAD"))
            defer { git_reference_free(ref) }
            let target = LibGit2.string(git_reference_symbolic_target(ref)) ?? ""
            let branch = target.hasPrefix("refs/heads/") ? String(target.dropFirst("refs/heads/".count)) : nil
            return HeadInfo(branch: branch, commitID: nil, isDetached: false, isUnborn: true)
        }
        var ref: OpaquePointer?
        try LibGit2.check(git_repository_head(&ref, handle))
        defer { git_reference_free(ref) }
        let oid = git_reference_target(ref)?.pointee.hexString
        let branch = detached ? nil : LibGit2.string(git_reference_shorthand(ref))
        return HeadInfo(branch: branch, commitID: oid, isDetached: detached, isUnborn: false)
    }

    public func state() -> RepositoryState {
        let raw = git_repository_state(handle)
        switch raw {
        case Int32(GIT_REPOSITORY_STATE_NONE.rawValue): return .clean
        case Int32(GIT_REPOSITORY_STATE_MERGE.rawValue): return .merging
        case Int32(GIT_REPOSITORY_STATE_REBASE.rawValue),
             Int32(GIT_REPOSITORY_STATE_REBASE_MERGE.rawValue),
             Int32(GIT_REPOSITORY_STATE_REBASE_INTERACTIVE.rawValue): return .rebasing
        case Int32(GIT_REPOSITORY_STATE_CHERRYPICK.rawValue),
             Int32(GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE.rawValue): return .cherryPicking
        case Int32(GIT_REPOSITORY_STATE_REVERT.rawValue),
             Int32(GIT_REPOSITORY_STATE_REVERT_SEQUENCE.rawValue): return .reverting
        default: return .other(raw)
        }
    }

    /// The identity from the repository's (or global) Git config, if any.
    public func configuredSignature() -> GitSignature? {
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, handle) == 0, let signature else { return nil }
        defer { git_signature_free(signature) }
        return GitSignature(name: String(cString: signature.pointee.name), email: String(cString: signature.pointee.email))
    }
}
