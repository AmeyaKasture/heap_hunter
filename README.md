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
- [MCP server](#mcp-server)
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
- **Cached overview** for sub-second histogram, classes, and info
  queries.

### Summary queries

- **Header and high-level summary** (`info`): id size, timestamp, total
  object / class / classloader / thread / array counts, total heap bytes.
- **Class histogram** (`histogram`): aggregate instances and shallow
  bytes per class, with regex match, exclude, and minimum-size filters.
- **Loaded classes** (`classes`): class name, superclass, instance size.

### Object queries

- **Object listing** (`objects`): paginated list of object ids matching
  a class-name regex, with shallow size and kind (instance, object
  array, primitive array).
- **Object decoding** (`object`): full JSON view of a single object,
  including its fields (typed primitives with `"type"` + `"value"`, object
  references, or array contents), shallow byte size, decoded
  `java.lang.String` text, and text previews for `char[]` / `byte[]` arrays.
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

### Threads and stack traces

Thread metadata is captured during indexing and decoded on demand. The
index stores only tiny stack-trace structures (HPROF `FRAME` /
`STACK_TRACE` records and per-thread root mappings) in
`thread_traces.bin`; the `threads` command and the MCP `list_threads`
tool then decode the live `java.lang.Thread`, `Thread$FieldHolder`, and
name-`String` objects straight from the source dump. Each thread
listing includes:

- Thread name, daemon flag, OS thread id (TID), priority, and state
  (both platform and virtual-thread states).
- Reconstructed Java stack frames: class name, method name, source
  file, and line number, with `--source` falling back to the dump
  recorded in the index manifest.

This keeps the index small while still making it straightforward to
identify which threads were active at the time the dump was taken and
what call sites they were executing.

### Output and automation

- **Three output modes per command**: human-readable tabular view
  (`--view`), CSV (default for histogram and classes), and JSON (default
  for object queries).
- **Streaming JSON writers** with stable field ordering, so `jq` queries
  against the output are predictable.
- **Paging support** via `--offset` and `--limit` on the list commands,
  with a `next_offset` field returned in JSON.
- **MCP server** (`mcp`): exposes every hunt command as a Model Context
  Protocol tool over stdio, so LLM clients and agents can index dumps
  and run queries directly.
- **No required environment**: the binary is self-contained and has no
  JVM, GUI, or daemon dependencies.

## Installation

Heap Hunter targets Zig 0.16.0 or later. The only build-time dependency
is a Zig toolchain. Builds are supported on Linux, macOS, and Windows.

### Installer script

**Important:** Always review the installer script before running it. For safety, read `install.sh` (Unix-like) or `install.ps1` (Windows) to understand what it does.

#### Linux / macOS (bash)
The repository ships `install.sh` that handles the download, `$PATH` wiring and the config file in one step:

```bash
# Download the latest release binary for your platform
./install.sh

# Build from this source tree instead (requires Zig 0.16.0+)
./install.sh -l

# Remove the binary, the $PATH entry and the config file
./install.sh -u
```

Without `-l`, the script resolves the latest GitHub release, downloads the
matching asset (`heap_hunter-<os>-<arch>.tar.gz`), verifies its
SHA-256 digest against the one published with the release, and installs the
binary into `~/.local/bin` (configurable via `HEAP_HUNTER_INSTALL_DIR`).

With `-l`, the script checks that the installed Zig toolchain satisfies
`.minimum_zig_version` from `build.zig.zon`, verifies the Zig dependency
tree with `zig build --fetch`, runs a `ReleaseFast` production build and
installs the resulting binary.

The script adds the install directory to `$PATH` through
`~/.heap_hunter_env`, sourced from your shell startup file, and creates a
config file with `"index-dir": "index"` at the first location the tool
searches (`$XDG_CONFIG_HOME/hunt/config.json`, then
`$HOME/.config/hunt/config.json`). Run `source ~/.zshrc` (or your
equivalent) to pick up the new `$PATH` entry in the current shell.

#### Windows 10+ (PowerShell)
Windows 10+ has `curl.exe` and native PowerShell support. Use `install.ps1` from Command Prompt or PowerShell. 

**From Command Prompt (recommended):**
```cmd
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Local
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

**From PowerShell:**
```powershell
.\install.ps1
.\install.ps1 -Local
.\install.ps1 -Uninstall
```

The Windows installer downloads the `.zip` release asset, verifies its SHA-256 digest, extracts `hunt.exe` to `%LOCALAPPDATA%\Programs\heap-hunter\bin`, adds it to your user PATH, and creates the config at `%APPDATA%\hunt\config.json`. Open a new terminal for PATH changes to take effect.

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

**Option 1: Installer (easiest)**
Read `install.ps1` before running it. From Command Prompt (Windows 10+):
```cmd
powershell -ExecutionPolicy Bypass -File .\install.ps1
```
Or build from source: `powershell -ExecutionPolicy Bypass -File .\install.ps1 -Local` (requires Zig 0.16.0+). To uninstall: `powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall`.

**Option 2: Manual build**
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
hunt threads           --index-dir ./idx --source path/to/heap.hprof
```

## MCP server

`hunt mcp` starts a [Model Context Protocol](https://modelcontextprotocol.io)
server that exposes hunt commands as tools. The server speaks JSON-RPC 2.0
over stdin/stdout with newline-delimited messages — no sockets, no daemon —
and terminates when stdin closes. This lets coding agents and LLM clients
index dumps and query the heap graph directly from their tool loop.

### Starting the server

```bash
hunt mcp
hunt --config /path/to/config.json mcp
```

The config file's `index-dir` is used as the default base directory when
`analyze_heap_dump` is called without an explicit `index_dir` argument.

### Tools

| Tool | Description |
|------|-------------|
| `analyze_heap_dump` | Index a dump and build the overview cache. First tool to call for a new dump. |
| `heap_info` | Header and high-level summary. |
| `heap_histogram` | Class-level histogram of instance counts and shallow bytes. |
| `heap_classes` | Loaded class metadata with names, superclasses, and instance sizes. |
| `find_objects` | Object IDs whose class name matches a regex. |
| `sample_objects` | Decoded sample objects matching a class regex. |
| `get_object` | Full decode of a single object, including typed field values, decoded `java.lang.String` text, and `char[]` / `byte[]` previews. |
| `refs_from` | Outgoing references of an object. |
| `refs_to` | Incoming references of an object. |
| `list_threads` | Threads with names, states, priorities, daemon flags, and stack traces decoded on demand from the dump. |
| `find_roots` | Shortest path from an object to a GC root. |
| `reference_tree` | Bounded reference tree expansion from an object. |

### Example session

Each line below is one JSON-RPC message on stdin; responses come back
newline-delimited on stdout.

Initialize the session:

```
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
```

Response:

```
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"hunt","version":"0.1.0"}}}
```

List available tools:

```
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
```

Index a dump (first tool to call for a new dump; emits
`notifications/progress` while the index is built):

```
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"analyze_heap_dump","arguments":{"hprof_path":"/tmp/heap.hprof"}}}
```

Query the histogram:

```
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"heap_histogram","arguments":{"index_dir":"index/heap.idx","limit":10}}}
```

Tool results are returned as `text` content blocks containing JSON (matching
the corresponding CLI command's JSON output, or structured JSON equivalents for
summary and thread tools). Failures are reported with `isError: true` and a
JSON error payload inside the content block.

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

### Thread queries (require `index` + source dump)

| Command | Description |
|---------|-------------|
| `threads --index-dir <dir>` | List live threads with names, states, priorities, daemon flags, TIDs, and stack traces. Requires access to the original HPROF (pass `--source` if it moved). |

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

### Server

| Command | Description |
|---------|-------------|
| `mcp` | Run hunt as an MCP server over stdio (JSON-RPC 2.0). |

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
    { "name": "id",      "declared_by": "java.lang.Long",   "type": "long",  "value": 7842193 },
    { "name": "status",  "declared_by": "java.lang.String", "ref": "0x4a10", "ordinal": 7129, "class": "java.lang.String" },
    { "name": "items",   "declared_by": "com.example.Order", "ref": "0x3008", "ordinal": 4220, "class": "java.util.ArrayList" },
    { "name": "created", "declared_by": "java.time.Instant", "ref": "0x2f88", "ordinal": 4192, "class": "java.time.Instant" }
  ]
}
```

`java.lang.String` instances also include a `"string"` field with the decoded text, and `char[]` / `byte[]` primitive arrays include a `"preview"` field.

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

### `hunt threads` (plain text, excerpt)

```
Thread: pool-worker-1
  State:    RUNNABLE
  Priority: 5
  Daemon:   false
  TID:      42
  Stack trace:
    at java.net.SocketInputStream.read(SocketInputStream.java:204)
    at java.net.Socket$SocketInputStream.read(Socket.java:956)
    at com.example.worker.Worker.process(Worker.java:88)
