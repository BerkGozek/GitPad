import Foundation
import Testing
@testable import GitKit

/// A temporary folder holding a bare "remote" and any number of clones of it.
/// Everything is local (file paths), so these tests need no network.
final class Sandbox {
    let root: URL
    let remote: URL
    static let alice = GitSignature(name: "Alice", email: "alice@example.com")
    static let bob = GitSignature(name: "Bob", email: "bob@example.com")

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GitKitTests-\(UUID().uuidString)", isDirectory: true)
        remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try GitRepository.create(at: remote, bare: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func clone(_ name: String) async throws -> GitRepository {
        try await GitRepository.clone(from: remote.path, to: root.appendingPathComponent(name, isDirectory: true))
    }

    /// A clone of a remote that already has one commit on `main`.
    func seededClone(_ name: String) async throws -> GitRepository {
        let repo = try await clone(name)
        try write("README.md", "hello\n", in: repo)
        try await repo.stage(["README.md"])
        try await repo.commit(message: "Initial commit", author: Self.alice)
        try await repo.push()
        return repo
    }

    func write(_ path: String, _ text: String, in repo: GitRepository) throws {
        let url = repo.workingDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String, in repo: GitRepository) throws -> String {
        try String(contentsOf: repo.workingDirectory.appendingPathComponent(path), encoding: .utf8)
    }
}

@Suite struct LocalWorkflowTests {
    @Test func libgit2Links() {
        #expect(libgit2Version().hasPrefix("1."))
    }

    @Test func cloneEmptyRemoteThenFirstPushSetsUpstream() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.seededClone("a")
        let head = try await repo.head()
        #expect(head.branch == "main")
        let main = try await repo.branches().first { $0.name == "main" && !$0.isRemote }
        #expect(main?.upstream == "origin/main")
        #expect(main?.ahead == 0)
        #expect(main?.behind == 0)
    }

    @Test func statusStagingAndCommit() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.seededClone("a")

        try sandbox.write("README.md", "hello\nworld\n", in: repo)
        try sandbox.write("src/new.swift", "let x = 1\n", in: repo)
        var status = try await repo.status()
        #expect(status.first { $0.path == "README.md" }?.unstaged == .modified)
        #expect(status.first { $0.path == "src/new.swift" }?.unstaged == .untracked)

        try await repo.stage(["src/new.swift"])
        status = try await repo.status()
        #expect(status.first { $0.path == "src/new.swift" }?.staged == .added)
        #expect(status.first { $0.path == "README.md" }?.staged == nil)

        try await repo.unstage(["src/new.swift"])
        status = try await repo.status()
        #expect(status.first { $0.path == "src/new.swift" }?.staged == nil)
        #expect(status.first { $0.path == "src/new.swift" }?.unstaged == .untracked)
        // Unstaging never touches the file itself.
        #expect(try sandbox.read("src/new.swift", in: repo) == "let x = 1\n")

