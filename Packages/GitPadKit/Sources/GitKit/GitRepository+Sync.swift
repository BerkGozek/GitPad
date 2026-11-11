import Foundation
import libgit2

extension GitRepository {
    // MARK: - Fetch

    /// Fetches from a remote (default: the current branch's remote, else `origin`) and updates
    /// remote-tracking branches. Never touches local branches or the working tree.
    public func fetch(
        remote remoteName: String? = nil,
        credentials: CredentialProvider? = nil,
        progress: ProgressHandler? = nil
    ) async throws {
        let name = try remoteName ?? self.remoteName(for: head().branch)
        try await withOperation(credentials: credentials, progress: progress) { context in
            var remote: OpaquePointer?
            try LibGit2.check(git_remote_lookup(&remote, handle, name))
            defer { git_remote_free(remote) }

            var options = git_fetch_options()
            try LibGit2.check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
            context.install(into: &options.callbacks)
            options.prune = GIT_FETCH_PRUNE
            try LibGit2.check(git_remote_fetch(remote, nil, &options, "fetch"), context: context)
            if context.isCancelled { throw GitError.cancelled }
        }
        progress?(TransferProgress(phase: .done, completed: 1, total: 1, bytes: 0))
    }

    // MARK: - Pull

    /// Fetch, then integrate the upstream branch into the current branch.
    ///
    /// Safety: fast-forwards and merges use a safe checkout. If they would overwrite
    /// uncommitted changes, nothing is changed and `.localChangesWouldBeOverwritten` is thrown.
    /// Conflicts leave the repository in the merging state with conflict markers in the files,
    /// exactly like command-line Git, and are returned as `.conflicts`.
    public func pull(
        credentials: CredentialProvider? = nil,
        author: GitSignature? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> PullResult {
        let current = try head()
        guard !current.isDetached else { throw GitError.detachedHead }
        guard let branch = current.branch else { throw GitError.unbornBranch }
        guard state() == .clean else { throw GitError.unresolvedConflicts(try conflictedPaths()) }

        try await fetch(credentials: credentials, progress: progress)
        return try integrateUpstream(of: branch, author: author)
    }

    /// Integrates `branch`'s upstream (already fetched) into it. Split out so tests can call it.
    public func integrateUpstream(of branch: String, author: GitSignature? = nil) throws -> PullResult {
        var localRef: OpaquePointer?
        try LibGit2.check(git_branch_lookup(&localRef, handle, branch, GIT_BRANCH_LOCAL))
        defer { git_reference_free(localRef) }

        var upstreamRef: OpaquePointer?
        let upstreamCode = git_branch_upstream(&upstreamRef, localRef)
        if upstreamCode == GIT_ENOTFOUND.rawValue { throw GitError.noUpstream(branch: branch) }
        try LibGit2.check(upstreamCode)
        defer { git_reference_free(upstreamRef) }

        var annotated: OpaquePointer?
        try LibGit2.check(git_annotated_commit_from_ref(&annotated, handle, upstreamRef))
        defer { git_annotated_commit_free(annotated) }

        var analysis = GIT_MERGE_ANALYSIS_NONE
        var preference = GIT_MERGE_PREFERENCE_NONE
        var heads: [OpaquePointer?] = [annotated]
        try LibGit2.check(git_merge_analysis(&analysis, &preference, handle, &heads, 1))

        guard let upstreamOID = git_annotated_commit_id(annotated)?.pointee else {
            throw GitError.notFound("upstream commit")
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return .upToDate
        }

        if analysis.rawValue & (GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue | GIT_MERGE_ANALYSIS_UNBORN.rawValue) != 0 {
            let target = try lookupCommit(upstreamOID)
            defer { git_commit_free(target) }
            var options = git_checkout_options()
            try LibGit2.check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            try LibGit2.check(git_checkout_tree(handle, target, &options))

            var newRef: OpaquePointer?
            var oid = upstreamOID
            try LibGit2.check(git_reference_set_target(&newRef, localRef, &oid, "pull: fast-forward"))
            git_reference_free(newRef)
            return .fastForwarded(to: upstreamOID.hexString)
        }

        // A real merge. Check for an identity first so we don't stop half-way.
        guard let identity = author ?? configuredSignature() else { throw GitError.missingIdentity }

        var mergeOptions = git_merge_options()
        try LibGit2.check(git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        var checkoutOptions = git_checkout_options()
        try LibGit2.check(git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        try LibGit2.check(git_merge(handle, &heads, 1, &mergeOptions, &checkoutOptions))

        let conflicts = try conflictedPaths()
        if !conflicts.isEmpty {
            return .conflicts(conflicts)
        }
        let upstreamName = LibGit2.string(git_reference_shorthand(upstreamRef)) ?? "upstream"
        let commit = try commit(message: "Merge \(upstreamName) into \(branch)", author: identity)
        return .merged(commit: commit)
    }

    /// Abandons an in-progress merge, restoring HEAD's version of every file the merge touched.
    /// This discards the merge's changes in those files, so the UI must confirm first.
    public func abortMerge() throws {
        guard state() == .merging else { return }
        guard let head = try headCommit() else { throw GitError.unbornBranch }
        defer { git_commit_free(head) }
        var options = git_checkout_options()
        try LibGit2.check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        // Equivalent to `git merge --abort`: reset index + tracked files to HEAD.
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        try LibGit2.check(git_reset(handle, head, GIT_RESET_HARD, &options))
        git_repository_state_cleanup(handle)
    }

    // MARK: - Push

    /// Pushes the current branch (never forced). On first push, sets the upstream to
    /// `<remote>/<branch>`. A non-fast-forward rejection throws `.pushRejectedNonFastForward`.
    public func push(
        branch requestedBranch: String? = nil,
        remote requestedRemote: String? = nil,
        credentials: CredentialProvider? = nil,
        progress: ProgressHandler? = nil
    ) async throws {
        let current = try head()
        guard let branch = requestedBranch ?? current.branch else {
            throw current.isDetached ? GitError.detachedHead : GitError.unbornBranch
        }
        let remoteName = requestedRemote ?? self.remoteName(for: branch)
        let refspec = "refs/heads/\(branch):refs/heads/\(branch)"  // no leading "+": never a force push

        try await withOperation(credentials: credentials, progress: progress) { context in
            var remote: OpaquePointer?
            try LibGit2.check(git_remote_lookup(&remote, handle, remoteName))
            defer { git_remote_free(remote) }

            var options = git_push_options()
            try LibGit2.check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)))
            context.install(into: &options.callbacks)
            let refspecs = CStringArray([refspec])
            try LibGit2.check(git_remote_push(remote, &refspecs.array, &options), context: context)
            if context.isCancelled { throw GitError.cancelled }
            if !context.rejectedRefs.isEmpty {
                let reasons = context.rejectedRefs.values.joined(separator: " ").lowercased()
                if reasons.contains("fast-forward") || reasons.contains("fetch first") || reasons.contains("non-fast") {
                    throw GitError.pushRejectedNonFastForward(context.rejectedRefs.values.joined(separator: "; "))
                }
                throw GitError.pushRejected(context.rejectedRefs)
            }
        }

        // First push of this branch: track the remote branch, like `git push -u`.
        var localRef: OpaquePointer?
        if git_branch_lookup(&localRef, handle, branch, GIT_BRANCH_LOCAL) == 0 {
            defer { git_reference_free(localRef) }
            var upstream: OpaquePointer?
            if git_branch_upstream(&upstream, localRef) == 0 {
                git_reference_free(upstream)
            } else {
                _ = git_branch_set_upstream(localRef, "\(remoteName)/\(branch)")
            }
        }
        progress?(TransferProgress(phase: .done, completed: 1, total: 1, bytes: 0))
    }
}
