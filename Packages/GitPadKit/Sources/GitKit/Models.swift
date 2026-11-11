import Foundation

/// Username/password pair handed to libgit2 for HTTPS. For token auth the password is the token.
public struct GitCredential: Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Supplies credentials for a remote URL on demand. Return `nil` when none are available
/// (libgit2 then reports an authentication error instead of prompting).
public typealias CredentialProvider = @Sendable (_ url: String, _ usernameFromURL: String?) -> GitCredential?

public struct TransferProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case receiving
        case resolving
        case checkingOut
        case uploading
        case done
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int
    public var bytes: Int

    public var fraction: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }

    public init(phase: Phase, completed: Int, total: Int, bytes: Int) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.bytes = bytes
    }
}

public typealias ProgressHandler = @Sendable (TransferProgress) -> Void

public struct GitSignature: Sendable, Equatable, Codable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

public enum ChangeKind: String, Sendable, Equatable, Codable {
    case added, modified, deleted, renamed, typeChanged, untracked
}

/// One path in `git status`. A path can be both staged and unstaged (e.g. edited again after `add`).
public struct FileChange: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var oldPath: String?
    public var staged: ChangeKind?
    public var unstaged: ChangeKind?
    public var isConflicted: Bool

    public init(path: String, oldPath: String? = nil, staged: ChangeKind? = nil, unstaged: ChangeKind? = nil, isConflicted: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.staged = staged
        self.unstaged = unstaged
        self.isConflicted = isConflicted
    }
}

public struct CommitInfo: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var shortID: String { String(id.prefix(7)) }
    public var summary: String
    public var message: String
    public var authorName: String
    public var authorEmail: String
    public var date: Date
    public var parentIDs: [String]
}

public struct BranchInfo: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { (isRemote ? "remote/" : "local/") + name }
    /// Short name, e.g. `main` or `origin/main`.
    public var name: String
    public var isRemote: Bool
    public var isHead: Bool
    public var targetID: String?
    /// Short upstream name, e.g. `origin/main` (local branches only).
    public var upstream: String?
    /// Commits on this branch not on its upstream / on the upstream not on this branch.
    public var ahead: Int?
    public var behind: Int?
}

public struct RemoteInfo: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var url: String
    public var pushURL: String?
}

public enum RepositoryState: Sendable, Equatable {
    case clean
    case merging
    case rebasing
    case cherryPicking
    case reverting
    case other(Int32)
}

public enum PullResult: Sendable, Equatable {
    case upToDate
    case fastForwarded(to: String)
    case merged(commit: String)
    /// The merge stopped with conflicts. Local changes were kept; the listed files need resolving.
    case conflicts([String])
}

public struct HeadInfo: Sendable, Equatable {
    /// Branch short name, or nil when detached / unborn.
    public var branch: String?
    public var commitID: String?
    public var isDetached: Bool
    public var isUnborn: Bool
}
