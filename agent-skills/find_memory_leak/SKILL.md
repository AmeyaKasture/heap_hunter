---
name: findmemoryleak
description: Use ONLY when the user asks to find a memory leak, analyse a Java heap dump for growth, or work out what is holding memory. Drives the `hunt` CLI end to end — class histogram, candidate objects, reference tracing, dominator tree and retained sizes — against an already-indexed dump whose index location comes from the config file. Not about the HPROF file format or the index internals.
---

# Find a memory leak with `hunt`

## Trigger

This skill runs when the user asks to:
- "find the memory leak in this heap dump"
- "analyse this dump for leaks"
- "what is holding memory in this heap?"
- "which class is growing?"
- "why is this object still in memory?"
- Any equivalent request that involves diagnosing memory growth from a Java heap dump.

## Scope

**In scope:** the operational workflow for using the `hunt` CLI to find a leak, and how to
report what the evidence shows.

**Out of scope:** the HPROF binary format, the on-disk index formats, the indexer's
internal stages. Do not parse dump bytes and do not read the tool's source to answer a
question — every question below is answered by running `hunt`.

## Preconditions

This skill assumes the dump is **already indexed** and that the index location comes
from the config file. Do not re-index, and do not pass `--index-dir`.

The index must have been built **with dominators** (the default for `hunt index`; only
`--no-dominators` skips them). If `hunt dominator` reports that the index was built
without dominators, you cannot re-index under this skill — fall back to `hunt roots` and
report the retained size as unknown.

Because of that, **every query command takes the dump path as a positional argument**.
Passing the dump tells the tool which `.idx` directory under the base to use; omitting it
makes the tool look for an index directly inside the base directory, which fails.

```bash
hunt info    <hprof file mentioned by user>          # good     
hunt object   0x3f2a1c00 <hprof file mentioned by user>  # good
hunt info    <hprof file mentioned by user>
```

The dump path may appear before or after the other positional argument — the tool
classifies a positional ending in `.hprof` as the dump and anything else as the id or
the class pattern.

| Command | Form |
| --- | --- |
| `info`, `histogram`, `classes` | `hunt <cmd> <dump.hprof> [options]` |
| `objects`, `sample` | `hunt <cmd> '<class-regex>' <dump.hprof> [options]` |
| `object`, `refs-from`, `refs-to`, `roots`, `tree`, `dominator`, `dominator-tree` | `hunt <cmd> <object-id> <dump.hprof> [options]` |

`dominator` and `dominator-tree` take only `--index-dir` and `--source`. They have no
`--max-visited`, `--depth`, or `--max-nodes` flags — the dominator chain is computed
eagerly at index time, so a lookup is a constant-time read (measured at ~30 ms on a
12.7 M-object heap).

To point at a different config for one run, use `--config <file>` **before** the
command:

```bash
hunt --config /etc/heaphunt/config.json info /dumps/heap.hprof
```

### Tool check

```bash
hunt --version          # must print "hunt version 0.1.0"
```

If `hunt` is not installed, from the repository root: `./install.sh` (downloads the
release) or `./install.sh -l` (builds from source, needs Zig 0.16+).

### Two-dump setups need no extra configuration

Because the index directory is derived from the dump name, one config holds many
dumps side by side:

```
/var/tmp/heaphunt/before.idx/     <- hunt index before.hprof
/var/tmp/heaphunt/after.idx/      <- hunt index after.hprof
```

Query each one by passing its own dump path.

## Workflow

> **The two-phase rule:** `hunt index` builds the queryable index; `hunt overview` builds
> the cache that the summary commands read. If the summary commands report a missing
> overview cache, run `hunt overview <dump.hprof>` once — the index alone is enough for
> the object and reference commands.

### Phase 1 — Baseline: what does this heap look like?

```bash
hunt info /dumps/heap.hprof
```

```
Header:
  id_size:    8 bytes
  timestamp:  1783429843270

Summary:
  total objects:  169,033
  classloaders:   4
  classes:        1,844
  arrays:         67,091
  threads:        0
  heap bytes:     10,137,438
```

