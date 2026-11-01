---
name: pr-review
description: Use ONLY when the user asks for a PR review, code review, or review of changes against the main branch. Performs an architecture-first, open-source-quality review including code correctness, tests, documentation, README freshness, and contributor hygiene.
---

# Generic PR Review against `main`

## Trigger

This skill runs when the user asks for:

- "PR review"
- "code review"
- "review these changes"
- "review against main"
- "review the PR"
- Any equivalent request that involves reviewing a branch, commit, or set of uncommitted changes.

The user may optionally provide:

- A commit hash or branch name to review. If omitted, default to the current working tree (`HEAD`).
- A base branch. If omitted, default to `main` (fall back to `master` if `main` does not exist).

## Input

- **Base branch:** `main` by default (`master` as fallback). Resolve it with `git rev-parse --abbrev-ref main` or `git symbolic-ref refs/remotes/origin/HEAD`.
- **Review target:** user-supplied commit/branch, or `HEAD` for uncommitted working-tree changes.

If the repository has no `main` or `master` branch and the user did not specify a base, report the ambiguity and stop.

## Workflow

> **Important:** This is a static code review. Do **not** run `zig build test` or any other build/test commands. Review the code purely by reading it, analyzing the logic, data flow, and architecture against the base branch and open-source quality standards.

1. **Resolve the base and target.**
   - Base: `main` (or user override).
   - Target: user-provided commit/branch, or `HEAD` for working-tree changes.
   - Use `git merge-base <base> <target>` to find the common ancestor, then `git diff --name-only <merge-base>..<target>` for the changed file list.

2. **Summarize the change.**
   - Read the commit messages between base and target: `git log --oneline <merge-base>..<target>`.
   - Note the overall purpose, number of commits, and any suspicious patterns (e.g., "WIP", "fix", "fix fix", huge binary files).

3. **Check documentation hygiene.**
   - If any of the following are changed, verify that `README.md` is updated accordingly:
     - New CLI commands, flags, or subcommands.
     - New public APIs, exported functions, or configuration options.
     - New build options, dependencies, or installation steps.
     - Behavior changes that affect the quick-start examples or sample output.
   - If `README.md` is touched, verify that the edited sections are internally consistent and match the implementation.
   - If the change adds a new user-facing feature and `README.md` is **not** updated, flag it.
   - Check for updates to `CHANGELOG.md`, `CONTRIBUTING.md`, or `AGENTS.md` if the project uses them. If `AGENTS.md` is missing and the change affects build/test/docs conventions, suggest creating or updating it.

4. **Architecture review first.**
   - Does the change introduce the right abstractions? Look for:
     - Tight coupling, leaked internals, or broken module boundaries.
     - Violations of single responsibility or inappropriate dependencies.
     - Unsafe concurrency, resource leaks, or unbounded growth.
     - API-contract violations or backward-incompatible changes without justification.
   - If any exist, output under `## Heavy Architectural Issues / Concerns` with bold red urgency.
   - Do not proceed to implementation details until the architecture is acceptable.

5. **Implementation review.**
   - Cross-reference each changed file against its purpose.
   - Look for real bugs, error-handling gaps, edge cases, off-by-one issues, null/undefined dereferences, memory leaks, and resource cleanup.
   - Check that new code has appropriate tests, examples, or documentation.
   - Verify that the change does not leave dead code, commented-out code, or debugging artifacts.

6. **Open-source quality checks.**
   - **Tests:** Are new features covered by tests? Are edge cases exercised? Are tests deterministic and self-contained?
   - **Commit hygiene:** Are commit messages clear and atomic? Is there a single logical change per commit, or are unrelated changes squashed together?
   - **Licensing:** If the project has a `LICENSE` or license headers, verify that new files include the expected header.
   - **Breaking changes:** If public behavior changed, is there a migration note, deprecation path, or version bump?
   - **Dependencies:** If new dependencies are added, are they justified, properly declared, and compatible with the project's license?
   - **Security:** Look for hard-coded secrets, unsafe input handling, injection risks, or unsafe defaults.

## Output format

For every item, produce exactly this four-part bulleted structure:

```
- **[Red|Yellow|Brown] Short Description**
  - **Short Description:** one-sentence summary of the problem or suggestion.
  - **Code Affected:** File: `<file>`, Line: `<line number>`
  - **Possible Error / Failure Case:** a concrete, real-life scenario where this issue can manifest.
  - **Proposed Change:**
    ```<language>
    <code snippet showing the fix or improvement>
    ```
```

### Sections

1. `## Summary`
   - Base branch, target commit/branch, number of files changed, and a one-paragraph summary of what the PR does.
2. `## Heavy Architectural Issues / Concerns` (if any)
3. `## README / Documentation` (if any issues or suggestions)
4. `## Possible Errors / Warnings`
5. `## Open-Source Quality Issues`
6. `## Suggestions`

### Formatting rules

- **Heavy architectural issues:** each bullet must be bold and carry red urgency: `🔴 **Heavy architectural issue: ...**`. Keep the same four-part structure.
- **Possible Errors / Warnings:** prefix with "Error" and write description in Red Colour for real bugs or
  prefix with "Warning" and write description in Yellow Colour for risky/smelly code.
