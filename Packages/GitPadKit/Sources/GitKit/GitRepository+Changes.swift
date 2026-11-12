import Foundation
import libgit2

extension GitRepository {
    // MARK: - Status

    public func status() throws -> [FileChange] {
        var options = git_status_options()
        try LibGit2.check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            | GIT_STATUS_OPT_SORT_CASE_INSENSITIVELY.rawValue

        var list: OpaquePointer?
        try LibGit2.check(git_status_list_new(&list, handle, &options))
        defer { git_status_list_free(list) }

        var changes: [FileChange] = []
        for i in 0..<git_status_list_entrycount(list) {
            guard let entry = git_status_byindex(list, i)?.pointee else { continue }
            let flags = entry.status.rawValue
            if flags & GIT_STATUS_IGNORED.rawValue != 0 { continue }

            let headToIndex = entry.head_to_index?.pointee
            let indexToWorkdir = entry.index_to_workdir?.pointee
            let path = LibGit2.string(indexToWorkdir?.new_file.path)
                ?? LibGit2.string(headToIndex?.new_file.path)
                ?? LibGit2.string(indexToWorkdir?.old_file.path)
                ?? LibGit2.string(headToIndex?.old_file.path)
                ?? "?"
            var oldPath: String?
            if flags & GIT_STATUS_INDEX_RENAMED.rawValue != 0 {
                oldPath = LibGit2.string(headToIndex?.old_file.path)
            }

            let staged: ChangeKind? =
                if flags & GIT_STATUS_INDEX_NEW.rawValue != 0 { .added }
                else if flags & GIT_STATUS_INDEX_RENAMED.rawValue != 0 { .renamed }
                else if flags & GIT_STATUS_INDEX_DELETED.rawValue != 0 { .deleted }
                else if flags & GIT_STATUS_INDEX_TYPECHANGE.rawValue != 0 { .typeChanged }
                else if flags & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 { .modified }
                else { nil }
            let unstaged: ChangeKind? =
                if flags & GIT_STATUS_WT_NEW.rawValue != 0 { .untracked }
                else if flags & GIT_STATUS_WT_DELETED.rawValue != 0 { .deleted }
                else if flags & GIT_STATUS_WT_RENAMED.rawValue != 0 { .renamed }
                else if flags & GIT_STATUS_WT_TYPECHANGE.rawValue != 0 { .typeChanged }
                else if flags & GIT_STATUS_WT_MODIFIED.rawValue != 0 { .modified }
                else { nil }
            let conflicted = flags & GIT_STATUS_CONFLICTED.rawValue != 0

            changes.append(FileChange(path: path, oldPath: oldPath, staged: staged, unstaged: unstaged, isConflicted: conflicted))
        }
        return changes
    }

    public func conflictedPaths() throws -> [String] {
        try status().filter(\.isConflicted).map(\.path)
    }

    // MARK: - Staging