Note `heap bytes` — that is the *shallow* total. Every number the tool reports is a
shallow size unless the command name says otherwise.

**Retained size IS available.** Use `hunt dominator` / `hunt dominator-tree` to answer
"how much does this object hold?" — see Phase 6. The index must have been built with
dominators (the default); if it was not, the query fails with
`error: index was built without dominators; re-index with dominators enabled`.

### Phase 2 — Shortlist suspects at class level

```bash
hunt histogram /dumps/heap.hprof --min-bytes 100000
```

CSV output, sorted by shallow bytes descending:

```
Class,Instances,Shallow Bytes
byte[],45970,5776794
java.util.HashMap$Node[],5336,690624
java.lang.Object[],7203,673952
java.lang.String,40864,572096
java.util.HashMap$Node,16406,459368
```

Useful flags:

| Flag | Effect |
| --- | --- |
| `--min-bytes N` | Drop classes below N bytes of total shallow size — cuts the noise. |
| `--min-instances N` | Drop classes below N instances — finds *many small objects* rather than a few big ones. |
| `--sort-instances` | Sort by instance count instead of bytes (finds collection leaks). |
| `--view` | Human-readable table instead of CSV. |
| `--match REGEX` / `--exclude REGEX` | Restrict the class set. |

`hunt classes /dumps/heap.hprof --view` lists loaded classes with their superclass and
instance size — use it when you suspect a specific class and need its instance size to
estimate the cost of one more instance.

**Leak heuristics to apply here:**

- A class with a huge instance count of a small object (`HashMap$Node`, `WeakReference`,
  `WeakHashMap$Entry`, `lambda$...`) is a collection leak.
- A class with a huge byte total in `byte[]` is a buffer leak (a growing cache, an
  unbounded log buffer, a repeated `StringBuilder`).
- A class whose count is high *and* whose instance size is large is a retention leak.

### Phase 3 — Pull concrete objects

```bash
hunt objects 'java\.util\.HashMap\$Node' /dumps/heap.hprof --limit 20
```

```json
{"pattern":"java\\.util\\.HashMap\\$Node","limit":20,"offset":0,"reverse":false,
 "items":[{"id":"0x0000000708800840","ordinal":58,"class":"java/util/HashMap$Node",
 "kind":"instance","shallow_bytes":28}, ...],"next_offset":20}
```

Pattern rules (verified):

- The pattern is matched against the **slashed** class name, but an escaped dot `\.` is
  rewritten to match `/`, `\` or `.` — so `java\.lang\.String` and `java.lang.String`
  both work.
- The match is a **substring** search unless the pattern starts with `^`.
- `--limit` (default 100) and `--offset` page through the result set; `next_offset` in
  the response is the offset to pass next. `--reverse` walks the ordinals backwards,
  which is a cheap way to sample the *end* of the heap.

Use `hunt sample '<regex>' <dump.hprof> --limit N` instead when you need the **field
values** of the matching objects — it decodes them fully:

```bash
hunt sample 'java\.util\.HashMap\$Node' /dumps/heap.hprof --limit 1
```

### Phase 4 — Decode one suspect

```bash
hunt object 0x0000000708800840 /dumps/heap.hprof
```

```json
{"id":"0x0000000708800840","ordinal":58,"class":"java/util/HashMap$Node",
 "shallow_bytes":28,
 "fields":[{"name":"hash","value":-1681299965},
           {"name":"key","ref":"0x00000007088007d8","ordinal":54,"class":"java/lang/String"},
           {"name":"value","ref":"0x0000000708800808","ordinal":56,
            "class":"com/sun/management/internal/DiagnosticCommandImpl$Wrapper"},
           {"name":"next"}]}
```

Read this as: *this node's `value` field points at a `DiagnosticCommandImpl$Wrapper`*.
That is the lead — follow the field, not the class.

Note that class names in JSON output are **slashed** (`java/util/HashMap$Node`) while
`hunt classes --view` prints them **dotted** (`java.util.HashMap$Node`).

### Phase 5 — Who points at it?

```bash
hunt refs-to 0x0000000708800840 /dumps/heap.hprof --limit 20
```

```json
{"object":"0x0000000708800840","direction":"inbound",
 "items":[{"id":"0x0000000708803d78","ordinal":358,
           "class":"[Ljava/util/HashMap$Node;","relation":"[3]"}],
 "next_offset":null}
