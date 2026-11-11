# Hard limits

These don't change because a task seems to need it. If one blocks you, stop and ask.

- **Never force-push** (`--force`, `-f`, `--force-with-lease`, `+refspec`) from the CLI, and never in app code paths. A rejected push gets explained to the user and offers fetch → merge/rebase.
- **Never silently discard local changes**: no `reset --hard`, `checkout -- .`, `clean -fd`, or the libgit2 equivalents (`GIT_CHECKOUT_FORCE`) on a dirty tree unless the user explicitly confirms in the UI. Default to `GIT_CHECKOUT_SAFE`.
- Work only inside `~/Documents/GitHub/git-ios`. Other folders under `~/Documents/GitHub/` are Berk's personal repos: you may read them as reference (e.g. `general-claude-usage/apps/DailyGoals/project.yml`), but never modify them, and never run git commands that write in them.
- `~/Documents/GitHub/general-claude-usage/.claude` is read-only context. `settings.json` denies edits there; don't work around that.
- Push this repo to `origin/main` only when Berk has asked for it in the current session (or by a standing instruction recorded in `gitpad.md`). Commits are fine; pushes are outward-facing.
- Ask before: deleting the sandbox GitHub repo, changing bundle ID or team, adding a File Provider extension, adding a dependency other than libgit2, or anything involving Berk's physical iPad (installing, erasing app data).
- Don't hide failures. If a build or test fails and you move on, say so explicitly and log it in `PROGRESS.md`.
