import Foundation
import GitPadCore
import Observation

/// State and actions for one repository screen. Views never touch GitKit directly.
@MainActor @Observable
final class RepositoryModel {
    let repository: LocalRepository
    private var git: GitRepository?

    private(set) var head: HeadInfo?
    private(set) var state: RepositoryState = .clean
    private(set) var changes: [FileChange] = []
    private(set) var commits: [CommitInfo] = []
    private(set) var branches: [BranchInfo] = []
    private(set) var remotes: [RemoteInfo] = []
    private(set) var lastRefresh: Date?
    private(set) var lastFetch: Date?

    /// A running operation ("Pulling…"), shown as a banner with progress.
    private(set) var activity: String?
    private(set) var progress: TransferProgress?
    var errorMessage: String?
    var infoMessage: String?
    private var runningTask: Task<Void, Never>?

    var stagedChanges: [FileChange] { changes.filter { $0.staged != nil } }
    var unstagedChanges: [FileChange] { changes.filter { $0.unstaged != nil || $0.isConflicted } }
    var conflicts: [FileChange] { changes.filter(\.isConflicted) }
    var currentBranch: BranchInfo? { branches.first { $0.isHead && !$0.isRemote } }
    var isBusy: Bool { activity != nil }

    init(repository: LocalRepository) {
        self.repository = repository
    }

    // MARK: - Refresh

    /// Re-reads everything from disk. Called on appear, when the app becomes active
    /// (to pick up edits made in other apps), and after every operation.
    func refresh() async {
        do {
            let git = try openIfNeeded()
            try await git.verifyIntegrity()
            head = try await git.head()
            state = await git.state()
            changes = try await git.status()
            commits = try await git.log(limit: 300)
            branches = try await git.branches()
            remotes = try await git.remotes()
            lastRefresh = .now
        } catch {
            show(error)
        }
    }

    private func openIfNeeded() throws -> GitRepository {
        if let git { return git }
        let opened = try GitRepository(openingAt: repository.url)
        git = opened
        return opened
    }

    // MARK: - Local operations

    func stage(_ paths: [String]) async {
        await perform { try await $0.stage(paths) }
    }

    func unstage(_ paths: [String]) async {
        await perform { try await $0.unstage(paths) }
    }

    func stageAll() async {
        await perform { try await $0.stageAll() }
    }

    /// Returns true when the commit was created.
    func commit(message: String) async -> Bool {
        guard let identity = CommitIdentity.current else {
            errorMessage = GitError.missingIdentity.localizedDescription
            return false
        }
        var succeeded = false
        await perform {
            let id = try await $0.commit(message: message, author: identity)
            succeeded = true
            self.infoMessage = "Committed \(id.prefix(7))."
        }
        return succeeded
    }

    func diff(for change: FileChange, staged: Bool) async -> String {
        do {
            return try await openIfNeeded().diff(path: change.path, staged: staged)
        } catch {
            return Redactor.redact(error.localizedDescription)
        }
    }

    func checkout(branch: String) async {
        await perform { try await $0.checkout(branch: branch) }
    }

    func createBranch(named name: String, from startPoint: String?, switchTo: Bool) async {
        await perform {
            try await $0.createBranch(named: name, from: startPoint)
            if switchTo { try await $0.checkout(branch: name) }
        }
    }

    func abortMerge() async {
        await perform { try await $0.abortMerge() }
    }

    // MARK: - Network operations

    func fetch() {
        runNetwork("Fetching") { git, progress in
            try await git.fetch(progress: progress)
            self.lastFetch = .now
            self.infoMessage = "Fetched."
        }
    }

    func pull() {
        runNetwork("Pulling") { git, progress in
            let result = try await git.pull(author: CommitIdentity.current, progress: progress)
            self.lastFetch = .now
            switch result {
            case .upToDate: self.infoMessage = "Already up to date."
            case .fastForwarded: self.infoMessage = "Pulled (fast-forward)."
            case .merged: self.infoMessage = "Pulled and merged."
            case .conflicts(let paths):
                self.errorMessage = "Pull stopped with conflicts in \(paths.count) file(s). Your changes are kept. Resolve them in Changes, or abort the merge."
            }
        }
    }

    func cancelRunningOperation() {
        runningTask?.cancel()
    }

    // MARK: - Plumbing

    private func perform(_ body: @MainActor (GitRepository) async throws -> Void) async {
        do {
            try await body(openIfNeeded())
        } catch {
            show(error)
        }
        await refresh()
    }

    private func runNetwork(_ title: String, _ body: @escaping @MainActor (GitRepository, @escaping ProgressHandler) async throws -> Void) {
        guard runningTask == nil else { return }
        activity = title
        progress = nil
        runningTask = Task {
            let handler: ProgressHandler = { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            do {
                try await body(openIfNeeded(), handler)
            } catch {
                show(error)
            }
            activity = nil
            progress = nil
            runningTask = nil
            await refresh()
        }
    }

    private func show(_ error: Error) {
        if let gitError = error as? GitError, gitError == .cancelled {
            infoMessage = "Cancelled."
            return
        }
        errorMessage = Redactor.redact(error.localizedDescription)
    }
}