    /// `git add` for each path, including deletions. Staging a conflicted file marks it resolved.
    public func stage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try withIndex { index in
            for path in paths {
                let fileURL = workingDirectory.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try LibGit2.check(git_index_add_bypath(index, path))
                } else {
                    try LibGit2.check(git_index_remove_bypath(index, path))
                }
            }
            try LibGit2.check(git_index_write(index))
        }
    }

    public func stageAll() throws {
        try stage(status().filter { $0.unstaged != nil || $0.isConflicted }.map(\.path))
    }

    /// `git restore --staged` for each path. Working-tree contents are never touched.
    public func unstage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        if let head = try headCommit() {
            defer { git_commit_free(head) }
            let pathspec = CStringArray(paths)
            try LibGit2.check(git_reset_default(handle, head, &pathspec.array))
        } else {
            // No commits yet: unstaging means removing the entries from the index.
            try withIndex { index in
                for path in paths {
                    try LibGit2.check(git_index_remove_bypath(index, path))
                }
                try LibGit2.check(git_index_write(index))
            }
        }
    }

    // MARK: - Committing

    /// Creates a commit from the index on the current branch.
    /// If a merge is in progress (and all conflicts are resolved), it becomes the merge commit.
    @discardableResult
    public func commit(message: String, author: GitSignature? = nil) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.libgit2(code: -1, message: "The commit message is empty.") }
        guard git_repository_head_detached(handle) == 0 else { throw GitError.detachedHead }

        let identity = author ?? configuredSignature()
        guard let identity, !identity.name.isEmpty, !identity.email.isEmpty else { throw GitError.missingIdentity }

        let conflicts = try conflictedPaths()
        guard conflicts.isEmpty else { throw GitError.unresolvedConflicts(conflicts) }

        var parents: [OpaquePointer?] = []
        defer { parents.forEach { git_commit_free($0) } }
        if let head = try headCommit() { parents.append(head) }
        if state() == .merging {
            for oid in try mergeHeads() { parents.append(try lookupCommit(oid)) }
        }

        var treeOID = git_oid()
        try withIndex { index in
            if git_index_has_conflicts(index) == 1 { throw GitError.unresolvedConflicts(conflicts) }
            try LibGit2.check(git_index_write_tree(&treeOID, index))
        }

        // Refuse empty commits (tree identical to the only parent) unless finishing a merge.
        if parents.count == 1, let parentTree = git_commit_tree_id(parents[0]), git_oid_equal(parentTree, &treeOID) == 1 {
            throw GitError.nothingToCommit
        }
        if parents.isEmpty, try status().allSatisfy({ $0.staged == nil }) {
            throw GitError.nothingToCommit
        }

        var tree: OpaquePointer?
        try LibGit2.check(git_tree_lookup(&tree, handle, &treeOID))
        defer { git_tree_free(tree) }

        var signature: UnsafeMutablePointer<git_signature>?
        try LibGit2.check(git_signature_now(&signature, identity.name, identity.email))
        defer { git_signature_free(signature) }

        var commitOID = git_oid()
        let parentArray = CPointerArray(parents)
        try LibGit2.check(git_commit_create(
            &commitOID, handle, "HEAD", signature, signature, nil,
            trimmed + "\n", tree, parentArray.count, parentArray.pointer
        ))
        if state() != .clean {
            git_repository_state_cleanup(handle)
        }
        return commitOID.hexString
    }

    func mergeHeads() throws -> [git_oid] {
        final class Box { var oids: [git_oid] = [] }
        let box = Box()
        let code = git_repository_mergehead_foreach(handle, { oid, payload in
            guard let oid, let payload else { return 0 }
            Unmanaged<Box>.fromOpaque(payload).takeUnretainedValue().oids.append(oid.pointee)
            return 0
        }, Unmanaged.passUnretained(box).toOpaque())
        if code == GIT_ENOTFOUND.rawValue { return [] }
        try LibGit2.check(code)
        return box.oids
    }

    // MARK: - Diff

    /// Unified diff text for one path: staged (HEAD → index) or unstaged (index → working tree).
    public func diff(path: String, staged: Bool) throws -> String {
        var options = git_diff_options()
        try LibGit2.check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
        options.context_lines = 3

        let pathspec = CStringArray([path])
        options.pathspec = pathspec.array
        options.flags |= GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue

        let index = try openIndex()
        defer { git_index_free(index) }
        var diff: OpaquePointer?
        if staged {
            var headTree: OpaquePointer?
            if let head = try headCommit() {
                defer { git_commit_free(head) }
                try LibGit2.check(git_commit_tree(&headTree, head))
            }
            defer { git_tree_free(headTree) }
            try LibGit2.check(git_diff_tree_to_index(&diff, handle, headTree, index, &options))
        } else {
            try LibGit2.check(git_diff_index_to_workdir(&diff, handle, index, &options))
        }
        defer { git_diff_free(diff) }
        withExtendedLifetime(pathspec) {}

        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try LibGit2.check(git_diff_to_buf(&buffer, diff, GIT_DIFF_FORMAT_PATCH))
        guard let ptr = buffer.ptr else { return "" }
        let data = Data(bytes: ptr, count: buffer.size)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - History

    public func log(limit: Int = 200, startingAt revision: String? = nil) throws -> [CommitInfo] {
        guard git_repository_head_unborn(handle) == 0 || revision != nil else { return [] }
        var walker: OpaquePointer?
        try LibGit2.check(git_revwalk_new(&walker, handle))
        defer { git_revwalk_free(walker) }
        try LibGit2.check(git_revwalk_sorting(walker, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
        if let revision {
            try LibGit2.check(git_revwalk_push_ref(walker, revision))
        } else {
            try LibGit2.check(git_revwalk_push_head(walker))
        }

        var commits: [CommitInfo] = []
        var oid = git_oid()
        while commits.count < limit, git_revwalk_next(&oid, walker) == 0 {
            let commit = try lookupCommit(oid)
            defer { git_commit_free(commit) }
            commits.append(commitInfo(commit, id: oid))
        }
        return commits
    }

    /// Commits on the current branch that a push would send: those not on its upstream, or,
    /// if it has none yet, those not on any remote-tracking branch.
    public func outgoingCommits(limit: Int = 200) throws -> [CommitInfo] {
        guard git_repository_head_unborn(handle) == 0 else { return [] }
        var walker: OpaquePointer?
        try LibGit2.check(git_revwalk_new(&walker, handle))
        defer { git_revwalk_free(walker) }
        try LibGit2.check(git_revwalk_sorting(walker, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
        try LibGit2.check(git_revwalk_push_head(walker))

        var hidUpstream = false
        if let branch = try head().branch {
            var local: OpaquePointer?
            if git_branch_lookup(&local, handle, branch, GIT_BRANCH_LOCAL) == 0 {
                defer { git_reference_free(local) }
                var upstream: OpaquePointer?
                if git_branch_upstream(&upstream, local) == 0 {
                    defer { git_reference_free(upstream) }
                    if let target = git_reference_target(upstream) {
                        try LibGit2.check(git_revwalk_hide(walker, target))
                        hidUpstream = true
                    }
                }
            }
        }
        if !hidUpstream {
            let code = git_revwalk_hide_glob(walker, "refs/remotes/*")
            if code != GIT_ENOTFOUND.rawValue { try LibGit2.check(code) }
        }

        var commits: [CommitInfo] = []
        var oid = git_oid()
        while commits.count < limit, git_revwalk_next(&oid, walker) == 0 {
            let commit = try lookupCommit(oid)
            defer { git_commit_free(commit) }
            commits.append(commitInfo(commit, id: oid))
        }
        return commits
    }

    func commitInfo(_ commit: OpaquePointer, id: git_oid) -> CommitInfo {
        let author = git_commit_author(commit)?.pointee
        let parents = (0..<git_commit_parentcount(commit)).compactMap { git_commit_parent_id(commit, $0)?.pointee.hexString }
        return CommitInfo(
            id: id.hexString,
            summary: LibGit2.string(git_commit_summary(commit)) ?? "",
            message: LibGit2.string(git_commit_message(commit)) ?? "",
            authorName: author.flatMap { LibGit2.string($0.name) } ?? "",
            authorEmail: author.flatMap { LibGit2.string($0.email) } ?? "",
            date: Date(timeIntervalSince1970: TimeInterval(author?.when.time ?? 0)),
            parentIDs: parents
        )
    }
}