```

`relation` tells you *which field or array slot* holds the reference — `[3]` means
element 3 of an object array. This is the single most useful command for leaks: it
names the exact field that is holding the object.

```bash
hunt refs-from 0x0000000708800840 /dumps/heap.hprof --limit 20
```

```json
{"object":"0x0000000708800840","direction":"outbound",
 "items":[{"id":"0x00000007088007d8","ordinal":54,"class":"java/lang/String","relation":"key"},
          {"id":"0x0000000708800808","ordinal":56,
           "class":"com/sun/management/internal/DiagnosticCommandImpl$Wrapper",
           "relation":"value"}],"next_offset":null}
```

`refs-from` is the outgoing side — use it to see what a container is holding.

### Phase 6 — Why is it still alive?

```bash
hunt roots 0x0000000708800840 /dumps/heap.hprof
```

```json
{"object":"0x0000000708800840","ordinal":58,"found":true,"truncated":false,
 "path":[{"id":null,"ordinal":170877,"class":"virtual root"},
         {"id":"0x0000000708803f88","ordinal":359,"class":"java/util/Collections$UnmodifiableMap"},
         {"id":"0x0000000708c2c430","ordinal":57734,"class":"java/util/HashMap"},
         {"id":"0x0000000708803d78","ordinal":358,"class":"[Ljava/util/HashMap$Node;"},
         {"id":"0x0000000708800840","ordinal":58,"class":"java/util/HashMap$Node"}]}
