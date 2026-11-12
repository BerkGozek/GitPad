import Foundation
import Testing
@testable import GitPadCore

@Suite struct AccountStoreTests {
    final class Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Accounts-\(UUID())")
        let secrets = InMemorySecretStore()
        var file: URL { folder.appendingPathComponent("accounts.json") }
        lazy var store = AccountStore(fileURL: file, secrets: secrets)
        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    static func github(_ name: String) -> Account {
        Account(provider: .github, host: "github.com", username: "x-access-token", displayName: name)
    }

    @Test func tokenGoesOnlyToSecretStore() throws {
        let f = Fixture()
        let account = try f.store.add(Self.github("berk"), token: "  ghp_secretvalue123  ")
        #expect(try f.store.token(for: account) == "ghp_secretvalue123")
        let json = try String(contentsOf: f.file, encoding: .utf8)
        #expect(!json.contains("ghp_secretvalue123"))
        #expect(json.contains("berk"))
    }

    @Test func accountsPersistAcrossInstances() throws {
        let f = Fixture()
        let account = try f.store.add(Self.github("berk"), token: "t1")
        try f.store.assign(account.id, toRepository: "Repo")
        let reopened = AccountStore(fileURL: f.file, secrets: f.secrets)
        #expect(reopened.accounts == [account])
        #expect(reopened.assignedAccountID(forRepository: "Repo") == account.id)
    }

    @Test func removeDeletesTokenAndAssignments() throws {
        let f = Fixture()
        let account = try f.store.add(Self.github("berk"), token: "t1")
        try f.store.assign(account.id, toRepository: "Repo")
        try f.store.remove(account.id)
        #expect(f.store.accounts.isEmpty)
        #expect(f.secrets.count == 0)
        #expect(f.store.assignedAccountID(forRepository: "Repo") == nil)
    }

    @Test func emptyTokenAndBadHostRejected() throws {
        let f = Fixture()
        #expect(throws: AccountError.emptyToken) { try f.store.add(Self.github("a"), token: "   ") }
        let bad = Account(provider: .other, host: "https://x/y", username: "u", displayName: "d")
        #expect(throws: AccountError.invalidHost) { try f.store.add(bad, token: "t") }
    }

    @Test func resolvesByHostAndNeverGuessesBetweenSeveral() throws {
        let f = Fixture()
        #expect(try f.store.resolveAccount(forRemote: "https://github.com/a/b.git", repository: "b") == nil)

        let personal = try f.store.add(Self.github("personal"), token: "t1")
        let gitlab = try f.store.add(Account(provider: .gitlab, host: "gitlab.com", username: "oauth2", displayName: "gl"), token: "t2")
        #expect(try f.store.resolveAccount(forRemote: "https://github.com/a/b.git", repository: "b") == personal)
        #expect(try f.store.resolveAccount(forRemote: "https://GitLab.com/a/b", repository: nil) == gitlab)

        let work = try f.store.add(Self.github("work"), token: "t3")
        #expect(throws: AccountError.chooseAccount(host: "github.com")) {
            _ = try f.store.resolveAccount(forRemote: "https://github.com/a/b.git", repository: "b")
        }
        try f.store.assign(work.id, toRepository: "b")
        #expect(try f.store.resolveAccount(forRemote: "https://github.com/a/b.git", repository: "b") == work)
    }

    @Test func credentialProviderReadsTokenLazily() throws {
        let f = Fixture()
        let account = try f.store.add(Self.github("berk"), token: "first")
        let provider = f.store.credentialProvider(for: account)
        try f.secrets.setSecret("rotated", for: account.id)
        #expect(provider("https://github.com/a/b", nil) == GitCredential(username: "x-access-token", password: "rotated"))
        try f.store.remove(account.id)
        #expect(provider("https://github.com/a/b", nil) == nil)
    }

    @Test func tokenIsNeverGivenToAnotherHost() throws {
        let f = Fixture()
        let account = try f.store.add(Self.github("berk"), token: "secret")
        let provider = f.store.credentialProvider(for: account)
        #expect(provider("https://github.com/a/b.git", nil)?.password == "secret")
        // e.g. a redirect from github.com to somewhere else
        #expect(provider("https://evil.example.com/a/b.git", nil) == nil)
        #expect(provider("https://github.com.evil.example.com/a/b.git", nil) == nil)
        #expect(provider("not a url", nil) == nil)
    }

    @Test func providerDefaults() {
        #expect(HostingProvider.guess(forHost: "gitlab.example.com") == .gitlab)
        #expect(HostingProvider.guess(forHost: "github.com") == .github)
        #expect(HostingProvider.bitbucket.defaultUsername == "x-bitbucket-api-token-auth")
        #expect(AccountStore.host(of: "https://GitHub.com/a/b.git") == "github.com")
    }
}

@Suite struct OutgoingCommitsTests {
    @Test func listsCommitsNotOnUpstream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Outgoing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git")
        try GitRepository.create(at: remote, bare: true)
        let repo = try await GitRepository.clone(from: remote.path, to: root.appendingPathComponent("a"))
        let me = GitSignature(name: "T", email: "t@example.com")

        func commit(_ name: String) async throws {
            try name.write(to: repo.workingDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try await repo.stageAll()
            try await repo.commit(message: name, author: me)
        }

        try await commit("one")
        // No upstream yet: everything not on a remote branch is outgoing.
        #expect(try await repo.outgoingCommits().map(\.summary) == ["one"])
        try await repo.push()
        #expect(try await repo.outgoingCommits().isEmpty)
        try await commit("two")
        try await commit("three")
        #expect(try await repo.outgoingCommits().map(\.summary) == ["three", "two"])
    }
}