- **README / Documentation:** prefix with "Docs" and write description in Brown Colour.
- **Open-source quality issues:** prefix with "Quality" and write description in Brown Colour.
- **Suggestions:** prefix with "Suggestion" and write description in Brown Colour for improvements or refactoring.
- **Code Affected** must include a real file path and a real line number from the diff or the file.
- **Proposed Change** must be a runnable code snippet inside a fenced code block, not prose.

## Example

User: "review this PR against main"

### Summary

- Base: `main` (`a1b2c3d`)
- Target: `feature/heap-indexer` (`e5f6g7h`)
- Files changed: 12
- The PR introduces a streaming external-sort indexer for HPROF heap dumps, adds a new `index` CLI command, and wires the result into a persistent on-disk catalog. It also adds unit tests for the sorter but does not update the README quick-start.

### Heavy Architectural Issues / Concerns

- 🔴 **Heavy architectural issue: Spec requires bounded merge memory, but implementation uses mmap for all runs**
  - **Short Description:** The design doc says merge memory must stay within `budget_bytes`, but `mergeRunGroup` memory-maps every run file in full, allowing merge memory to balloon to `fanout × run_size`.
  - **Code Affected:** File: `src/index/ExtSort.zig`, Line: 348-374
  - **Possible Error / Failure Case:** On a 20 GB heap dump with a 512 MB budget, runs average ~400 MB. With fanout=64, the merge would map ~25 GB of virtual memory, causing OOM or severe page-cache thrashing — directly violating the project's memory discipline.
  - **Proposed Change:**
    ```zig
    // Replace mmap merge with streaming one-record-at-a-time merge
    // or use the already-implemented sortStreaming function instead.
    ```

### README / Documentation

- **Docs: New `index` command is undocumented in README quick-start**
  - **Short Description(in brown color):** The PR adds `hunt index <dump> --index-dir <dir>` but the README quick-start still only shows querying an existing index.
  - **Code Affected:** File: `README.md`, Line: 220-244
  - **Possible Error / Failure Case:** A new contributor clones the repo, follows the README, and cannot figure out how to produce the index that every other command requires.
  - **Proposed Change:**
    ```markdown
    ```bash
    # Phase 1: build a persistent index from a heap dump.
    hunt index path/to/heap.hprof --index-dir ./idx

    # Phase 2: build the overview cache (required by summary commands).
    hunt overview path/to/heap.hprof --index-dir ./idx
    ```
    ```

### Possible Errors / Warnings

- **Error: Null pointer when `user` is missing**
  - **Short Description(in red color):** `user.name` is dereferenced without checking whether `user` exists.
  - **Code Affected:** File: `src/greeting.ts`, Line: 15
  - **Possible Error / Failure Case:** A request with an expired session sends an unauthenticated user to this endpoint, `user` is `undefined`, and the server throws a 500 instead of returning a 401.
  - **Proposed Change:**
    ```ts
    const name = user?.name ?? 'Guest';
    ```

- **Warning: Hard-coded timeout may be too short for slow networks**
  - **Short Description(in yellow color):** HTTP client uses a fixed 1-second timeout.
  - **Code Affected:** File: `src/api/client.ts`, Line: 8
  - **Possible Error / Failure Case:** A customer on a 3G connection in a rural area hits the timeout every time they try to upload a receipt, causing the app to appear broken.
  - **Proposed Change:**
    ```ts
    const client = new ApiClient({ timeoutMs: 30_000, retry: 3 });
    ```

### Open-Source Quality Issues

- **Quality: New public function lacks tests for empty input**
  - **Short Description(in brown color):** `parseHeader` returns success for a zero-byte buffer but no test covers the empty-input case.
  - **Code Affected:** File: `src/hprof/Header.zig`, Line: 42
  - **Possible Error / Failure Case:** A malformed truncated dump causes `parseHeader` to return a default header, and downstream code later crashes with a confusing error instead of failing fast.
  - **Proposed Change:**
    ```zig
    test "parseHeader rejects empty buffer" {
        var buf: [0]u8 = .{};
        try std.testing.expectError(error.TruncatedHeader, parseHeader(&buf));
    }
    ```

- **Quality: Commit messages mix unrelated changes**
  - **Short Description(in brown color):** The second commit message is "fix stuff" and touches both the indexer and the CLI parser.
  - **Code Affected:** Commit: `e5f6g7h`
  - **Possible Error / Failure Case:** Future `git bisect` runs become unreliable because a single commit both breaks and partially fixes two unrelated areas.
  - **Proposed Change:**
    ```text
    # Split into two commits:
    index: cap merge memory to budget_bytes
    cli: add --index-dir default from config file
    ```

### Suggestions

- **Suggestion: Extract the magic number into a named constant**
  - **Short Description(in brown color):** `42` is used directly without explanation.
  - **Code Affected:** File: `src/config.ts`, Line: 22
  - **Possible Error / Failure Case:** Six months from now, a developer changes one occurrence but misses another, leaving the system in an inconsistent state.
  - **Proposed Change:**
    ```ts
    const MAX_RETRY_ATTEMPTS = 42;
    ```
