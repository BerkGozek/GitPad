---
description: Commit the current GitPad work and push it to origin/main (never force)
allowed-tools: Bash
---

Berk running this command is the authorization to push for this run.

1. `git status --short`. Stop if any of these are staged or untracked and not gitignored: `.build/`, `DerivedData/`, `*.xcuserdata`, `.claude/settings.local.json`, or anything that looks like a secret (`*.p12`, `*.mobileprovision`, `.env`, a token string). Show what you found and ask.
2. Scan the diff for secrets: `git diff --cached; git diff | grep -nE "ghp_|github_pat_|glpat-|https://[^/ ]+:[^@ ]+@"`. If anything matches, stop.
3. Stage the changes and commit with a message that says what changed and why (`$ARGUMENTS`, if given, is the summary).
4. `git push origin main`. If it's rejected, **don't force**. Run `git fetch` and show Berk how far the branches have diverged, then ask how he wants to proceed.
5. Show `git log -1 --oneline` and `git status -sb`.
