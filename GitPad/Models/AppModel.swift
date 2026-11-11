import Foundation
import GitPadCore
import Observation

/// App-wide state: the list of local repositories and the selection.
@MainActor @Observable
final class AppModel {
    let store: RepositoryStore
    private(set) var repositories: [LocalRepository] = []
    var selection: LocalRepository.ID?
    var errorMessage: String?

    /// One model per opened repository, kept so switching back is instant.
    private var models: [URL: RepositoryModel] = [:]

    init(store: RepositoryStore = .live()) {
        self.store = store
        do {
            try store.prepare()
        } catch {
            errorMessage = "Couldn't prepare storage: \(Redactor.redact(error.localizedDescription))"
        }
        reloadRepositories()
    }

    func reloadRepositories() {
        do {
            repositories = try store.list()
            let urls = Set(repositories.map(\.url))
            models = models.filter { urls.contains($0.key) }
            if let selection, !urls.contains(selection) { self.selection = nil }
        } catch {
            errorMessage = Redactor.redact(error.localizedDescription)
        }
    }

    func model(for repository: LocalRepository) -> RepositoryModel {
        if let existing = models[repository.url] { return existing }
        let model = RepositoryModel(repository: repository)
        models[repository.url] = model
        return model
    }

    func delete(_ repository: LocalRepository) {
        do {
            try store.delete(repository)
            if selection == repository.id { selection = nil }
            models[repository.url] = nil
            reloadRepositories()
        } catch {
            errorMessage = Redactor.redact(error.localizedDescription)
        }
    }

    func didClone(_ repository: LocalRepository) {
        reloadRepositories()
        selection = repository.id
    }
}

/// The commit author, stored on the device (iPadOS has no global ~/.gitconfig).
enum CommitIdentity {
    static let nameKey = "commitAuthorName"
    static let emailKey = "commitAuthorEmail"

    static var current: GitSignature? {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: nameKey)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let email = defaults.string(forKey: emailKey)?.trimmingCharacters(in: .whitespaces), !email.isEmpty
        else { return nil }
        return GitSignature(name: name, email: email)
    }
}
