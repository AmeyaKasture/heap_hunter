# Heap Hunter

An offline Java HPROF heap dump analyzer written in Zig. Fast, memory-efficient,
and built for automation.

Heap Hunter parses binary HPROF heap dumps (format 1.0.2), builds a persistent
on-disk heap-graph index, and answers questions about what is in your heap and
what is keeping it alive — all from a single native binary with no JVM, no
daemon, and no network.

```
$ hunt index heap.hprof --index-dir ./idx
$ hunt histogram heap.hprof --view --match 'com.example.*'
$ hunt roots 0x3000 --index-dir ./idx
```

## Why Heap Hunter

Analyzing a 2–20 GB heap dump with Eclipse MAT or VisualVM means loading the
whole graph into a JVM and waiting. Heap Hunter memory-maps the dump and streams
through it with a bounded memory budget, so a laptop can index a multi-gigabyte
heap without running out of RAM.

- **Single native binary** — no runtime, fast startup, trivially scriptable.
- **Bounded memory** — external sorting keeps the index build within a fixed
  budget regardless of dump size.
- **Machine-readable output** — every command emits JSON or CSV, so it composes
  with `jq`, scripts, and LLM agents.
- **Persistent index** — index once, query many times.

## Install

Requires [Zig](https://ziglang.org) 0.16.0 or later.

```bash
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/hunt`.

## Quick start

```bash
# 1. Build a persistent index from a heap dump
hunt index heap.hprof --index-dir ./idx

# 2. Build the overview cache (used by the summary commands)
hunt overview heap.hprof --index-dir ./idx

# 3. Explore
hunt info --index-dir ./idx
hunt histogram --index-dir ./idx --view
hunt classes --index-dir ./idx --view
```

## Commands

### Indexing

| Command | Description |
|---------|-------------|
| `index <dump> --index-dir <dir>` | Build a persistent heap-graph index. |
| `overview <dump> --index-dir <dir>` | Build a cached overview for summary queries. |

### Summary (require `overview`)

| Command | Description |
|---------|-------------|
| `info --index-dir <dir>` | Header and high-level summary. |
| `histogram --index-dir <dir>` | Class histogram by shallow heap or instance count. |
| `classes --index-dir <dir>` | Loaded classes with names and instance sizes. |

### Object queries (require `index`)

| Command | Description |
|---------|-------------|
| `objects <class-regex> --index-dir <dir>` | List object IDs matching a class regex. |
| `sample <class-regex> --index-dir <dir>` | Decode sample objects as JSON. |
| `object <id> --index-dir <dir>` | Decode a single object, including fields. |

### Reference tracing (require `index`)

| Command | Description |
|---------|-------------|
| `refs-from <id> --index-dir <dir>` | Outgoing references from an object. |
| `refs-to <id> --index-dir <dir>` | Incoming references to an object. |
| `roots <id> --index-dir <dir>` | Shortest path from an object to a GC root. |
| `tree <id> --index-dir <dir>` | Bounded tree expansion from an object. |

Run `hunt <command> --help` for the full option list of any command.

## Configuration

Heap Hunter reads an optional JSON config file, resolved in this order:

1. `$XDG_CONFIG_HOME/hunt/config.json`
2. `$HOME/.config/hunt/config.json`
3. `$HOME/.hunt/config.json`

```json
{
  "index-dir": "/path/to/hunt/indexes"
}
```

When `index-dir` is a base directory, each dump gets its own subdirectory
`<base>/<stem>.idx/`. Pass `--index-dir` on any command to override it.

## Build options

| Option | Values | Description |
|--------|--------|-------------|
| `-Dlog-level` | `err`, `warn`, `info`, `debug` | Minimum log level (defaults by optimize mode). |
| `-Dstack-traces` | `true`, `false` | Capture and dump error-return stack traces. |

```bash
zig build -Doptimize=ReleaseFast                 # production
zig build -Doptimize=ReleaseSafe -Dlog-level=debug -Dstack-traces=true  # diagnostics
```

## Performance

Heap Hunter is built for multi-gigabyte production dumps. On real-world HPROF
files larger than 20 GB, indexing completes in under 3 minutes on a single
core, with working memory bounded by `--sorting-budget-mb` (default 4 GiB).
The index is built once and queried many times, so subsequent `histogram`,
`roots`, `refs-from`, and similar commands return in milliseconds.

## Testing

```bash
zig build test
```

The test suite covers the parser, every index stage, and the query commands.
Several tests in `src/index/` and `src/tests/integration.zig` additionally
read a few HPROF dumps placed under `test_hprofs/` to exercise the full
pipeline end to end. The directory is gitignored; the file names referenced
by the tests are:

- `test_hprofs/heapforge.hprof` — mixed object/array/root graph.
- `test_hprofs/heapforge_classloaders.hprof` — ClassLoader-heavy layout.
- `test_hprofs/heapforge_threads.hprof` — thread metadata.

## Project layout

```
src/
  main.zig              CLI entry point
  root.zig              CLI logic and command dispatch
  Cli.zig               Help generation and argument parsing
  Config.zig            User configuration
  Analysis.zig          Single-pass indexer and overview commands
  Overview.zig          Overview cache
  hprof/                HPROF binary format parser
  index/                Persistent heap-graph index (scan, sort, join, query)
  tests/                Synthetic HPROF builder and integration tests
test_hprofs/            (gitignored) sample HPROFs used by the test suite
```

## Contributing

Bug reports, fixes, and improvements are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for development setup, code conventions, and how to run the test suite.

## License

Heap Hunter is licensed under the [GNU Affero General Public License v3.0](LICENSE).