        try await repo.stageAll()
        let diff = try await repo.diff(path: "README.md", staged: true)
        #expect(diff.contains("+world"))
        let id = try await repo.commit(message: "Add world", author: Sandbox.alice)
        #expect(try await repo.status().isEmpty)
        let log = try await repo.log()
        #expect(log.first?.id == id)
        #expect(log.first?.summary == "Add world")
        #expect(log.count == 2)
    }

    @Test func stagingADeletion() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.seededClone("a")
        try FileManager.default.removeItem(at: repo.workingDirectory.appendingPathComponent("README.md"))
        #expect(try await repo.status().first?.unstaged == .deleted)
        try await repo.stage(["README.md"])
        #expect(try await repo.status().first?.staged == .deleted)
        try await repo.commit(message: "Remove readme", author: Sandbox.alice)
        #expect(try await repo.status().isEmpty)
    }

    @Test func commitRefusesEmptyAndMissingIdentity() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.seededClone("a")
        await #expect(throws: GitError.nothingToCommit) {
            try await repo.commit(message: "nothing", author: Sandbox.alice)
        }
        await #expect(throws: GitError.self) {
            try await repo.commit(message: "   ", author: Sandbox.alice)
        }
    }

    @Test func pushThenPullFastForward() async throws {
        let sandbox = try Sandbox()
        let a = try await sandbox.seededClone("a")
        let b = try await sandbox.clone("b")
        #expect(try sandbox.read("README.md", in: b) == "hello\n")

        try sandbox.write("README.md", "hello from a\n", in: a)
        try await a.stageAll()
        try await a.commit(message: "A edits", author: Sandbox.alice)
        try await a.push()

        let result = try await b.pull(author: Sandbox.bob)
        guard case .fastForwarded = result else { Issue.record("expected fast-forward, got \(result)"); return }
        #expect(try sandbox.read("README.md", in: b) == "hello from a\n")
        #expect(try await b.pull(author: Sandbox.bob) == .upToDate)
    }

    @Test func pullRefusesToOverwriteUncommittedChanges() async throws {
        let sandbox = try Sandbox()
        let a = try await sandbox.seededClone("a")
        let b = try await sandbox.clone("b")

        try sandbox.write("README.md", "remote change\n", in: a)
        try await a.stageAll()
        try await a.commit(message: "A edits", author: Sandbox.alice)
        try await a.push()

        // B has an uncommitted edit to the same file.
        try sandbox.write("README.md", "my unsaved work\n", in: b)
        await #expect(throws: GitError.self) {
            _ = try await b.pull(author: Sandbox.bob)
        }
        // The local edit is untouched and HEAD didn't move.
        #expect(try sandbox.read("README.md", in: b) == "my unsaved work\n")
        #expect(try await b.log().count == 1)
    }

    @Test func nonFastForwardPushIsRejectedNotForced() async throws {
        let sandbox = try Sandbox()
        let a = try await sandbox.seededClone("a")
        let b = try await sandbox.clone("b")

        try sandbox.write("a.txt", "a\n", in: a)
        try await a.stageAll()
        try await a.commit(message: "A", author: Sandbox.alice)
        try await a.push()

        try sandbox.write("b.txt", "b\n", in: b)
        try await b.stageAll()
        try await b.commit(message: "B", author: Sandbox.bob)
        do {
            try await b.push()
            Issue.record("push should have been rejected")
        } catch let error as GitError {
            switch error {
            case .pushRejectedNonFastForward, .pushRejected: break
            default: Issue.record("unexpected error \(error)")
            }
        }
        // The remote still has A's commit on top.
        let check = try await sandbox.clone("check")
        #expect(try await check.log().first?.summary == "A")

        // Recovery path: pull (clean merge, different files), then push succeeds.
        let result = try await b.pull(author: Sandbox.bob)
        guard case .merged = result else { Issue.record("expected merge, got \(result)"); return }
        try await b.push()
        #expect(try await b.log().first?.parentIDs.count == 2)
    }

    @Test func conflictingPullStopsWithConflictsAndCanBeResolved() async throws {
        let sandbox = try Sandbox()
        let a = try await sandbox.seededClone("a")
        let b = try await sandbox.clone("b")

        try sandbox.write("README.md", "from a\n", in: a)
        try await a.stageAll()
        try await a.commit(message: "A", author: Sandbox.alice)
        try await a.push()

        try sandbox.write("README.md", "from b\n", in: b)
        try await b.stageAll()
        try await b.commit(message: "B", author: Sandbox.bob)

        let result = try await b.pull(author: Sandbox.bob)
        #expect(result == .conflicts(["README.md"]))
        #expect(await b.state() == .merging)
        let text = try sandbox.read("README.md", in: b)
        #expect(text.contains("<<<<<<<") && text.contains("from a") && text.contains("from b"))

        // Committing before resolving is refused.
        await #expect(throws: GitError.unresolvedConflicts(["README.md"])) {
            try await b.commit(message: "Merge", author: Sandbox.bob)
        }

        // Resolve: edit, stage, commit → a merge commit with two parents.
        try sandbox.write("README.md", "from a and b\n", in: b)
        try await b.stage(["README.md"])
        try await b.commit(message: "Merge origin/main", author: Sandbox.bob)
        #expect(await b.state() == .clean)
        #expect(try await b.log().first?.parentIDs.count == 2)
        try await b.push()
    }

    @Test func abortMergeRestoresHead() async throws {
        let sandbox = try Sandbox()
        let a = try await sandbox.seededClone("a")
        let b = try await sandbox.clone("b")
        try sandbox.write("README.md", "from a\n", in: a)
        try await a.stageAll()
        try await a.commit(message: "A", author: Sandbox.alice)
        try await a.push()
        try sandbox.write("README.md", "from b\n", in: b)
        try await b.stageAll()
        try await b.commit(message: "B", author: Sandbox.bob)
        _ = try await b.pull(author: Sandbox.bob)

        try await b.abortMerge()
        #expect(await b.state() == .clean)
        #expect(try sandbox.read("README.md", in: b) == "from b\n")
        #expect(try await b.status().isEmpty)
    }

    @Test func branchesCreateSwitchAndSafety() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.seededClone("a")

        try await repo.createBranch(named: "feature")
        try await repo.checkout(branch: "feature")
        #expect(try await repo.head().branch == "feature")
        try sandbox.write("feature.txt", "f\n", in: repo)
        try await repo.stageAll()
        try await repo.commit(message: "Feature", author: Sandbox.alice)

        // Switching back removes the committed feature file (it isn't on main).
        try await repo.checkout(branch: "main")
        #expect(!FileManager.default.fileExists(atPath: repo.workingDirectory.appendingPathComponent("feature.txt").path))

        // An uncommitted edit that conflicts with the target branch blocks the switch.
        try await repo.checkout(branch: "feature")
        try sandbox.write("README.md", "feature readme\n", in: repo)
        try await repo.stageAll()
        try await repo.commit(message: "Feature readme", author: Sandbox.alice)
        try sandbox.write("README.md", "dirty\n", in: repo)
        await #expect(throws: GitError.self) {
            try await repo.checkout(branch: "main")
        }
        #expect(try await repo.head().branch == "feature")
        #expect(try sandbox.read("README.md", in: repo) == "dirty\n")

        // Unmerged branches aren't deleted without force; the current branch never is.
        await #expect(throws: GitError.self) { try await repo.deleteBranch(named: "feature") }
        #expect(try await repo.branches().contains { $0.name == "feature" })
    }

    @Test func invalidRepositoryIsReported() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-repo-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: GitError.self) { _ = try GitRepository(openingAt: folder) }
    }

    @Test func cloneOfMissingRemoteFails() async throws {
        let sandbox = try Sandbox()
        await #expect(throws: GitError.self) {
            _ = try await GitRepository.clone(from: sandbox.root.appendingPathComponent("nope.git").path,
                                              to: sandbox.root.appendingPathComponent("x"))
        }
    }
}

