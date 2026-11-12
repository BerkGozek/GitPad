# Development progress

Last updated: 2026-11-11.

Current phase: **3 (Remote Sync)**, code complete; waiting on a check on the real iPad.
Next: on-device check of accounts + push, then Phase 4 (GitHub sign-in via device flow once a Client ID exists, README, UI tests, polish).

## Verification summary

| Area | Command | Result |
|---|---|---|
| Git engine + storage + accounts (macOS) | `swift test --package-path Packages/GitPadKit` | ✅ 35/35: clone, status, stage/unstage (incl. deletions), commit, diff, log, branches (create/switch/delete, safe checkout), fetch, fast-forward pull, pull refusing to overwrite local edits, non-fast-forward push rejected (not forced) then pull+push recovery, conflict → resolve → merge commit, abort merge, invalid repo, missing remote, outgoing commits, redaction, repository store (staging, cancel/fail leave nothing, persistence, name validation, safe delete), account store (token only in secret store, persistence, removal, host matching, refuses to guess between several accounts, lazy token read) |
| Live HTTPS against GitHub | `GITPAD_LIVE_TESTS=1 GITPAD_TEST_REPO=… GITPAD_TEST_TOKEN=… swift test --filter LiveGitHubTests` | ✅ 1/1 against private sandbox `BerkGozek/gitpad-test-sandbox`: anonymous clone → auth error; wrong token → auth error with the token not in the message; private clone, commit, push, pull in a second clone; token not in `.git/config` |
| App build (simulator) | `xcodebuild -scheme GitPad -destination 'generic/platform=iOS Simulator' build` | ✅ no errors, no warnings (Swift 6) |
| App launch (simulator) | `simctl install` + `launch` + screenshot | ✅ launches to the empty state (Phase 1 build) |
| App UI tests (simulator, iPad Pro 11" M5, iOS 26.5) | `xcodebuild -scheme GitPad -destination 'id=<sim>' test` | ✅ 1/1: Settings → Add Account → type token → change service → form stays open → Cancel back to Settings |
| Device build (command line) | `xcodebuild -destination generic/platform=iOS` | ❌ "No Accounts" in Xcode for the CLI; building from the Xcode app works (Berk installed it on the iPad) |

## Verified on Berk's iPad Air (5th gen, iPadOS 26)
- Phase 1 build installed from Xcode; cloned `BerkGozek/Testing-Repository` over HTTPS ✅
- Repositories did **not** appear in Files ❌ → fixed (see below), needs re-check.

## Bugs caught and fixed
- Add Account closed itself (and Settings) right after opening, found by Berk on the iPad. The sheet was attached to a Form section inside the Settings sheet; SwiftUI tears such sections down on re-render. Now presented from the Settings screen; reproduced and verified with a UI test.
- `INFOPLIST_KEY_UIFileSharingEnabled` was silently dropped from the generated Info.plist, so the app's folder never showed in Files → On My iPad. Both Files keys now live in `GitPad/Info.plist`; verified in the built app's Info.plist.
- Xcode showed "Missing package product 'GitPadCore'" after the package had been opened in a separate window; fixed by restarting Xcode (stale package graph, project was fine).

## Needs a real iPad
- Repos visible in Files after the Info.plist fix.
- Editing a repo file in another app, returning, seeing it in Changes.
- Adding an account (Keychain on device), pushing to `Testing-Repository`.
- Opening a whole repository folder in third-party editors (expected to work for editors that support folders via Files; not verified).
