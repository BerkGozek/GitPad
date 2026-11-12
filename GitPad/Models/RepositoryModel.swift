import Foundation
import GitPadCore
import Observation

/// State and actions for one repository screen. Views never touch GitKit directly.
@MainActor @Observable
final class RepositoryModel {
    let repository: LocalRepository
    private weak var app: AppModel?
    private var git: GitRepository?
    private(set) var outgoing: [CommitInfo] = []
    /// Set when a push was rejected because the remote has new commits; the UI offers "Pull".
    var pushNeedsPull = false

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

    init(repository: LocalRepository, app: AppModel) {
        self.repository = repository
        self.app = app
    }

    // MARK: - Accounts

    /// The remote we sync with: the current branch's remote, else `origin`, else the first one.
    var primaryRemote: RemoteInfo? {
        let wanted = currentBranch?.upstream?.split(separator: "/").first.map(String.init) ?? "origin"
        return remotes.first { $0.name == wanted } ?? remotes.first
    }

    var remoteHost: String? {
        primaryRemote.flatMap { AccountStore.host(of: $0.url) }
    }

    /// Accounts whose host matches this repository's remote.
    var candidateAccounts: [Account] {
        guard let host = remoteHost, let app else { return [] }
        return app.accounts.filter { $0.host == host }
    }

    /// The account used for network operations, or nil (public access).
    /// Throws `.chooseAccount` when several match and the user hasn't picked one.
    func resolvedAccount() throws -> Account? {
        guard let app, let remote = primaryRemote else { return nil }
        return try app.accountStore.resolveAccount(forRemote: remote.url, repository: repository.name)
    }

    var selectedAccountID: UUID? {
        get { (try? resolvedAccount())?.id }
        set {
            try? app?.accountStore.assign(newValue, toRepository: repository.name)
        }
    }

    private func credentials(required: Bool) throws -> CredentialProvider? {
        guard let app else { return nil }
        guard let account = try resolvedAccount() else {
            if required { throw AccountError.noAccount(host: remoteHost ?? "this server") }
            return nil
        }
        return app.accountStore.credentialProvider(for: account)
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
            outgoing = try await git.outgoingCommits()
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
            try await git.fetch(credentials: self.credentials(required: false), progress: progress)
            self.lastFetch = .now
            self.infoMessage = "Fetched."
        }
    }

    /// Pushes the current branch. Never forced: a rejection is explained and offers a pull.
    func push() {
        let count = outgoing.count
        runNetwork("Pushing") { git, progress in
            try await git.push(credentials: self.credentials(required: true), progress: progress)
            self.infoMessage = count == 1 ? "Pushed 1 commit." : "Pushed \(count) commits."
        }
    }

    func pull() {
        pushNeedsPull = false
        runNetwork("Pulling") { git, progress in
            let result = try await git.pull(credentials: self.credentials(required: false), author: CommitIdentity.current, progress: progress)
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
        switch error as? GitError {
        case .cancelled?:
            infoMessage = "Cancelled."
            return
        case .pushRejectedNonFastForward?:
            pushNeedsPull = true
            return
        case .authenticationFailed?:
            let hint = (try? resolvedAccount()) == nil
                ? "This repository needs an account. Add one in Settings → Accounts."
                : "Check that the token is valid, not expired, and has write access to this repository."
            errorMessage = "Authentication failed. \(hint)"
            return
        case .permissionDenied?:
            let account = try? resolvedAccount()
            let fix = account?.provider == .github
                ? "On github.com: Settings → Developer settings → your token → Edit. Under Repository access include \(repository.name), and set Contents to “Read and write”. The token itself doesn't change, so just push again."
                : "Give the token write access to this repository on \(remoteHost ?? "the server"), then push again."
            errorMessage = "Your token is valid but isn't allowed to push here (HTTP 403). \(fix)"
            return
        default:
            errorMessage = Redactor.redact(error.localizedDescription)
        }
    }
}
