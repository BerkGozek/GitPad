import Foundation
import libgit2

/// State shared between a Swift async operation and libgit2's C callbacks.
///
/// libgit2 calls back synchronously on the thread running the operation; the only value
/// touched from another thread is the cancellation flag (set by `withTaskCancellationHandler`),
/// which is lock-protected.
final class OperationContext: @unchecked Sendable {
    let credentials: CredentialProvider?
    let progress: ProgressHandler?

    private let lock = NSLock()
    private var cancelled = false

    /// libgit2 calls the credential callback again after the server rejects credentials.
    /// We answer once per URL and then give up, instead of looping forever.
    private var credentialAttempts = 0
    private(set) var authenticationGaveUp = false
    private(set) var rejectedRefs: [String: String] = [:]
    private var lastReported: (phase: TransferProgress.Phase, completed: Int)?
    private var secretsInUse: [String] = []

    init(credentials: CredentialProvider? = nil, progress: ProgressHandler? = nil) {
        self.credentials = credentials
        self.progress = progress
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var opaque: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func from(_ payload: UnsafeMutableRawPointer?) -> OperationContext? {
        payload.map { Unmanaged<OperationContext>.fromOpaque($0).takeUnretainedValue() }
    }

    // MARK: - Callback bodies

    fileprivate func acquireCredential(
        _ out: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
        url: String,
        usernameFromURL: String?,
        allowedTypes: UInt32
    ) -> Int32 {
        if isCancelled { return GIT_EUSER.rawValue }
        guard allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else {
            // SSH-only remote (not supported in v1).
            authenticationGaveUp = true
            return GIT_EUSER.rawValue
        }
        credentialAttempts += 1
        guard credentialAttempts == 1, let credential = credentials?(url, usernameFromURL) else {
            authenticationGaveUp = true
            return GIT_EUSER.rawValue
        }
        secretsInUse.append(credential.password)
        return git_credential_userpass_plaintext_new(out, credential.username, credential.password)
    }

    fileprivate func report(_ progress: TransferProgress) -> Int32 {
        if isCancelled { return GIT_EUSER.rawValue }
        guard let handler = self.progress else { return 0 }
        // Throttle: report phase changes, completion, and roughly every 1%.
        let step = max(1, progress.total / 100)
        if let last = lastReported, last.phase == progress.phase,
           progress.completed - last.completed < step, progress.completed < progress.total {
            return 0
        }
        lastReported = (progress.phase, progress.completed)
        handler(progress)
        return 0
    }

    fileprivate func recordRejection(ref: String, status: String) {
        rejectedRefs[ref] = Redactor.redact(status, secrets: secretsInUse)
    }

    // MARK: - Installing callbacks

    func install(into callbacks: inout git_remote_callbacks) {
        callbacks.payload = opaque
        callbacks.credentials = { out, url, usernameFromURL, allowedTypes, payload in
            guard let context = OperationContext.from(payload) else { return GIT_EUSER.rawValue }
            return context.acquireCredential(
                out,
                url: LibGit2.string(url) ?? "",
                usernameFromURL: LibGit2.string(usernameFromURL),
                allowedTypes: allowedTypes
            )
        }
        callbacks.transfer_progress = { stats, payload in
            guard let context = OperationContext.from(payload), let stats = stats?.pointee else { return 0 }
            let receiving = stats.received_objects < stats.total_objects
            return context.report(TransferProgress(
                phase: receiving ? .receiving : .resolving,
                completed: Int(receiving ? stats.received_objects : stats.indexed_deltas),
                total: Int(receiving ? stats.total_objects : stats.total_deltas),
                bytes: Int(stats.received_bytes)
            ))
        }
        callbacks.sideband_progress = { _, _, payload in
            // Server messages ("Counting objects…"): only used as a cancellation point.
            (OperationContext.from(payload)?.isCancelled ?? false) ? GIT_EUSER.rawValue : 0
        }
        callbacks.push_transfer_progress = { current, total, bytes, payload in
            guard let context = OperationContext.from(payload) else { return 0 }
            return context.report(TransferProgress(phase: .uploading, completed: Int(current), total: Int(total), bytes: bytes))
        }
        callbacks.push_update_reference = { refname, status, payload in
            if let status, let context = OperationContext.from(payload) {
                context.recordRejection(ref: LibGit2.string(refname) ?? "?", status: String(cString: status))
            }
            return 0
        }
    }

    func install(into checkout: inout git_checkout_options) {
        checkout.progress_payload = opaque
        checkout.progress_cb = { _, completed, total, payload in
            guard let context = OperationContext.from(payload) else { return }
            _ = context.report(TransferProgress(phase: .checkingOut, completed: completed, total: total, bytes: 0))
        }
    }
}
