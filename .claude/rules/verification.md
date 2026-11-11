# Verification and progress reporting

## The rule
Something is "done" only when a command proved it, and you report what that command actually printed. "Code written" is not done. "Builds" is not "works". If you didn't run it, say "not run" and why.

## Before saying a step is done
1. `cd Packages/GitPadKit && swift test` is green.
2. If app code or `project.yml` changed: `xcodegen generate`, then the simulator `xcodebuild … test` from `tech-stack.md` is green.
3. Every new button actually does something. Never leave a placeholder action. If a feature isn't ready, hide it or disable it with a reason the user can see.
4. Update `PROGRESS.md`.

You can delegate steps 1–2 to the `verifier` agent (`.claude/agents/verifier.md`) to keep long build logs out of your own context.

## Tests
- Use temporary local repositories built in the test: create a bare "remote" with libgit2 (or CLI git in tests only) in `FileManager.default.temporaryDirectory`, clone it, edit, commit, push to it, and fetch back. This covers clone/fetch/pull/push without the network or Berk's repos.
- Cover the failure paths the brief lists: dirty tree before pull, merge conflict, rejected (non-fast-forward) push, bad credentials, cancelled clone, deleting a repo, corrupted `.git`.
- Delete temp dirs in `tearDown` / `defer`.
- Network tests against GitHub run only against the sandbox repo, only when `GITPAD_LIVE_TESTS=1`, and are skipped otherwise.

## PROGRESS.md format
Copy the layout of `~/Documents/GitHub/general-claude-usage/apps/AlphaBeta/PROGRESS.md`:
- "Last updated: YYYY-MM-DD."
- A verification table: `| Area | Command | Result |`, with ✅ / ❌ / ⏸ Not run (reason).
- "Bugs the tests caught and fixed": short list.
- A "Needs a real iPad" list: what can't be checked in the simulator.
- The current phase (1–4 from the brief) and what's next.

## Milestone updates to Berk
Short: what's done (with test results), what broke, what's next, and any question you're blocked on. Group your questions together; don't stop for things best practice already answers.
