---
description: Run every GitPad build/test suite and update PROGRESS.md with the real results
allowed-tools: Bash, Read, Edit, Agent
---

1. Use the `verifier` agent to run all suites (the package tests, xcodegen, the simulator tests).
2. Show Berk its report as-is: ✅/❌/⏸ per suite, with the counts.
3. Update the verification table in `PROGRESS.md` (format in `.claude/rules/verification.md`). Replace the rows for suites that just ran and set "Last updated" to today's date.
4. If something failed, list the failures and propose a fix, but don't apply it unless `$ARGUMENTS` contains `fix`.
