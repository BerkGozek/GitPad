# Tech stack and commands

## Layout
- `Packages/GitPadKit/`: local Swift package. All logic that can be tested on macOS lives here.
  - `GitKit`: thin Swift wrapper over libgit2. It is the only target that does `import libgit2`.
  - `GitPadCore`: repository storage, auth/account service, view models' domain logic. Depends on GitKit, never on SwiftUI.
- `GitPad/` (app target, created from `project.yml`): SwiftUI views and the app entry point only.
- `project.yml`: XcodeGen spec. **The `.xcodeproj` is generated, so never hand-edit it.** Change `project.yml`, then run `xcodegen generate`.
- `PROGRESS.md`, `README.md`: deliverables (see `verification.md`).

The `.build/` folder is SwiftPM's cache (gitignored). Never read or grep inside it; libgit2's checkout there is huge and will flood your context.

## Toolchain (checked 2026-11-11)
- Xcode 26.6, Swift 6 language mode, XcodeGen and `gh` from Homebrew.
- Simulators: `iPad Pro 11-inch (M5)` is the default test destination. Run `xcrun simctl list devices available | grep iPad` if it is missing.

## Commands
```sh
# Fast loop (macOS, seconds): run after every change to GitPadKit
cd Packages/GitPadKit && swift build && swift test

# Regenerate the Xcode project after editing project.yml or adding/removing app files
xcodegen generate

# App build + tests on the simulator
xcodebuild -project GitPad.xcodeproj -scheme GitPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test 2>&1 | tail -60

# Device build (signing check, no install)
xcodebuild -project GitPad.xcodeproj -scheme GitPad -destination 'generic/platform=iOS' build
```
Pipe `xcodebuild` output through `tail` or `grep -E "error:|warning:|Test Suite|passed|failed"`. The full log will eat your context. When something fails, re-run and grep around the first `error:` instead of reading the whole log.

## libgit2 wrapper rules (GitKit)
- Call `git_libgit2_init()` once per process, not once per call (`Probe.swift` currently does it per call: fine for a smoke test, not for real code).
- Every `git_*` object you get back must be freed exactly once. Wrap each in a Swift class whose `deinit` frees it, or free it with `defer` right after you create it.
- libgit2 repository handles are not safe to share across threads. Make each open repository an `actor` (or confine it to one serial executor). Never pass raw `OpaquePointer`s out of GitKit.
- Convert every negative return code to a typed Swift error using `git_error_last()`. Run the message through redaction (see `security.md`) before it reaches UI or logs.
- Long operations (clone/fetch/push) report progress through libgit2 callbacks and must support cancellation: return a non-zero value from the callback when the Swift `Task` is cancelled.
- Never shell out to `/usr/bin/git` inside the app. It doesn't exist on iPadOS. Using CLI git in *tests* only to build or inspect fixtures is fine.
- Don't write Git internals (packfiles, index format, merge) by hand. If libgit2 can't do it, say so.

## Architecture
MVVM: SwiftUI views → `@Observable` view models (in the app or in GitPadCore) → services (`GitService`, `RepositoryStore`, `AuthService`) → GitKit. Use protocols only at service boundaries where tests need a fake; don't add a protocol in front of every type.
