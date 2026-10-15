---
name: git-commit
description: Use when the user asks you to stage all changes, write a commit message, and commit. Do NOT use for general git operations like push, pull, branch, or rebase.
---

# Git Commit

## Trigger

This skill runs when the user asks to:
- "commit all changes"
- "stage and commit"
- "commit everything"
- "commit my work"
- "make a commit"
- Any equivalent request to stage all changes and commit.

Do NOT trigger for push, pull, branch, rebase, stash, or other git operations.

## Workflow

1. **Stage all changes:**
   ```bash
   git add -A
   ```

2. **Get the diff for the commit message:**
   ```bash
   git diff --cached --stat
   ```
   Read the full staged diff to understand what changed. Also check `git diff --cached --name-status` for a summary of added/modified/deleted files.

3. **Write a commit message** following the repo's conventions:
   - First line: a concise imperative summary (under 72 chars, no period)
   - Blank line
   - Body: explain what and why, not how. Each line wrapped at 72 chars.
   - Use conventional commits format (`feat:`, `fix:`, `refactor:`, `chore:`, `docs:`, `test:`, etc.) if the repo uses them.

4. **Commit:**
   ```bash
   git commit -m "<message>"
   ```
   or use `git commit` with a message file if the message is long.

5. **Report the result** to the user — show the commit hash and summary.
