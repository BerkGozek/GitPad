import Foundation
import libgit2

/// Every failure GitKit reports. Messages are already redacted (no tokens, no URL credentials).
public enum GitError: Error, Equatable, Sendable {
    /// The operation was cancelled by the user (Swift task cancellation).
    case cancelled
    /// The server refused the credentials, or no credentials were available for a private repository.
    case authenticationFailed(String)
    /// The TLS certificate could not be verified.
    case certificateInvalid(String)
    /// Checkout/merge would overwrite uncommitted local changes, so nothing was changed.
    case localChangesWouldBeOverwritten(String)
    /// The remote rejected the push because it has commits we don't have.
    case pushRejectedNonFastForward(String)
    /// The remote rejected specific refs (e.g. branch protection). Keys are ref names.
    case pushRejected([String: String])
    /// The repository has unresolved merge conflicts.
    case unresolvedConflicts([String])
    /// The branch has no upstream configured.
    case noUpstream(branch: String)
    /// HEAD is detached; the operation needs a branch.
    case detachedHead
    /// The repository has no commits yet.
    case unbornBranch
    /// No author identity is configured for commits.
    case missingIdentity
    /// Nothing to commit (no staged changes).
    case nothingToCommit
    /// A branch, remote or object was not found.
    case notFound(String)
    /// The name already exists (branch, remote, folder).
    case alreadyExists(String)
    /// The folder is not a valid Git repository, or `.git` is damaged.
    case invalidRepository(String)
    /// The network could not be reached.
    case network(String)
    /// Any other libgit2 error.
    case libgit2(code: Int32, message: String)

    static func from(code: Int32, context: OperationContext?) -> GitError {
        let raw = git_error_last().flatMap { LibGit2.string($0.pointee.message) } ?? "libgit2 error \(code)"
        let klass = git_error_last()?.pointee.klass ?? 0
        let message = Redactor.redact(raw)

        if let context {
            if context.isCancelled { return .cancelled }
            if context.authenticationGaveUp { return .authenticationFailed(message) }
            if !context.rejectedRefs.isEmpty { return .pushRejected(context.rejectedRefs) }
        }
        switch code {
        case GIT_EUSER.rawValue: return .cancelled
        case GIT_EAUTH.rawValue: return .authenticationFailed(message)
        case GIT_ECERTIFICATE.rawValue: return .certificateInvalid(message)
        case GIT_ECONFLICT.rawValue, GIT_EMERGECONFLICT.rawValue: return .localChangesWouldBeOverwritten(message)
        case GIT_ENONFASTFORWARD.rawValue: return .pushRejectedNonFastForward(message)
        case GIT_ENOTFOUND.rawValue: return .notFound(message)
        case GIT_EEXISTS.rawValue: return .alreadyExists(message)
        case GIT_EUNBORNBRANCH.rawValue: return .unbornBranch
        default: break
        }
        if klass == Int32(GIT_ERROR_NET.rawValue) || klass == Int32(GIT_ERROR_SSL.rawValue) {
            // HTTP 401/403 surface as network-class errors on some servers.
            let lowered = message.lowercased()
            if lowered.contains("401") || lowered.contains("403") || lowered.contains("authentication") {
                return .authenticationFailed(message)
            }
            return .network(message)
        }
        if klass == Int32(GIT_ERROR_REPOSITORY.rawValue) || klass == Int32(GIT_ERROR_ODB.rawValue) {
            return .invalidRepository(message)
        }
        return .libgit2(code: code, message: message)
    }
}

extension GitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled: "The operation was cancelled."
        case .authenticationFailed(let m): "Authentication failed. Check the account and token for this host. (\(m))"
        case .certificateInvalid(let m): "The server's certificate could not be verified. (\(m))"
        case .localChangesWouldBeOverwritten: "Your uncommitted changes would be overwritten. Commit or discard them first; nothing was changed."
        case .pushRejectedNonFastForward: "The remote has commits you don't have yet. Pull first, then push again."
        case .pushRejected(let refs): "The remote rejected the push: " + refs.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
        case .unresolvedConflicts(let paths): "Resolve the conflicts in \(paths.count) file(s) first."
        case .noUpstream(let branch): "Branch '\(branch)' has no upstream branch on the remote yet."
        case .detachedHead: "You're not on a branch (detached HEAD). Switch to a branch first."
        case .unbornBranch: "The repository has no commits yet."
        case .missingIdentity: "Set your commit name and email in Settings first."
        case .nothingToCommit: "Nothing is staged for commit."
        case .notFound(let m): "Not found: \(m)"
        case .alreadyExists(let m): "Already exists: \(m)"
        case .invalidRepository(let m): "This folder isn't a valid Git repository, or its .git folder is damaged. (\(m))"
        case .network(let m): "Network error: \(m)"
        case .libgit2(_, let m): m
        }
    }
}
