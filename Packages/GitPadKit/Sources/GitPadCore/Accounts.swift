import Foundation
import GitKit
import Security

// MARK: - Providers

/// Git hosts differ in how a token is presented over HTTPS, so each gets its own defaults.
public enum HostingProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case github, gitlab, bitbucket, other

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucket: "Bitbucket"
        case .other: "Other Git Server"
        }
    }

    public var defaultHost: String {
        switch self {
        case .github: "github.com"
        case .gitlab: "gitlab.com"
        case .bitbucket: "bitbucket.org"
        case .other: ""
        }
    }

    /// The HTTPS username to send alongside a token.
    /// - GitHub: any non-empty username works with a personal access token.
    /// - GitLab: `oauth2` works with personal/project access tokens.
    /// - Bitbucket Cloud: API tokens use the fixed username `x-bitbucket-api-token-auth`.
    public var defaultUsername: String {
        switch self {
        case .github: "x-access-token"
        case .gitlab: "oauth2"
        case .bitbucket: "x-bitbucket-api-token-auth"
        case .other: ""
        }
    }

    /// Where the user creates a token.
    public func tokenCreationURL(host: String) -> URL? {
        switch self {
        case .github: URL(string: "https://\(host)/settings/personal-access-tokens/new")
        case .gitlab: URL(string: "https://\(host)/-/user_settings/personal_access_tokens")
        case .bitbucket: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")
        case .other: nil
        }
    }

    public static func guess(forHost host: String) -> HostingProvider {
        let host = host.lowercased()
        if host.contains("github") { return .github }
        if host.contains("gitlab") { return .gitlab }
        if host.contains("bitbucket") { return .bitbucket }
        return .other
    }
}

/// Non-secret account metadata. The token itself lives only in the Keychain under `id`.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: HostingProvider
    public var host: String
    /// Username sent over HTTPS with the token.
    public var username: String
    /// Shown in the UI, e.g. the GitHub login the token belongs to.
    public var displayName: String

    public init(id: UUID = UUID(), provider: HostingProvider, host: String, username: String, displayName: String) {
        self.id = id
        self.provider = provider
        self.host = host.lowercased()
        self.username = username
        self.displayName = displayName
    }

    public var label: String { "\(displayName) · \(host)" }
}

// MARK: - Secret storage

public protocol SecretStore: Sendable {
    func setSecret(_ secret: String, for id: UUID) throws
    func secret(for id: UUID) throws -> String?
    func deleteSecret(for id: UUID) throws
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// Tokens as generic passwords: only readable on this device, after its first unlock (so a
/// fetch can still run while the screen is locked), and never synced or backed up elsewhere.
public struct KeychainSecretStore: SecretStore {
    let service: String

    public init(service: String = "com.berkgozek.GitPad.token") {
        self.service = service
    }

    private func query(_ id: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        #if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public func setSecret(_ secret: String, for id: UUID) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(id) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(id)
            add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func secret(for id: UUID) throws -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func deleteSecret(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: String] = [:]

    public init() {}

    public func setSecret(_ secret: String, for id: UUID) throws { lock.withLock { secrets[id] = secret } }
    public func secret(for id: UUID) throws -> String? { lock.withLock { secrets[id] } }
    public func deleteSecret(for id: UUID) throws { _ = lock.withLock { secrets.removeValue(forKey: id) } }
    public var count: Int { lock.withLock { secrets.count } }
}

// MARK: - Account store

public enum AccountError: Error, LocalizedError, Equatable {
    case emptyToken
    case invalidHost
    case tokenRejected(String)
    case noAccount(host: String)
    case chooseAccount(host: String)

    public var errorDescription: String? {
        switch self {
        case .emptyToken: "Enter a token."
        case .invalidHost: "Enter the server's host name, e.g. git.example.com."
        case .tokenRejected(let message): "The server rejected this token. \(message)"
        case .noAccount(let host): "No account for \(host). Add one in Settings → Accounts."
        case .chooseAccount(let host): "You have several accounts for \(host). Choose one for this repository."
        }
    }
}

/// Accounts (metadata in a JSON file, tokens in a `SecretStore`) and which account each
/// repository uses. Thread-safe and synchronous, because libgit2's credential callback asks for
/// credentials synchronously on a background thread.
public final class AccountStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        var accounts: [Account] = []
        /// Repository folder name → account ID. Keyed by folder name because the app
        /// container's absolute path can change between installs.
        var repositoryAccounts: [String: UUID] = [:]
    }