@Suite struct RedactorTests {
    @Test func redactsURLCredentials() {
        #expect(Redactor.redact("failed: https://bob:s3cret@github.com/x.git") == "failed: https://***@github.com/x.git")
    }

    @Test func redactsKnownTokenFormats() {
        let text = "ghp_abcdefghijklmnopqrstuvwxyz0123 github_pat_11ABCDEFG0123456789_abcdefghijkl glpat-abcdefghijklmnopqrstu ATBBabcdefghijklmnopqrstuvwxyz"
        let redacted = Redactor.redact(text)
        #expect(!redacted.contains("abcdefghijklmnopqrst"))
    }

    @Test func redactsAuthorizationHeaders() {
        #expect(Redactor.redact("Authorization: Basic dXNlcjpwYXNz") == "Authorization: ***")
        #expect(Redactor.redact("got Bearer abc.def.ghi12345") == "got Bearer ***")
    }

    @Test func redactsLiteralSecrets() {
        #expect(Redactor.redact("token was hunter2hunter2", secrets: ["hunter2hunter2"]) == "token was ***")
    }

    @Test func leavesNormalTextAlone() {
        let text = "Merge branch 'main' of https://github.com/BerkGozek/GitPad"
        #expect(Redactor.redact(text) == text)
    }
}
