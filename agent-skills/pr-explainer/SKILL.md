---
name: pr-explainer
description: Use ONLY when the user asks to explain a PR, document what a PR does, write a PR summary/overview, or produce a "what was before and what is now" write-up for a branch or commit. Produces a single Markdown document under test_hprofs/ that explains the PR holistically — which area of the codebase it touches, the before/now behaviour, and explanatory diagrams of the workflow backed by real command output from the actual fixtures in fixtures/.
---

# Explain a PR holistically

## Trigger

This skill runs when the user asks to:

- "explain this PR"
- "document what this PR does"
- "write up this PR"
- "what did this PR change?"
- "explain the before and after of this PR"
- "make a PR overview / summary doc"
- Any equivalent request to produce a narrative document about a branch, a
  commit, or a set of commits.

Do **not** trigger for:

- PR *reviews* (use `pr-review` — that skill reports issues, not explanations).
- Committing changes (use `git-commit`).
- Analysing a heap dump for leaks (use `findmemoryleak`).

## Output location

The document goes under `test_hprofs/`, next to the existing `test_hprofs/planning/`
directory. Use a descriptive kebab-case filename:

```
test_hprofs/pr-<branch-or-short-topic>.md
```

If a document for that PR already exists, **update it in place** rather than
creating a second file. Do not leave two documents describing the same PR.

## Input

- **Target:** the branch, commit, or PR the user means. Resolve it in this order:
  1. an explicit branch/commit/PR reference in the user's message;
  2. `origin/experimental/*` branches, if exactly one exists and the user said
     "the PR" without naming it;
  3. otherwise ask which one — do not guess.
- **Base:** `main` by default. Fall back to `master` if `main` does not exist.

Resolve both with:

```bash
git rev-parse --verify main
git merge-base main <target>
git diff --name-only main...<target>
```

Use the **three-dot** diff (`main...<target>`) — it compares against the merge
base, so unrelated commits that landed on `main` after the branch started are
not attributed to the PR.

## Workflow

> **The grounding rule:** every factual claim in the document must come from
> one of three sources — the diff itself, the source files at the target commit,
> or **real command output captured from the actual fixtures in `fixtures/`**.
> Never invent a JSON payload, a byte count, or a command output. If you cannot
> run the tool, say so in the document rather than fabricating numbers.

