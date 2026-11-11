import Foundation
import Testing
@testable import GitPadCore

@Suite struct RepositoryStoreTests {
    final class Fixture {
        let root: URL
        let store: RepositoryStore
        let remote: URL

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("StoreTests-\(UUID())", isDirectory: true)
            store = RepositoryStore(
                repositoriesURL: root.appendingPathComponent("Documents/Repositories"),
                stagingURL: root.appendingPathComponent("Support/IncomingClones")
            )
            try store.prepare()
            // A bare remote with one commit.
            remote = root.appendingPathComponent("remote.git")
            try GitRepository.create(at: remote, bare: true)
            let seed = try await GitRepository.clone(from: remote.path, to: root.appendingPathComponent("seed"))
            try "hi\n".write(to: seed.workingDirectory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try await seed.stageAll()
            try await seed.commit(message: "Initial", author: GitSignature(name: "T", email: "t@example.com"))
            try await seed.push()
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func cloneLandsInRepositoriesAndIsListed() async throws {
        let f = try await Fixture()
        let repo = try await f.store.clone(from: f.remote.path, name: "Project")
        #expect(repo.url.lastPathComponent == "Project")
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent(".git").path))
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("README.md").path))
        #expect(try f.store.list().map(\.name) == ["Project"])
        // Staging is cleaned up.
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.store.stagingURL.path).isEmpty)
    }

    @Test func repositoriesPersistAcrossStoreInstances() async throws {
        let f = try await Fixture()
        _ = try await f.store.clone(from: f.remote.path, name: "Keep")
        // Simulates an app restart: a new store over the same folders.
        let reopened = RepositoryStore(repositoriesURL: f.store.repositoriesURL, stagingURL: f.store.stagingURL)
        try reopened.prepare()
        let listed = try reopened.list()
        #expect(listed.map(\.name) == ["Keep"])
        let repo = try GitRepository(openingAt: listed[0].url)
        #expect(try await repo.log().count == 1)
    }

    @Test func failedCloneLeavesNothingBehind() async throws {
        let f = try await Fixture()
        await #expect(throws: (any Error).self) {
            _ = try await f.store.clone(from: f.root.appendingPathComponent("missing.git").path, name: "Broken")
        }
        #expect(try f.store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.store.repositoriesURL.appendingPathComponent("Broken").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.store.stagingURL.path).isEmpty)
    }

    @Test func cancelledCloneLeavesNothingBehind() async throws {
        let f = try await Fixture()
        let task = Task { try await f.store.clone(from: f.remote.path, name: "Cancelled") }
        task.cancel()
        _ = try? await task.value
        #expect(!FileManager.default.fileExists(atPath: f.store.repositoriesURL.appendingPathComponent("Cancelled").path))
    }

    @Test func prepareRemovesInterruptedClones() async throws {
        let f = try await Fixture()
        let leftover = f.store.stagingURL.appendingPathComponent("dead/Half")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try f.store.prepare()
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.store.stagingURL.path).isEmpty)
    }

    @Test func listIgnoresFoldersWithoutGit() async throws {
        let f = try await Fixture()
        try FileManager.default.createDirectory(at: f.store.repositoriesURL.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        _ = try await f.store.clone(from: f.remote.path, name: "Real")
        #expect(try f.store.list().map(\.name) == ["Real"])
    }

    @Test func nameValidation() async throws {
        let f = try await Fixture()
        for bad in ["", "  ", ".", "..", ".hidden", "a/b", "a:b"] {
            #expect(throws: StoreError.self) { _ = try f.store.validateNewName(bad) }
        }
        _ = try await f.store.clone(from: f.remote.path, name: "Taken")
        #expect(throws: StoreError.nameTaken("Taken")) { _ = try f.store.validateNewName("Taken") }
        #expect(try f.store.validateNewName("  Fine Name ") == "Fine Name")
    }

    @Test func suggestedNames() async throws {
        let f = try await Fixture()
        #expect(f.store.suggestedName(for: "https://github.com/apple/swift.git") == "swift")
        #expect(f.store.suggestedName(for: "https://gitlab.com/group/sub/project/") == "project")
        #expect(f.store.suggestedName(for: "git@github.com:user/repo.git") == "repo")
    }

    @Test func deleteOnlyInsideStore() async throws {
        let f = try await Fixture()
        let repo = try await f.store.clone(from: f.remote.path, name: "Gone")
        try f.store.delete(repo)
        #expect(try f.store.list().isEmpty)
        #expect(throws: StoreError.notInStore) {
            try f.store.delete(LocalRepository(url: f.root.appendingPathComponent("seed")))
        }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("seed").path))
    }
}
