# iPadOS sandbox and Files integration

## What iPadOS allows
- No shell, no `/usr/bin/git`, no `fork`/`exec`. Everything goes through libgit2 in-process.
- The app's `Documents/` folder shows up in Files → On My iPad → GitPad when `project.yml` sets `INFOPLIST_KEY_UIFileSharingEnabled: YES` and `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES` (same as Berk's DailyGoals app). Store clones in `Documents/Repositories/<name>/`.
- Files hides dot-folders, but `.git/` is still there and other apps can modify it. Treat `.git` as something that can be corrupted from outside: check it with libgit2 before every operation, never assume.
- The app can be suspended or killed during any network operation. Write to a temporary location and move into place when done (e.g. clone into `Repositories/.incoming/<uuid>` and rename on success). A half-finished clone must never look like a valid repository.
- Background execution is limited. Don't promise "keeps syncing in the background". Use `BGContinuedProcessingTask` (iPadOS 26) for clones/pushes the user starts, if it fits, and document what happens when it isn't granted.

## External edits
- Other apps edit files in place, either through Files or through a security-scoped URL. Detect the changes by recomputing `git status` on `scenePhase == .active` and when the repo screen appears. `NSFilePresenter` / `DispatchSource` watching is an optimization on top of that, not a replacement: neither fires while the app is suspended.
- Use `NSFileCoordinator` for reads and writes the app itself does in the working tree, so that it cooperates with editors that coordinate.
- For anything you can't verify in the simulator (third-party editors, opening a whole folder in another app), write down what is expected and mark it "needs device test" in `PROGRESS.md`. Don't claim it works.

## File Provider extension
Don't add one unless Berk agrees after you present a specific reason plain `Documents/` sharing can't cover. It adds a second process, its own sandbox and a lot of complexity.

## Simulator tips
- App data container: `xcrun simctl get_app_container booted com.berkgozek.GitPad data`. You can edit files there from macOS to simulate an external edit.
- Erasing or deleting the simulator app wipes the test repos, which is expected. Doing the same on Berk's real iPad is not acceptable without asking.