1. **Inventory the change.**
   ```bash
   git log --oneline main..<target>
   git diff --stat main...<target>
   git diff --name-only main...<target>
   ```
   Group the changed files into *areas* (e.g. "index build pipeline", "query
   commands", "MCP surface", "on-disk format", "tests"). The document is
   organised by area, not by file.

2. **Read the diff in full.** For each changed file, read the post-change
   version at the target commit:
   ```bash
   git show <target>:src/<new-module>.zig
   git diff main...<target> -- src/root.zig
   ```
   Understand what the code *does*, not just which lines changed. Note new
   public functions, new CLI commands, new MCP tools, new index files, new
   config keys, and new manifest fields.

3. **Establish the "before" state.** Read the base version of the same files to
   state precisely what existed before. Use `git show main:<path>`. The
   "before" column of every before/now table must be verifiable in the base
   commit.

   Build the before/now comparison from **four lenses**, so the document
   answers "what changed" from every angle a reader cares about:

   | Lens | Question it answers | Where it goes in the doc |
   | --- | --- | --- |
   | **Capability** | What can the tool now answer that it could not before? | Section 1 |
   | **Pipeline** | Which build/query stages were added, removed, or reordered? | Sections 2–4 (before/after diagrams) |
   | **On-disk format** | Did the index layout change? New files? New manifest fields? | Section 6 |
   | **User surface** | New commands, flags, MCP tools, JSON fields, error messages? | Sections 7–8 |

   For each row of the before/now table, the "before" cell must be checkable
   in `main` and the "now" cell checkable at the target commit.

4. **Capture real output from the fixtures.**
   This is the part that makes the document useful rather than generic.

   ```bash
   # The tool under test — build FROM THE TARGET COMMIT, not from main.
   # An installed `hunt` on PATH may be an older build; check it first.
   git worktree add /tmp/pr-doc-worktree <target>
   cd /tmp/pr-doc-worktree && zig build -Doptimize=ReleaseFast
   # then use ./zig-out/bin/hunt for every command below

   # The fixture dumps live in fixtures/.
   ls -la fixtures/*.hprof

   # Index a fixture into a scratch directory (never into the repo's index/).
   ./zig-out/bin/hunt index fixtures/heapforge.hprof --index-dir /tmp/pr-doc-idx

   # Then run the commands the PR touches and capture stdout verbatim.
   ./zig-out/bin/hunt info    fixtures/heapforge.hprof
   ./zig-out/bin/hunt object  0x... fixtures/heapforge.hprof
   ./zig-out/bin/hunt <command-the-pr-adds> 0x... fixtures/heapforge.hprof
   ```

   > **Only run commands that exist at the target commit.** A command the PR
   > *introduces* does not exist on the base, so it cannot be captured from a
   > `main` build. If you cannot build the target commit, do **not** show
   > output for a command you did not run — describe the command's effect
   > from the code and say the output was not captured against a running
   > build.

   Rules for captured output:
   - Use the **smallest** fixture that demonstrates the behaviour. Prefer
     `heapforge.hprof` (16.8 MB) over the 7.9 GB `shop.hprof`.
   - Prefer the **`--view` / CSV** forms when they are more readable, and show
     the JSON when the PR is about JSON output.
   - Use real object ids taken from the dump (`hunt objects '<regex>' ...`),
     never invented ones.
   - Keep each captured block short — trim long arrays to the first few entries
     and mark the elision with `…` so the shape stays obvious.
   - If the target commit does not build, or a command fails, capture the
     failure verbatim and label it. A documented failure is honest; a
     fabricated success is not.

5. **Add explanatory diagrams.** The diagrams exist to **explain the
   workflow**, not to decorate the page. A reader who only looks at the
   diagrams should come away understanding what the PR does.

   The test for every diagram: **"what does this diagram tell me that the
   prose does not?"** If the answer is "nothing", cut it.

   What makes a diagram *explanatory* rather than decorative:
   - It shows the **flow of data and control** between the steps the PR
     touches, with the *shape* of the data named on the edge.
   - Add a simple e
   - It highlights **where the PR's change sits** in that flow, so the reader
     can see the blast radius at a glance.
   - It contrasts the flow **before** and **after**, making the difference
     visible rather than asserted.
   - It is paired with a **caption** saying what to look at, so the reader
     does not have to reverse-engineer the intended point.

   Diagram rules:
   - Use **Mermaid** so the diagrams render on GitHub and in most Markdown
     viewers. Pick the form that fits: a flowchart for a pipeline or data
     flow, a sequence diagram for a request/response interaction, a
     class diagram for a data-model change.
   - Label every node with the **real** identifier from the code — the actual
     file name, the actual function name, the actual data file name. A
     diagram full of generic box names explains nothing.
   - Name the **data that flows** on the edges, not just the boxes.
   - Mark the PR's new or changed steps visually, and say in the caption what
     the marker means.
   - Include a **before** diagram alongside the **after** one whenever the PR
     changes a flow, so the reader sees the shape change rather than reading
     about it.
   - Keep each diagram small enough to read at a glance — roughly twenty
     nodes. Split a large flow across two diagrams rather than drawing one
     unreadable one.
   - Every diagram must be **checkable against the code**. Trace the actual
     call chain before drawing. If you are unsure how two steps connect, read
     the caller — a diagram that contradicts the code is worse than no
     diagram.
   - **Do not invent a diagram the PR does not need.** If the PR adds a
     single field, one small diagram explaining where that field is produced
     and consumed is right; three diagrams are not.

6. **Write the document.** Use the structure in "Document structure" below.

7. **Verify the document.** Before declaring it done:
   - Every command in the document is one you actually ran (or that the
     existing README documents as supported).
   - Every file path referenced exists at the target commit.
   - Every line number you cite matches the file at the target commit.
   - Every diagram block parses (check the diagram keyword casing, and that
     node ids do not contain unescaped `-` or spaces).
   - Every diagram agrees with the code — re-trace the flow against the
     target commit before finishing.
   - Every diagram has a caption that says what the reader should take from
     it.
   - No placeholder text remains (`TODO`, `TBD`, `...` used as fake data).
   - **Grep for accidental placeholders:**
     ```bash
     grep -nE 'TODO|TBD|FIXME|<placeholder>|XXX' test_hprofs/pr-*.md
     ```

## Document structure

Use these sections. Skip a section only when it genuinely does not apply, and
say so in one line rather than leaving it out silently.

```markdown
# <PR title> — <one-line summary>

> **PR:** <branch / commit range>
> **Base:** `main` @ `<short-sha>` ("<subject>")
> **Target:** `<branch>` @ `<short-sha>` ("<subject>")
> **Files changed:** <N> across <area list>
> **Status:** <merged / open / draft>

---

## Table of contents
- [1. What this PR does](#1-what-this-pr-does)
- [2. Which area of the codebase it touches](#2-which-area-of-the-codebase-it-touches)
- [3. Before and now](#3-before-and-now)
- [4. How it works](#4-how-it-works)
- [5. Real output from the fixtures](#5-real-output-from-the-fixtures)
- [6. Data on disk](#6-data-on-disk)
- [7. User-facing surface](#7-user-facing-surface)
- [8. Edge cases and error handling](#8-edge-cases-and-error-handling)
- [9. Tests](#9-tests)
- [10. Limitations and follow-ups](#10-limitations-and-follow-ups)

---

## 1. What this PR does

<3–6 sentences. Plain language. State the capability that did not exist before
and does exist now. No jargon before the reader has the context.>

## 2. Which area of the codebase it touches

<Group the changed files into areas. This section answers "where in the
codebase does this PR live?" — the reader should be able to navigate to the
right directory from this table alone.>

| Area | Files | What changed there |
| --- | --- | --- |
| <Area 1> | `<path/one.zig>`, `<path/two.zig>` | <What changed, in one line> |
| <Area 2> | `<path/three.zig>` | <What changed, in one line> |

<Then the "after" diagram of the main flow, with a caption saying what to
look at.>

## 3. Before and now

<A before/after table, one row per user-visible behaviour.>

| Question | Before | Now |
| --- | --- | --- |
| <What a user could ask before> | <What happened before> | <What happens now> |

<Then the "before" diagram, so the shape change is visible rather than
asserted.>

## 4. How it works

<The core mechanism, explained with a diagram that shows the flow of data and
control. Walk through the concrete data with real values — not abstractions.>

## 5. Real output from the fixtures

<Captured command output, verbatim, with the command shown above it.>

**Each example must carry real values.** A block that only shows the *shape*
of the output teaches the reader nothing. Include the actual numbers, the
actual class names, and the actual object ids:

```console
$ ./zig-out/bin/hunt objects 'java\.util\.HashMap\$Node' fixtures/heapforge.hprof --limit 3
{"pattern":"java\\.util\\.HashMap\\$Node","limit":3,"offset":0,"reverse":false,
 "items":[{"id":"0x0000000708800840","ordinal":58,"class":"java/util/HashMap$Node",
 "kind":"instance","shallow_bytes":28},
 {"id":"0x00000007088007d8","ordinal":54,"class":"java/lang/String",
 "kind":"instance","shallow_bytes":24}],
 "next_offset":3}
```

Not this — a shape with no real values:

```json
{"items": [{"id": "0x1234", "class": "com.example.Foo", "shallow_bytes": 42}]}
```

## 6. Data on disk

<New/changed data files, metadata fields, config keys — as tables with real
byte sizes measured from the built output.>

```console
$ ls -l /tmp/pr-doc-idx/
-rw-r--r--  1 user  staff  2613732 Nov  7 13:20 <new-file>.bin
-rw-r--r--  1 user  staff   681280 Nov  7 13:20 <other-file>.bin
```

## 7. User-facing surface

<New CLI commands, flags, MCP tools, JSON fields. Show a JSON sample that was
actually produced.>

## 8. Edge cases and error handling

<Table: Situation | Behaviour | Error message.>

## 9. Tests

<Table: Test | What it proves. Point at the file and test name.>

## 10. Limitations and follow-ups

<What this PR does NOT do. Be explicit — this is the section readers trust
most.>
```

## Writing rules

- **Lead with the "why", then the "what".** A reader should get the point in
  the first paragraph and be able to stop there.
- **Explain terms before using them.** If the PR involves a concept a
  newcomer would not know, define it in one sentence the first time it
  appears. Link to the relevant planning document in `test_hprofs/planning/` if
  one exists.
- **Use real names.** Real class names (`java.util.HashMap$Node`), real file
  names (`src/index/Scanner.zig`), real function names
  (`Decoder.decodeStringBacking`). No `Foo`, `Bar`, `someClass`.
- **Show the actual numbers.** Real object counts, real byte totals, real
  timings — measured from the fixtures, not estimated.
- **Be explicit about what did not change.** A PR that changes the query path
  but not the stored format should say exactly that.
- **Mark uncertainty explicitly.** If something is inferred rather than
  verified, write "inferred from `<file>:<line>`" or "not verified against a
  running build".
- **Do not editorialise about quality.** The document explains the PR. If you
  spot a problem, put it in "Limitations and follow-ups" with the concrete
  failure case — do not turn the document into a review.

## Realistic example

The example below is deliberately about a *different* feature area from the
one the skill happens to be used on. The point is the **shape** of the
document: a reader who only reads the diagrams and the first paragraph
should still come away understanding the whole workflow.

User: "explain the PR that adds the new index stage"

```
Target: origin/feature/new-stage (2 commits)
Base:   main @ 3fc91cd
Areas:  index build pipeline, stored format, query commands, MCP surface

## 1. What this PR does

Before this PR, `hunt` could answer questions about the objects in a dump but
not about the threads that were running when it was taken. Thread names,
states and stack traces were collected during indexing and then thrown away,
so the information existed only in the source file and never reached the
user.

This PR keeps that information in the index and decodes it on demand, adding
a `threads` command and a `list_threads` MCP tool. The thread objects
themselves are still read from the dump at query time, so the index stays
small.

## 2. Which area of the codebase it touches

| Area | Files | What changed there |
| --- | --- | --- |
| Index build pipeline | `src/index/Scanner.zig` | Captures frame and trace records while walking the dump |
| Stored format | `src/index/ThreadTraces.zig` | New file defining the on-disk layout for thread metadata |
| Query commands | `src/index/ThreadQuery.zig`, `src/root.zig` | Joins stored metadata with the live objects in the dump |
| MCP surface | `src/McpTools.zig` | New `list_threads` tool |

<after diagram: the flow from the dump through the index to the query>

## 3. Before and now

| Question | Before | Now |
| --- | --- | --- |
| Which threads were running? | Not answerable from the index | `hunt threads` lists name, state, priority, daemon flag, TID |
| What was a thread doing? | Not answerable | Stack frames are decoded per thread |
| Can an agent ask the same thing? | No | `list_threads` MCP tool |

<before diagram: the same flow with the thread data discarded>
```

Note what the example does **not** contain: no invented JSON payload, no
estimated byte counts, no diagram that was not traced against the code, and
no conclusion the diff does not support.

## Pitfalls

| Pitfall | Consequence | Avoid |
| --- | --- | --- |
| Writing the document from the commit message alone | The doc restates the subject line and teaches nothing | Read the diff and the post-change files |
| Inventing JSON payloads for readability | The document lies about the tool's actual output | Capture real output, elide with `…` |
| Using `git diff main..<target>` | Attributes unrelated `main` commits to the PR | Use `main...<target>` (three dots) |
| Diagramming from imagination | The diagram contradicts the code | Trace the actual call chain |
| Diagrams that restate the prose | The reader learns nothing and the page gets longer | Ask what the diagram tells the reader that the text does not; cut it if the answer is "nothing" |
| Drawing a diagram with generic box names | It explains no actual mechanism | Label every node with the real file, function, or data file name |
| Adding a diagram for its own sake | The document becomes decorative | Only diagram the flows the PR actually changes |
| Documenting one commit when the branch has four | The doc misses most of the PR | Use the whole `main..<target>` range |
| Writing to `test_hprofs/planning/` | Conflates a PR explanation with a design proposal | Write to `test_hprofs/pr-<topic>.md` |
| Citing line numbers from the wrong revision | Readers cannot find the code | Cite line numbers at the **target** commit |
| Leaving `TODO` / `TBD` in the doc | The document ships unfinished | Grep for placeholders before finishing |