```

### MCP `list_threads` (JSON, excerpt)

```json
{
  "threads": [
    {
      "id": "0x2100",
      "thread_serial": 1,
      "name": "pool-worker-1",
      "state": "RUNNABLE",
      "priority": 5,
      "daemon": false,
      "tid": 42,
      "virtual": false,
      "stack_frames": [
        { "class_name": "java.net.SocketInputStream", "method": "read", "source": "SocketInputStream.java", "line_number": 204 }
      ]
    }
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
- `threads` decodes only the live `Thread`, holder, and name-`String`
  objects on demand, so it depends on access to the source dump rather
  than the index size.

## Testing

```bash
zig build test
```

The test suite covers the HPROF parser, every index stage, and every
query command. Most tests build synthetic HPROF dumps in memory and
exercise the full `index → overview → query` pipeline. A handful of
tests in `src/index/` and `src/tests/integration.zig` additionally
read real HPROF dumps placed under `fixtures/` to exercise the
end-to-end pipeline. The directory is tracked; the file names
referenced by the tests are:

- `fixtures/heapforge.hprof` — mixed object, array, and root graph.
- `fixtures/heapforge_classloaders.hprof` — ClassLoader-heavy layout.
- `fixtures/heapforge_threads.hprof` — thread metadata and stacks.

## Project layout

```
src/
  main.zig              CLI entry point
  root.zig              CLI logic and command dispatch
  Cli.zig               Help generation and argument parsing
  Commands.zig          Command implementations shared by the CLI and MCP server
  Config.zig            User configuration
  Progress.zig          TTY progress bar and progress callbacks
  Analysis.zig          Single-pass indexer and overview commands
  Overview.zig          Overview cache (histogram, classes, info)
  Mcp.zig               MCP JSON-RPC 2.0 server over stdio
  McpTools.zig          MCP tool definitions and dispatch
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
    ThreadTraces.zig    Thread stack-trace metadata (`thread_traces.bin`)
    ThreadQuery.zig     On-demand thread/stack-trace query over the index
  tests/                Synthetic HPROF builder and integration tests
    HprofBuilder.zig
    integration.zig
fixtures/               (tracked) sample HPROFs used by the test suite
agent-skills/           Project-local agent skills (git-commit, pr-review)
install.sh              Installer script (download, local build, uninstall)
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