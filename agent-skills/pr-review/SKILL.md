---
name: pr-review
description: Use ONLY when the user asks for a PR review, code review, or review of code/commits against the indexer implementation plan at docs/indexer_plan.md. Checks for heavy architectural issues first, then implementation errors/warnings and suggestions.
---

# PR Review against docs/indexer_plan.md

## Trigger

This skill runs when the user asks for:
- "PR review"
- "review this commit"
- "code review"
- "review the implementation against the plan"
- "review commit <commit> against the indexer plan"
- Any equivalent request that involves reviewing code or a commit.

The user may optionally provide a commit hash. If not provided, default to `HEAD` (`git rev-parse HEAD`).

## Input

The spec is fixed: `docs/indexer_plan.md` in the workspace root. Do not ask for a different input file. If the file is missing, report that and stop.

## Workflow

> **Important:** This is a static code review. Do **not** run `zig build test` or any other build/test commands. Review the code purely by reading it, analyzing the logic, data flow, and architecture against the spec.

1. **Identify the commit** to review. Use the user-provided commit hash, or default to `HEAD` with `git rev-parse HEAD`.
2. **Read the spec file** `docs/indexer_plan.md` in full — it is the authoritative reference for what should be built.
3. **Get the files changed in the commit:** `git diff --name-only <commit>~1 <commit>` (or `git diff --name-only <commit>..<commit>~1`).

   If the user instead wants a review of the working tree (uncommitted changes), use `git diff --name-only` against `HEAD`. If the user asks to review "the code" without mentioning a commit, default to reviewing `HEAD` against the plan.

   For each milestone or section in the spec relevant to this commit:
   - Read the changed files that correspond to that milestone.
   - Compare the implementation against the spec's requirements, API, data formats, and engineering guidelines.

4. **Architecture review first** — does the implementation match the architectural decisions in the spec?
   - Check for deviations from the spec's design: wrong data structures, violated constraints, missing stages, incorrect interfaces.
   - Also look for general architectural issues: wrong abstraction, tight coupling, broken module boundaries, unsafe concurrency, API-contract violations,overusage of resources,wrong design patterns, wrong memoy calculation etc.
   - If any exist, output under `## Heavy Architectural Issues / Concerns` with bold red urgency.
   - Do not proceed to implementation details until the architecture is acceptable.

5. **If the architecture matches the spec, move to implementation review.**
   - Cross-reference the implementation against the spec's deliverables, tests, and engineering guidelines.
   - Output `## Possible Errors / Warnings` (label items `[Red]` or `[Yellow]`).
   - Output `## Suggestions` (label items `[Brown]`).
   - Each item should reference both the spec's requirement and the implementation gap.

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

### Formatting rules

- **Heavy architectural issues:** each bullet must be bold and carry red urgency: `🔴 **Heavy architectural issue: ...**`. Keep the same four-part structure.
- **Possible Errors / Warnings:** prefix with "Error" and write description in Red Colour for real bugs or 
prefix with "Warning" and write description in Yellow Colour for risky/smelly code.
- **Suggestions:** prefix with "Suggestion" and write description in Brown Colour for improvements or refactoring.
- **Code Affected** must include a real file path and a real line number from the diff or the file.
- **Proposed Change** must be a runnable code snippet inside a fenced code block, not prose.

## Example

User: "review commit abc123 against the indexer plan"

### Heavy Architectural Issues / Concerns

- 🔴 **Heavy architectural issue: Spec requires bounded merge memory, but implementation uses mmap for all runs**
  - **Short Description:** The plan at §M1 says merge memory must stay within `budget_bytes`, but `mergeRunGroup` memory-maps every run file in full, allowing merge memory to balloon to `fanout × run_size`.
  - **Code Affected:** File: `src/index/ExtSort.zig`, Line: 348-374
  - **Possible Error / Failure Case:** On a 20 GB heap dump with a 512 MB budget, runs average ~400 MB. With fanout=64, the merge would map ~25 GB of virtual memory, causing OOM or severe page-cache thrashing — directly violating the plan's memory discipline guideline.
  - **Proposed Change:**
    ```zig
    // Replace mmap merge with streaming one-record-at-a-time merge (as documented in extsort_algorithm.md)
    // or use the already-implemented sortStreaming function instead.
    ```

- **🔴  Spec requires `max_fanout` to handle K > 64 via multi-pass, but multi-pass path is untested and skips run-size jitter boundary**
  - **Short Description:** At fanout=64 with >64 runs, the multi-pass code (`mergeRuns` while loop) produces `.merge-{pass}-{group}` files but there is no test for the exact boundary where run count exceeds fanout, nor for the cleanup of multi-pass intermediates.
  - **Code Affected:** File: `src/index/ExtSort.zig`, Line: 252
  - **Possible Error / Failure Case:** A merge that produces exactly 65 runs (one over the fanout limit) triggers multi-pass. If a run file is read incompletely during the second pass, one or more records could be silently dropped.
  - **Proposed Change:**
    ```zig
    // Add a directed test: 65 runs, fanout=64, each run with distinct key ranges,
    // assert full output sorted and all intermediate .merge-* files cleaned up.
    ```

### Possible Errors / Warnings

- **Error : Null pointer when `user` is missing**
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

### Suggestions

- **Suggestion: Extract the magic number into a named constant**
  - **Short Description(in brown color):** `42` is used directly without explanation.
  - **Code Affected:** File: `src/config.ts`, Line: 22
  - **Possible Error / Failure Case:** Six months from now, a developer changes one occurrence but misses another, leaving the system in an inconsistent state.
  - **Proposed Change:**
    ```ts
    const MAX_RETRY_ATTEMPTS = 42;
    ```
