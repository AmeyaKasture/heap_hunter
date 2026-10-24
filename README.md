# Heap Hunter

A fast, offline, memory-bounded analyzer for Java HPROF heap dumps. Implemented
as a single native binary in Zig with no JVM, no daemon, and no network
dependency.

Heap Hunter reads binary HPROF dumps (format 1.0.2), builds a persistent
on-disk heap-graph index, and answers questions about object contents,
reference paths, retention, and thread state from a single executable.
Every command emits either a human-readable tabular view, CSV, or JSON,
so output composes with `jq`, shell pipelines, and automated tooling.

## Table of contents

- [Overview](#overview)
- [Features](#features)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Sample output](#sample-output)
- [Configuration](#configuration)
- [Build options](#build-options)
- [Performance characteristics](#performance-characteristics)
- [Testing](#testing)
- [Project layout](#project-layout)
- [Contributing](#contributing)
- [License](#license)

## Overview

Traditional heap analysis tools (Eclipse MAT, VisualVM, the JDK `jhat`)
require a JVM, load the entire heap graph into memory, and depend on
remote introspection protocols. Heap Hunter is designed for environments
where none of these are available or appropriate:

- A production server with no GUI and no JVM tooling installed.
- An incident-response workstation analyzing a 20 GB dump with 16 GB of RAM.
- A CI pipeline that must diff two heap dumps and fail a build on regressions.
- An LLM agent that needs structured, machine-readable answers to
  retention questions about a heap.

The tool is built around a streaming external-sort indexer with a fixed
working-set budget, so memory consumption stays bounded regardless of
the size of the source dump.

## Features

### Indexing and persistence

- **Streaming parser** for HPROF binary dumps (format 1.0.2, both 32-bit
  and 64-bit object ids).
- **External-sort indexer** that builds an on-disk catalog, edge list,
  and CSR (compressed sparse row) graph in a single pass, with a
  configurable memory budget.
- **Fingerprint verification** that refuses to query an index built from
  a different dump.
- **Cached overview** for sub-second histogram, classes, info, and
  thread queries.

### Summary queries

- **Header and high-level summary** (`info`): id size, timestamp, total
  object / class / classloader / thread / array counts, total heap bytes.
- **Class histogram** (`histogram`): aggregate instances and shallow
  bytes per class, with regex match, exclude, and minimum-size filters.
- **Loaded classes** (`classes`): class name, superclass, instance size.
- **Thread summary** (`threads`, in the overview cache): name, state,
  priority, daemon flag, OS thread id, and Java thread id, plus a
  per-thread stack trace reconstructed from HPROF `STACK_TRACE` records.

### Object queries

- **Object listing** (`objects`): paginated list of object ids matching
  a class-name regex, with shallow size and kind (instance, object
  array, primitive array).
- **Object decoding** (`object`): full JSON view of a single object,
  including its fields (typed primitives, object references, or array
  contents) and shallow byte size.
- **Sample decoding** (`sample`): N random or ordered sample objects per
  class, fully decoded — useful for inspecting a representative slice
  of a large class without paying the cost of decoding every instance.

### Reference tracing

- **Outgoing references** (`refs-from`): every object an object points to,
  with the field/element that holds the reference.
- **Incoming references** (`refs-to`): every object that points to a
  given object, with the field/element that holds the reference.
- **Shortest path to a GC root** (`roots`): bounded BFS through the
  inbound-edge graph, returning the path from a virtual GC root to the
  target object.
- **Bounded subtree expansion** (`tree`): depth- and node-limited tree
  walk in either direction, with cycle suppression.

### Stack traces

HPROF `STACK_TRACE` records are captured during indexing and surfaced
through the overview cache. Each thread entry in the overview output
includes:

- Thread name, daemon flag, OS and JVM thread ids, and priority.
- Reconstructed Java stack frames: class name, method name, source
  file, and line number.

This makes it straightforward to identify which threads were active at
the time the dump was taken and what call sites they were executing.

### Output and automation

- **Three output modes per command**: human-readable tabular view
  (`--view`), CSV (default for histogram and classes), and JSON (default
  for object queries).
- **Streaming JSON writers** with stable field ordering, so `jq` queries
  against the output are predictable.
- **Paging support** via `--offset` and `--limit` on the list commands,
  with a `next_offset` field returned in JSON.
- **No required environment**: the binary is self-contained and has no
  JVM, GUI, or daemon dependencies.

## Installation

Heap Hunter targets Zig 0.16.0 or later. The only build-time dependency
is a Zig toolchain. Builds are supported on Linux, macOS, and Windows.

### Linux / macOS

```bash
git clone https://github.com/AmeyaKasture/heap_hunter.git
cd heap_hunter
zig build -Doptimize=ReleaseFast
```

The resulting binary is written to `zig-out/bin/hunt`. Optionally copy
it onto `$PATH`:

```bash
install -m 0755 zig-out/bin/hunt /usr/local/bin/hunt
```

### Windows

```powershell
git clone https://github.com/AmeyaKasture/heap_hunter.git
cd heap_hunter
zig build -Doptimize=ReleaseFast
```

The resulting binary is written to `zig-out\bin\hunt.exe`. Either add
`zig-out\bin` to your `PATH` or copy `hunt.exe` to a directory already on
your `PATH`.

You can also cross-compile from another OS:

```bash
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu
```

## Quick start

The typical workflow is two phases: build a persistent index, then
query it.

If you have not copied `zig-out/bin/hunt` onto your `$PATH`, replace
`hunt` below with `./zig-out/bin/hunt` (or with `./hunt` if the binary
is in the current directory).

```bash
# Phase 1: build a persistent index from a heap dump.
hunt index path/to/heap.hprof --index-dir ./idx

# Phase 2: build the overview cache (required by summary commands).
hunt overview path/to/heap.hprof --index-dir ./idx

# Phase 3: explore.
hunt info              --index-dir ./idx
hunt histogram         --index-dir ./idx --view
hunt classes           --index-dir ./idx --view
hunt objects 'com.example.*' --index-dir ./idx --limit 5
hunt object 0x3000     --index-dir ./idx
hunt sample 'java.util.HashMap\$Node' --index-dir ./idx --limit 3
hunt roots 0x3000      --index-dir ./idx
```

## Commands

### Indexing

| Command | Description |
|---------|-------------|
| `index <dump> --index-dir <dir>` | Build the persistent heap-graph index. |
| `overview <dump> --index-dir <dir>` | Build the cached overview used by summary queries. |

### Summary (require `overview`)

| Command | Description |
|---------|-------------|
| `info --index-dir <dir>` | Header and high-level summary. |
| `histogram --index-dir <dir>` | Class histogram by instance count or shallow bytes. |
| `classes --index-dir <dir>` | Loaded classes with names, superclasses, and instance sizes. |

### Object queries (require `index`)

| Command | Description |
|---------|-------------|
| `objects <class-regex> --index-dir <dir>` | List object ids matching a class regex. |
| `sample <class-regex> --index-dir <dir>` | Decode N sample objects as full JSON. |
| `object <id> --index-dir <dir>` | Decode a single object, including field values. |

### Reference tracing (require `index`)

| Command | Description |
|---------|-------------|
| `refs-from <id> --index-dir <dir>` | Outgoing references from an object. |
| `refs-to <id> --index-dir <dir>` | Incoming references to an object. |
| `roots <id> --index-dir <dir>` | Shortest path from an object to a GC root. |
| `tree <id> --index-dir <dir>` | Bounded subtree expansion from an object. |

### Common options

| Option | Applies to | Description |
|--------|------------|-------------|
| `--view` | `histogram`, `classes` | Tabular text output instead of CSV. |
| `--match <regex>` | `histogram`, `classes` | Restrict to class names matching the regex. |
| `--exclude <regex>` | `histogram`, `classes` | Exclude class names matching the regex. |
| `--min-bytes <n>` | `histogram` | Drop entries with fewer than `n` shallow bytes. |
| `--min-instances <n>` | `histogram` | Drop entries with fewer than `n` instances. |
| `--min-instance-size <n>` | `classes` | Drop classes with instance size below `n`. |
| `--sort-instances` | `histogram` | Sort by instance count instead of by bytes. |
| `--limit <n>` | list and tracing commands | Maximum items to emit. |
| `--offset <n>` | list and tracing commands | Skip the first `n` items. |
| `--reverse` | `objects`, `sample` | Emit items in reverse ordinal order. |
| `--depth <n>` | `tree` | Maximum depth of the expanded tree. |
| `--max-nodes <n>` | `tree` | Maximum number of nodes in the tree. |
| `--max-visited <n>` | `roots` | BFS visit budget for the root search. |
| `--source <path>` | query commands | Override the path to the original HPROF dump. |

Run `hunt <command> --help` for the full option list of any command.

## Sample output

### `hunt info` (plain text)

```
Header:
  id_size:    8 bytes
  timestamp:  1735689600000

Summary:
  total objects:  12,487,201
  classloaders:   347
  classes:        9,142
  arrays:         4,820,553
  threads:        118
  heap bytes:     8,419,302,144
```

### `hunt histogram --view` (tabular text)

```
Class                                               Instances        Shallow Bytes
------------------------------------------------------------------------------------------
com.example.cache.OrderEntry[]                          1,204       482,113,440
java.util.HashMap                                     18,402       212,876,448
java.lang.String                                       892,103      178,420,600
com.example.cache.OrderEntry                          182,401      131,328,720
byte[]                                              2,041,557       98,455,200
```

### `hunt histogram` (CSV, default)

```
Class,Instances,Shallow Bytes
com.example.cache.OrderEntry[],1204,482113440
java.util.HashMap,18402,212876448
java.lang.String,892103,178420600
```

### `hunt object 0x3000` (JSON)

```json
{
  "id": "0x3000",
  "ordinal": 4218,
  "class": "com.example.Order",
  "shallow_bytes": 96,
  "fields": [
    { "name": "id",      "declared_by": "java.lang.Long",   "value": 7842193 },
    { "name": "status",  "declared_by": "java.lang.String", "ref": "0x4a10", "ordinal": 7129, "class": "java.lang.String" },
    { "name": "items",   "declared_by": "com.example.Order", "ref": "0x3008", "ordinal": 4220, "class": "java.util.ArrayList" },
    { "name": "created", "declared_by": "java.time.Instant", "ref": "0x2f88", "ordinal": 4192, "class": "java.time.Instant" }
  ]
}
```

### `hunt sample 'java.util.HashMap\$Node' --limit 2` (JSON, abbreviated)

```json
{
  "pattern": "java.util.HashMap$Node",
  "limit": 2,
  "offset": 0,
  "reverse": false,
  "items": [
    {
      "id": "0x18a040",
      "ordinal": 184201,
      "class": "java.util.HashMap$Node",
      "shallow_bytes": 48,
      "fields": [
        { "name": "hash", "value": 0 },
        { "name": "key",  "ref": "0x4a10", "ordinal": 7129,  "class": "java.lang.String" },
        { "name": "value","ref": "0x9af0", "ordinal": 182004,"class": "com.example.LineItem" },
        { "name": "next", "ref": "0x18a080", "ordinal": 184220, "class": "java.util.HashMap$Node" }
      ]
    }
  ],
  "next_offset": 2
}
```

### `hunt roots 0x3000` (JSON, abbreviated)

```json
{
  "object": "0x3000",
  "ordinal": 4218,
  "found": true,
  "truncated": false,
  "path": [
    { "id": null,        "ordinal": 0,    "class": "virtual root" },
    { "id": "0x2100",    "ordinal": 182,  "class": "java.lang.Thread" },
    { "id": "0x2880",    "ordinal": 1024, "class": "java.util.concurrent.ConcurrentHashMap" },
    { "id": "0x2fc0",    "ordinal": 4088, "class": "com.example.service.OrderService" },
    { "id": "0x3000",    "ordinal": 4218, "class": "com.example.Order" }
  ]
}
```

### `hunt threads` (excerpt, includes stack traces)

```json
{
  "name": "pool-1-thread-3",
  "state": "RUNNABLE",
  "priority": 5,
  "daemon": true,
  "tid": 17,
  "virtual": false,
  "stack_frames": [
    { "class_name": "java.net.SocketInputStream",  "method": "read",      "source": "SocketInputStream.java", "line_number": 204 },
    { "class_name": "java.net.SocketInputStream",  "method": "read0",     "source": "SocketInputStream.java", "line_number": 145 },
    { "class_name": "com.example.worker.Worker",   "method": "process",   "source": "Worker.java",           "line_number": 88  }
  ]
}
```

## Configuration

Heap Hunter reads an optional JSON config file. The search order is
platform-specific:

### Linux / macOS

1. `$XDG_CONFIG_HOME/hunt/config.json`
2. `$HOME/.config/hunt/config.json`
3. `$HOME/.hunt/config.json`

### Windows

1. `%APPDATA%\hunt\config.json`
2. `%USERPROFILE%\.hunt\config.json`

```json
{
  "index-dir": "/var/lib/hunt/indexes"
}
```

When `index-dir` is a base directory, each dump gets its own subdirectory
`<base>/<stem>.idx/`. Pass `--index-dir` on any command to override it.

## Build options

| Option | Values | Description |
|--------|--------|-------------|
| `-Doptimize` | `Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall` | Standard Zig optimization modes. |
| `-Dlog-level` | `err`, `warn`, `info`, `debug` | Minimum log level. Defaults are chosen per optimize mode. |
| `-Dstack-traces` | `true`, `false` | Capture and dump error-return stack traces. |

```bash
zig build -Doptimize=ReleaseFast                              # production
zig build -Doptimize=ReleaseSafe -Dlog-level=debug -Dstack-traces=true   # diagnostics
```

## Performance characteristics

Heap Hunter is designed for multi-gigabyte production dumps. The
indexer operates in a single streaming pass with an external-sort
merge phase, so memory consumption is bounded by
`--sorting-budget-mb` (default 4 GiB) regardless of dump size.

Typical measurements on a single modern core:

- Index build throughput: 60–120 MB/s of source HPROF.
- 20 GB dump indexed end-to-end in under 3 minutes.
- Subsequent `histogram`, `classes`, and `info` queries return in
  milliseconds (served from the overview cache).
- `roots` and `tree` queries run as BFS over the CSR graph; latency
  scales with the visit budget, not the heap size.

## Testing

```bash
zig build test
```

The test suite covers the HPROF parser, every index stage, and every
query command. Most tests build synthetic HPROF dumps in memory and
exercise the full `index → overview → query` pipeline. A handful of
tests in `src/index/` and `src/tests/integration.zig` additionally
read real HPROF dumps placed under `test_hprofs/` to exercise the
end-to-end pipeline. The directory is gitignored; the file names
referenced by the tests are:

- `test_hprofs/heapforge.hprof` — mixed object, array, and root graph.
- `test_hprofs/heapforge_classloaders.hprof` — ClassLoader-heavy layout.
- `test_hprofs/heapforge_threads.hprof` — thread metadata and stacks.

## Project layout

```
src/
  main.zig              CLI entry point
  root.zig              CLI logic and command dispatch
  Cli.zig               Help generation and argument parsing
  Config.zig            User configuration
  Analysis.zig          Single-pass indexer and overview commands
  Overview.zig          Overview cache (histogram, classes, threads, stack traces)
  hprof/                HPROF binary format parser
    Header.zig          Header record
    Record.zig          Record-type dispatch
    Reader.zig          Streaming reader
    HeapDump.zig        Heap-dump segment reader
    Types.zig           Shared HPROF types
  index/                Persistent heap-graph index
    Scanner.zig         First-pass scan
    CatalogSorter.zig   External sort of the class catalog
    ExtSort.zig         External-sort driver
    EdgeEmitter.zig     Edge-list emission
    Csr.zig             CSR graph construction
    Layouts.zig         On-disk record layouts
    Join.zig            Catalog/edge/CSR join
    Preflight.zig       Pre-index validation
    Publish.zig         Index publication
    Validate.zig        Post-build validation
    Manifest.zig        Index manifest and fingerprinting
    IndexReader.zig     Query-side reader
  tests/                Synthetic HPROF builder and integration tests
    HprofBuilder.zig
    integration.zig
test_hprofs/            (gitignored) sample HPROFs used by the test suite
agent-skills/           Project-local agent skills (git-commit, pr-review)
.github/                CLA bot workflow
```

## Contributing

Bug reports, fixes, and improvements are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, code
conventions, and how to run the test suite. All contributors must
sign the [Contributor License Agreement](CLA.md) before their first
pull request can be merged; the
[CLA bot](.github/workflows/cla.yml) enforces this automatically.

## License

Heap Hunter is licensed under the
[GNU Affero General Public License v3.0](LICENSE).