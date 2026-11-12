# GitPad project rules

Native iPadOS Git client. Full brief: `~/Downloads/iPadOS_Git_Client_Claude_Prompt.md` (read it at the start of a session if you have not this conversation; it is the spec).

Other rule files in this folder, each one topic:
- `tech-stack.md`: layout, build/test commands, libgit2 wrapper rules
- `ipados-files.md`: Files app exposure, external edits, sandbox limits
- `security.md`: credentials, Keychain, redaction
- `verification.md`: how to prove something works, and `PROGRESS.md`
- `safety.md`: what is never allowed (force-push, touching other repos, deleting user data)
- `user-context.md`: who Berk is and how he wants answers

## Decisions (made by Berk, 2026-11-11)
- Minimum iPadOS 26, iPad only.
- App name **GitPad**, bundle ID `com.berkgozek.GitPad`, team `7WRYR7WZJR` ("Berk Gozek (Personal Team)", free; see the 2026-11-11 team entry below). Keep both pinned in `project.yml`: changing either makes iPadOS treat it as a new app, and deleting the old one deletes every cloned repository stored in it.
- Auth: personal access tokens for every host, plus GitHub OAuth device flow (public Client ID only; never a client secret in the app). Secrets go only in Keychain.
- Remote: push this project to `https://github.com/BerkGozek/GitPad` (`origin/main`). Never force-push.
- Live tests: a throwaway **private** GitHub repo (e.g. `gitpad-test-sandbox`) may be created with `gh`; delete it only after Berk confirms.
- 2026-11-11: **standing instruction: push regularly.** Commit and push to `origin/main` at every milestone that builds (e.g. a component compiling with its tests passing), not only at the end. Never push code that fails to compile; never force-push.
- 2026-11-11: physical test device is Berk's **iPad Air (5th gen, M1)**. It already runs iPadOS 26 and supports Stage Manager. The closest simulator is `iPad Air 11-inch (M3)`; still ask before installing on or erasing data on the real iPad (see `safety.md`).
- 2026-11-11: **signing team is `7WRYR7WZJR`, "Berk Gozek (Personal Team)"** (Berk's choice). It's what signed the copy already on his iPad. `KBT99X57V8` (copied from DailyGoals) belongs to the berk@berkgozek.com Apple ID, which isn't in Xcode. Personal Team is a *free* team: builds expire after 7 days and **TestFlight/App Store is not possible** with it. Don't use the "Freelea Corp" team in Xcode without asking.

When Berk makes a new decision, add it to this list with the date. Don't record it only in chat.
