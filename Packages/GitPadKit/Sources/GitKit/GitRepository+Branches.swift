import Foundation
import libgit2

extension GitRepository {
    public func branches() throws -> [BranchInfo] {
        var iterator: OpaquePointer?
        try LibGit2.check(git_branch_iterator_new(&iterator, handle, GIT_BRANCH_ALL))
        defer { git_branch_iterator_free(iterator) }

        var result: [BranchInfo] = []
        var ref: OpaquePointer?
        var type = GIT_BRANCH_LOCAL
        while git_branch_next(&ref, &type, iterator) == 0 {
            defer { git_reference_free(ref); ref = nil }
            var namePointer: UnsafePointer<CChar>?
            guard git_branch_name(&namePointer, ref) == 0, let name = LibGit2.string(namePointer) else { continue }
            let isRemote = type == GIT_BRANCH_REMOTE
            if isRemote, name.hasSuffix("/HEAD") { continue }

            var info = BranchInfo(
                name: name,
                isRemote: isRemote,
                isHead: git_branch_is_head(ref) == 1,
                targetID: git_reference_target(ref)?.pointee.hexString,
                upstream: nil
            )
            if !isRemote {
                var upstream: OpaquePointer?
                if git_branch_upstream(&upstream, ref) == 0 {
                    defer { git_reference_free(upstream) }
                    info.upstream = LibGit2.string(git_reference_shorthand(upstream))
                    if let local = git_reference_target(ref), let remote = git_reference_target(upstream) {
                        var ahead = 0, behind = 0
                        if git_graph_ahead_behind(&ahead, &behind, handle, local, remote) == 0 {
                            info.ahead = ahead
                            info.behind = behind
                        }
                    }
                }
            }
            result.append(info)
        }
        return result.sorted { ($0.isRemote ? 1 : 0, $0.name) < ($1.isRemote ? 1 : 0, $1.name) }
    }

    /// Creates a local branch at HEAD (or at `startPoint`, e.g. `origin/feature`).
    /// When starting from a remote branch, that branch becomes the upstream.
    public func createBranch(named name: String, from startPoint: String? = nil) throws {
        guard git_reference_is_valid_name("refs/heads/\(name)") == 1 else {
            throw GitError.libgit2(code: -1, message: "'\(name)' isn't a valid branch name.")
        }
        var object: OpaquePointer?
        try LibGit2.check(git_revparse_single(&object, handle, startPoint ?? "HEAD"))
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        try LibGit2.check(git_object_peel(&commit, object, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }

        var ref: OpaquePointer?
        try LibGit2.check(git_branch_create(&ref, handle, name, commit, 0))
        defer { git_reference_free(ref) }
        if let startPoint, try branches().contains(where: { $0.isRemote && $0.name == startPoint }) {
            try LibGit2.check(git_branch_set_upstream(ref, startPoint))
        }
    }

    /// Switches to a local branch. Uses a *safe* checkout: if switching would overwrite
    /// uncommitted changes, nothing is changed and `.localChangesWouldBeOverwritten` is thrown.
    /// Uncommitted changes that don't conflict are carried over, as with `git switch`.
    public func checkout(branch name: String) throws {
        var ref: OpaquePointer?
        try LibGit2.check(git_branch_lookup(&ref, handle, name, GIT_BRANCH_LOCAL))
        defer { git_reference_free(ref) }
        var target: OpaquePointer?
        try LibGit2.check(git_reference_peel(&target, ref, GIT_OBJECT_COMMIT))
        defer { git_object_free(target) }

        var options = git_checkout_options()
        try LibGit2.check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try LibGit2.check(git_checkout_tree(handle, target, &options))
        try LibGit2.check(git_repository_set_head(handle, "refs/heads/\(name)"))
    }

    /// Deletes a local branch. Refuses the current branch and (unless `force`) unmerged branches.
    public func deleteBranch(named name: String, force: Bool = false) throws {
        var ref: OpaquePointer?
        try LibGit2.check(git_branch_lookup(&ref, handle, name, GIT_BRANCH_LOCAL))
        defer { git_reference_free(ref) }
        guard git_branch_is_head(ref) == 0 else {
            throw GitError.libgit2(code: -1, message: "You can't delete the branch you're on.")
        }
        if !force, let head = try headCommit() {
            defer { git_commit_free(head) }
            if let tip = git_reference_target(ref), let headID = git_commit_id(head),
               git_graph_descendant_of(handle, headID, tip) != 1, git_oid_equal(headID, tip) != 1 {
                throw GitError.libgit2(code: -1, message: "'\(name)' has commits that aren't on the current branch.")
            }
        }
        try LibGit2.check(git_branch_delete(ref))
    }

    // MARK: - Remotes

    public func remotes() throws -> [RemoteInfo] {
        var names = git_strarray()
        try LibGit2.check(git_remote_list(&names, handle))
        defer { git_strarray_dispose(&names) }
        var result: [RemoteInfo] = []
        for i in 0..<names.count {
            guard let name = LibGit2.string(names.strings[i]) else { continue }
            var remote: OpaquePointer?
            guard git_remote_lookup(&remote, handle, name) == 0 else { continue }
            defer { git_remote_free(remote) }
            result.append(RemoteInfo(
                name: name,
                url: Redactor.redact(LibGit2.string(git_remote_url(remote)) ?? ""),
                pushURL: LibGit2.string(git_remote_pushurl(remote)).map(Redactor.redact)
            ))
        }
        return result
    }

    public func addRemote(named name: String, url: String) throws {
        var remote: OpaquePointer?
        try LibGit2.check(git_remote_create(&remote, handle, name, url))
        git_remote_free(remote)
    }

    public func setRemoteURL(named name: String, url: String) throws {
        try LibGit2.check(git_remote_set_url(handle, name, url))
    }

    /// The remote that `branch` tracks, falling back to `origin`.
    func remoteName(for branch: String?) -> String {
        guard let branch else { return "origin" }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        if git_branch_upstream_remote(&buffer, handle, "refs/heads/\(branch)") == 0, let ptr = buffer.ptr {
            return String(cString: ptr)
        }
        return "origin"
    }
}
