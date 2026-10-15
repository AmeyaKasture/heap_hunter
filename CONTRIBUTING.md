# Contributing to Heap Hunter

Thanks for your interest in contributing. Heap Hunter is a Zig project that
parses Java HPROF heap dumps and builds a persistent heap-graph index.

## Development setup

Requires [Zig](https://ziglang.org) 0.16.0 or later. No other dependencies.

```bash
# Build
zig build -Doptimize=ReleaseFast

# Run the test suite
zig build test

# Run hunt directly from the build output
zig build run -- index path/to/heap.hprof --index-dir ./idx
```

## Code conventions

- Match the surrounding style. The codebase uses 4-space indentation, Zig 0.16
  `std.Io` APIs, and `std.ArrayList` / `std.fs.Dir` patterns.
- Public API surfaces carry doc comments. Run `zig build test` to ensure the
  test suite still passes.
- Prefer streaming, bounded-memory algorithms. The indexer must stay within the
  sorting budget on multi-gigabyte dumps.
- Do not introduce new global state. Dependencies are wired through `build.zig`
  modules.

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

## Testing

```bash
zig build test
```

The test suite is mostly self-contained: it builds synthetic HPROF dumps in
memory and exercises the full index → overview → query pipeline. A handful of
tests in `src/index/` and `src/tests/integration.zig` additionally read real
HPROF dumps from the `test_hprofs/` directory. The directory is gitignored;
if you want to run those particular tests, drop the sample HPROFs there
before running `zig build test`.

## Pull requests

- Keep changes focused. One logical change per PR.
- Run `zig build test` before submitting.
- Update the README, doc comments, or CLI help text if your change affects
  user-facing behavior.
- Add a regression test for any bug fix.

## Reporting issues

Please include:

- The Heap Hunter version (`hunt --version`).
- A minimal HPROF reproduction if the issue is parser-related.
- The full command line and the unexpected output.
- Relevant platform and Zig version.

## License

By contributing, you agree that your contributions will be licensed under the
[GNU Affero General Public License v3.0](LICENSE).

### Contributor License Agreement (CLA)

Before your first contribution is merged, you must accept the
[Individual Contributor License Agreement](CLA.md). The CLA lets the project
owner relicense your contribution under additional terms (for example, a
future commercial offering) while your own copyright in the contribution
remains with you. The Project itself stays AGPL v3.0 for everyone who
receives it under the open-source terms.

To accept, add a `Signed-off-by: Your Name <email>` line referencing this
CLA to your commit messages and include a short comment on your first
pull request that says "I have read and accept CLA.md".