    private let fileURL: URL
    private let secrets: SecretStore
    private let lock = NSLock()
    private var snapshot: Snapshot

    public init(fileURL: URL, secrets: SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
    }

    public static func live() -> AccountStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AccountStore(fileURL: support.appendingPathComponent("accounts.json"), secrets: KeychainSecretStore())
    }

    public var accounts: [Account] {
        lock.withLock { snapshot.accounts }
    }

    public func accounts(forHost host: String) -> [Account] {
        let host = host.lowercased()
        return accounts.filter { $0.host == host }
    }

    /// Saves the account and its token. The token goes only to the secret store.
    @discardableResult
    public func add(_ account: Account, token: String) throws -> Account {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AccountError.emptyToken }
        guard !account.host.isEmpty, !account.host.contains("/"), !account.host.contains(" ") else { throw AccountError.invalidHost }
        try secrets.setSecret(token, for: account.id)
        try mutate { $0.accounts.removeAll { $0.id == account.id }; $0.accounts.append(account) }
        return account
    }

    /// Removes the account, its token, and any repository assignments to it.
    public func remove(_ id: UUID) throws {
        try secrets.deleteSecret(for: id)
        try mutate { snapshot in
            snapshot.accounts.removeAll { $0.id == id }
            snapshot.repositoryAccounts = snapshot.repositoryAccounts.filter { $0.value != id }
        }
    }

    public func assign(_ accountID: UUID?, toRepository name: String) throws {
        try mutate { $0.repositoryAccounts[name] = accountID }
    }

    public func assignedAccountID(forRepository name: String) -> UUID? {
        lock.withLock { snapshot.repositoryAccounts[name] }
    }

    public func forgetRepository(_ name: String) throws {
        try mutate { $0.repositoryAccounts[name] = nil }
    }

    /// The account to use for a remote: the one assigned to the repository if it matches the
    /// host; otherwise the only account for that host. Several matches and no choice → throws
    /// `.chooseAccount` (the UI asks the user) instead of guessing.
    public func resolveAccount(forRemote remoteURL: String, repository name: String?) throws -> Account? {
        guard let host = Self.host(of: remoteURL) else { return nil }
        let candidates = accounts(forHost: host)
        if let name, let assigned = assignedAccountID(forRepository: name), let match = candidates.first(where: { $0.id == assigned }) {
            return match
        }
        switch candidates.count {
        case 0: return nil
        case 1: return candidates[0]
        default: throw AccountError.chooseAccount(host: host)
        }
    }

    /// A libgit2 credential callback that reads the token from the Keychain only when asked.
    public func credentialProvider(for account: Account) -> CredentialProvider {
        let secrets = self.secrets
        return { _, usernameFromURL in
            guard let token = try? secrets.secret(for: account.id) else { return nil }
            let username = account.username.isEmpty ? (usernameFromURL ?? "git") : account.username
            return GitCredential(username: username, password: token)
        }
    }

    public func token(for account: Account) throws -> String? {
        try secrets.secret(for: account.id)
    }

    public static func host(of remoteURL: String) -> String? {
        URL(string: remoteURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host()?.lowercased()
    }

    private func mutate(_ change: (inout Snapshot) -> Void) throws {
        try lock.withLock {
            var copy = snapshot
            change(&copy)
            let data = try JSONEncoder().encode(copy)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            snapshot = copy
        }
    }
}

// MARK: - Token check

/// Asks the provider's API who a token belongs to, so a typo is caught when the account is
/// added rather than on the first push. Only GitHub and GitLab have a simple "who am I" call.
public enum TokenValidator {
    public static func identity(provider: HostingProvider, host: String, token: String, session: URLSession = .shared) async throws -> String? {
        var request: URLRequest
        switch provider {
        case .github:
            let api = host == "github.com" ? "https://api.github.com/user" : "https://\(host)/api/v3/user"
            request = URLRequest(url: URL(string: api)!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        case .gitlab:
            request = URLRequest(url: URL(string: "https://\(host)/api/v4/user")!)
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        case .bitbucket, .other:
            return nil
        }
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AccountError.tokenRejected("HTTP \(status)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["login"] ?? json?["username"]) as? String
    }
}
