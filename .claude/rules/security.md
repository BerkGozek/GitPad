# Credentials and security

- Tokens live only in Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), keyed by account ID. Store only non-secret metadata (host, username, account display name) in SwiftData.
- Never put a token in a remote URL, `.git/config`, UserDefaults, a log line, an error message, a test fixture, or a commit. Hand credentials to libgit2 only inside its credential callback.
- Redaction: one function in GitPadCore (e.g. `Redactor.redact(_:)`) that strips `https://user:token@`, `ghp_…`, `github_pat_…`, `glpat-…`, Bitbucket app passwords, and `Authorization:` headers. Every error shown to the user or logged goes through it. Write tests for it.
- GitHub OAuth device flow needs only the public Client ID. If you need one, **ask Berk** to register the OAuth app and give you the Client ID. Never invent one and never ask for a client secret.
- Multiple accounts per host must work: pick the credential by remote host and the account the user chose for that repo, not "the first token we have".
- Never ask Berk to paste a real token into chat or into a source file. For live tests, read it from the environment or Keychain at test time (e.g. `GITPAD_TEST_TOKEN`, set in his shell; `gh auth token` is fine for the sandbox repo) and skip the test with a clear message when it isn't set.
- No private APIs, no jailbreak-only features, no server we would have to keep running.