```

The path runs from the **virtual root** (which represents all GC roots) down to the
object. Read it bottom-up: this node is reachable through
`Collections$UnmodifiableMap → HashMap → [Ljava/util/HashMap$Node; → the node`.

Interpretation rules:

- `found: false` → the object is **not reachable from any GC root**. It is unreachable
  garbage: the dump caught it mid-collection, or it is genuinely leaked in a way the
  collector cannot see. Either way it is not the leak you are looking for.
- `truncated: true` → the search hit `--max-visited` (default 1,000,000). Raise it with
  `--max-visited 5000000`.
- This is **one** path found by BFS, not proof of what retains the object. An object with
  several referrers has several root paths, and BFS returns an arbitrary one. Use
  **Phase 6b** (`hunt dominator-tree`) for the *unique* unavoidable holder and the
  retained size.

For the shape of the subgraph below an object:

```bash
hunt tree 0x0000000708800840 /dumps/heap.hprof --depth 2 --max-nodes 20
```

```json
{"root":{"id":"0x0000000708800840","ordinal":58,"class":"java/util/HashMap$Node",
 "children":[{"id":"0x00000007088007d8","ordinal":54,"class":"java/lang/String",
              "children":[...]}]},"nodes_used":5}
```

`tree` expands **outgoing** references by default; `--direction to` expands incoming
ones. `"marker":"repeat"` marks an object already shown; `"marker":"truncated"` marks
where `--max-nodes` cut the expansion.

### Phase 6b — Who actually *holds* the memory? (dominator + retained size)

This is the phase that turns "this class is big" into "this object is what is keeping
it alive". Run it on the suspect object from Phase 3–5.

```bash
hunt dominator 0x0000000708800840 /dumps/heap.hprof
```

```json
{"id":"0x0000000708800840","ordinal":58,
 "dominator":"0x0000000708803d78","retained_bytes":4134}
```

- `dominator` — the **immediate dominator**: the nearest object whose removal would make
  the target unreachable. Every path from a GC root to the target goes through it.
- `retained_bytes` — how many bytes would be freed if this object became garbage. This
  is the number that quantifies the leak.

For the whole chain up to the top of the reachable graph:

```bash
hunt dominator-tree 0x0000000708800840 /dumps/heap.hprof
```

```json
{"id":"0x0000000708800840","ordinal":58,
 "path":[{"ordinal":58,"id":"0x0000000708800840","retained_bytes":4134},
         {"ordinal":358,"id":"0x0000000708803d78","retained_bytes":8402},
         {"ordinal":359,"id":"0x0000000708803f88","retained_bytes":4195549725}]}
```

The path runs **bottom-up**: the object first, then its immediate dominator, and so on
to the top of the reachable graph. Each step is the unique unavoidable holder.

**Interpretation rules (all verified):**

- **`dominator: null` means top-of-the-reachable-graph, not "unreachable".** The chain
  ends at a real object (often the `ClassLoader` or a `Thread`), not at the synthetic
  virtual root. The virtual root is a construct of the tool, so it never appears as a
  node with a retained size.
- **Unreachable objects also report `dominator: null`**, but with `retained_bytes` equal
  to their own shallow size and a **one-node** `dominator-tree` path. Distinguish the two
  cases by the tree length: `path` with a single element ⇒ unreachable garbage; a long
  `path` ending in a `null` dominator ⇒ top of the reachable graph.
- **`retained_bytes` is non-decreasing** as you walk up the chain. If you ever see a
  parent with a *smaller* retained size than its child, the dominator data is corrupt.
- **`retained_bytes` ≥ `shallow_bytes`** always.
- **`dominator` is `null` and `retained_bytes` is `0` for class objects and other
  zero-length placeholders** (e.g. a `[B` class object with `shallow_bytes: 0`).

**How to use it — the dominant-retainer technique:**

Run `hunt dominator-tree` on the *container* you suspect (not the leaf) and read the
retained sizes off the chain. The node with the large jump in retained size is the
culprit. A real example from a 7.6 GB heap:

```
ProductView (994,709 instances)     retained           4,134
  → ConcurrentHashMap$Node           retained           8,402
  → ConcurrentHashMap$Node[]         retained   4,195,549,725   <- the 16 MB table holding 4.19 GB
  → ConcurrentHashMap                retained   4,195,549,841
  → ProductCache                     retained   4,195,550,930   <- the cache entry that owns it
  → Object[]                         retained   5,828,368,763
  → ArrayList                        retained   5,828,368,779
  → AppClassLoader                   retained   5,828,392,925   <- top of the reachable graph
```

The huge jump at `ConcurrentHashMap$Node[]` and the fact that `ProductCache` retains
4.19 GB proves the cache entry is what holds the memory — something the histogram
cannot show you.

**Cross-check the dominator against `refs-to` before trusting it.** If an object has
several referrers, only one of them can dominate it. Example: `ProductCache` had two
referrers — `Object[][2]` (its dominator) and `MemberName.clazz` (a non-dominating
referrer). `hunt dominator-tree` on the `MemberName` showed a *different* branch that
reconverges on `ProductCache`. If a referrer appears in `refs-to` but does **not** appear
in the dominator chain of the target, it does not dominate it — the object is reachable
by more than one route.

### Phase 7 — Prove the growth (needs two dumps)

One dump tells you what is big. Two dumps tell you what is *leaking*. Both dumps are
already indexed; query each one with its own path:

```bash
hunt histogram /dumps/before.hprof > /tmp/before.csv
hunt histogram /dumps/after.hprof  > /tmp/after.csv
```

```bash
python3 - <<'PY'
import csv
def load(p):
    with open(p) as f:
        return {r["Class"]: (int(r["Instances"]), int(r["Shallow Bytes"]))
                for r in csv.DictReader(f)}
b, a = load("/tmp/before.csv"), load("/tmp/after.csv")
rows = []
for k in set(b) | set(a):
    bi, bb = b.get(k, (0, 0)); ai, ab = a.get(k, (0, 0))
    rows.append((ab - bb, ai - bi, k, bi, ai))
rows.sort(reverse=True)
print(f"{'class':52} {'d_inst':>8} {'d_bytes':>12}  before->after")
for dbytes, dinst, k, bi, ai in rows[:15]:
    if dinst > 0:
        print(f"{k:52} {dinst:+8d} {dbytes:+12d}  {bi}->{ai}")
PY
```

```
class                                                d_inst      d_bytes  before->after
com.sun.tools.javac.util.SharedNameTable$NameImpl     +3554       +85296  0->3554
java.lang.invoke.MemberName                            +999       +43956  0->999
java.lang.reflect.Method                               +167       +21710  659->826
java.util.concurrent.ConcurrentHashMap$Node[]           +89       -9984  49->138
```

The class with the largest growth is the suspect. Then go back to Phase 3–6b **in the
newer dump** and find the objects of that class and trace who holds them.

Run the dominator phase on the container you suspect to size the damage:

```bash
hunt dominator-tree <container-id> /dumps/after.hprof
```

A growing class whose dominator retains most of the heap is an unbounded cache. A
growing class whose dominator retains only its own subtree is a per-request object
that is being dropped somewhere it should not be.

Sort by instance count instead when the leak is many small objects rather than a few
large ones:

```bash
hunt histogram /dumps/heap.hprof --sort-instances --min-instances 100
```

## Output format

Report in this order, with the evidence attached to each claim:

```
## Verdict
<one sentence: the class and the field that is leaking, or "no leak found">

## Evidence
- Growth: <class> +N instances (+M bytes) between <before> and <after>   [histogram diff]
- Instances: <count> × <shallow size> bytes                                [histogram]
- Holder: <id> <class>.<field> -> <id> <class>                            [refs-to]
- Retained: <id> <class> retains N bytes (dominator <id> <class>)         [dominator]
- Path to GC root: virtual root -> ... -> <id>                            [roots]

## Suspect
<class>: <why this class leaks, e.g. "instances are added to a static map and never evicted">

## Next steps
<what to change, or what to capture next>
```

Rules:
- **Quote retained sizes verbatim from `hunt dominator`.** A retained size is a real,
  tool-computed number — cite the command that produced it. Do not estimate it from
  instance counts.
- **Always cite the command** that produced each number.
- **Distinguish "big" from "leaking".** Without two dumps, say the class *dominates the
  heap*, not that it *is leaking*. Retained size shows what is *held*, not what is
  *growing* — only the two-dump diff proves growth.
- If the object is unreachable (`found: false`), say so — it changes the conclusion.
- **Name the dominant retainer, not just the class.** "The heap is dominated by
  `byte[]`" is weaker than "`ProductCache` retains 4.19 GB through one
  `ConcurrentHashMap`". The first names a symptom; the second names a fix.

## Pitfalls

Verified error messages and what they mean:

| Message | Cause | Fix |
| --- | --- | --- |
| `error: failed to read manifest: FileNotFound` | The dump path was omitted, so the tool looked for an index directly inside the config's base directory | Pass the dump path: `hunt info heap.hprof` |
| `error: overview cache not found; run 'hunt overview <file.hprof> ...'` | Summary command without the overview cache | Run `hunt overview <dump.hprof>` once |
| `error: object id not found in index: 0x...` | The id is not in this dump | Copy the id from a `hunt objects` / `hunt sample` result — never retype it |
| `error: index was built without dominators; re-index with dominators enabled` | The index was built with `--no-dominators` | Re-run `hunt index <dump.hprof>` without `--no-dominators` (or use `hunt roots` instead) |
| `error: invalid value '42a003088' for option '<id>': expected an object id such as 0x3000` | The id was passed without the `0x` prefix | Prefix with `0x` — `0x42a003088`. `0X` and zero-padded forms are also accepted |
| `error: source file not found` / fingerprint mismatch | The dump moved or changed | Pass `--source /new/path.hprof` to the query command |
| `error: failed to open index: FileNotFound` | No index for that dump | Run `hunt index <dump.hprof>` |
| `no configuration file found` + the sample config | No `index-dir` configured | Create `~/.config/hunt/config.json` with an `index-dir` |
| `hunt objects` returns zero items | The regex does not match | Use `\.` for package separators, or `^` to anchor; check the class name with `hunt classes --view` |
| `hunt roots` says `truncated: true` | BFS budget hit | `--max-visited 5000000` |
| `hunt tree` stops early | `--max-nodes` hit (default 256) | `--max-nodes 1000 --depth 4` |

Other traps:

- **One config, many dumps.** The index directory is derived from the dump file name, so
  the same `index-dir` base holds `before.idx/` and `after.idx/` side by side. Do not
  copy a dump into a different filename and expect the old index to be found — the
  derived path changes with the name.
- **`hunt index` is reusable.** If the dump has not changed it prints
  `{"status":"reused",...}` and does nothing. That is not an error.
- **Progress output goes to stderr.** The JSON payload is on stdout, so
  `hunt objects ... | jq` works even though the progress bar is being printed.
- **`hunt info` counts objects, not bytes.** `total objects` excludes the arrays counted
  separately in `arrays`.
- **A `null` dominator is ambiguous — always check the `dominator-tree` length.** It
  means either "top of the reachable graph" or "unreachable garbage". A one-node `path`
  means unreachable; a multi-node `path` ending in a `null` dominator means the top of
  the reachable graph.
- **The dominator chain does not end at the virtual root.** The virtual root is
  synthetic; the chain tops out at a real object (usually a `ClassLoader` or a
  `Thread`). Do not expect a `virtual root` node in `dominator-tree` output.
- **Retained sizes cover only the reachable graph.** Objects the collector considers
  unreachable get `retained_bytes` equal to their own shallow size. The index manifest
  reports the count under `diagnostics.unreachable_objects`; on a real dump this can be
  in the millions, so the sum of retained sizes is *less* than the total heap.
- **Dominator queries need an index built with dominators.** `hunt index` computes them
  by default; `--no-dominators` skips the stage and deletes `dom_parent.bin`,
  `dom_order.bin`, and `retained.bin`. The stage is bounded by
  `--dominator-budget-mb` (default 4096) and fails with a user error if it cannot fit.
- **`hunt dominator` and `hunt dominator-tree` have no `--max-visited`/`--depth`
  flags.** A lookup is a constant-time read, so there is nothing to tune. Use
  `hunt tree` for bounded graph expansion.

## Example

```
User: "our checkout service is leaking memory, here's before.hprof and after.hprof"
      (both already indexed; config index-dir = /var/tmp/heaphunt)

Phase 1  hunt info after.hprof
        -> total objects: 169033, heap bytes: 10137438

Phase 2  hunt histogram after.hprof --min-instances 100
        -> com.shop.checkout.CartSnapshot dominates

Phase 3  hunt objects 'com\.shop\.checkout\.CartSnapshot' after.hprof --limit 3
        -> 0x0000000708800840, ordinal 58, shallow_bytes 120

Phase 4  hunt object 0x0000000708800840 after.hprof
        -> fields: cartId, items (ref), expiresAt

Phase 5  hunt refs-to 0x0000000708800840 after.hprof
        -> relation "snapshot" on com.shop.checkout.CheckoutSession

Phase 6  hunt roots 0x0000000708800840 after.hprof
        -> virtual root -> com.shop.checkout.SessionRegistry -> CheckoutSession -> CartSnapshot
        -> found: true

Phase 6b hunt dominator 0x0000000708800840 after.hprof
        -> dominator 0x0000000708803d78, retained_bytes 4134
        hunt dominator-tree 0x0000000708800840 after.hprof
        -> CartSnapshot 4,134 -> SessionRegistry 8,402 -> AppClassLoader 5,828,392,925
        (the registry entry retains the whole heap; that is the fix target)

Phase 7  hunt histogram before.hprof > /tmp/before.csv
        hunt histogram after.hprof  > /tmp/after.csv
        -> com.shop.checkout.CartSnapshot  +12000 instances (+1440000 bytes)  0->12000
        -> java.util.HashMap$Node          +48000 instances (+1344000 bytes)  1200->49200

Verdict: CartSnapshot instances are stored in the static SessionRegistry map and never
evicted; the registry grows by 12,000 instances (1.44 MB) between the two dumps, and
every snapshot is reachable from the static registry.
```
