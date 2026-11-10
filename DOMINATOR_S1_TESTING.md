# S1 Dominator CHK Engine — Manual Test Checklist

Run these from `/Users/ameyakasture/heap_hunter`.

## 1. Formatting / compile sanity

```bash
cd /Users/ameyakasture/heap_hunter
zig fmt --check src/root.zig src/index/Dominator.zig src/index/dominator/*.zig src/Commands.zig src/index/Publish.zig src/index/Manifest.zig src/index/Preflight.zig src/index/Validate.zig src/index/IndexReader.zig src/Cli.zig src/Config.zig
zig build
```

## 2. Unit tests

```bash
# Debug (slow; may take 20–40 min)
zig build test

# ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

## 3. End-to-end index with dominators

```bash
rm -rf /tmp/idx_dominators
./zig-out/bin/hunt index fixtures/heapforge.hprof --index-dir /tmp/idx_dominators
```

Expected JSON fields in output:

- `"format_version": 2`
- `"has_dominators": true`
- `"n_dominator_nodes"` > 0
- `"retained_total_bytes"` > 0
- `"unreachable_objects"` > 0

Verify files exist:

```bash
ls -la /tmp/idx_dominators | grep -E 'dom_parent\.bin|dom_order\.bin|retained\.bin'
```

## 4. `--no-dominators` deletes stale optional files

```bash
./zig-out/bin/hunt index fixtures/heapforge.hprof --index-dir /tmp/idx_dominators --no-dominators --force
```

Expected JSON:

- `"has_dominators": false`
- `"n_dominator_nodes": 0`
- `"retained_total_bytes": 0`

Verify files are gone:

```bash
ls /tmp/idx_dominators | grep -E 'dom_parent\.bin|dom_order\.bin|retained\.bin' || echo "optional files removed"
```

## 5. Budget error message (spec compliance)

```bash
rm -rf /tmp/idx_budget
./zig-out/bin/hunt index fixtures/heapforge.hprof --index-dir /tmp/idx_budget --dominator-budget-mb 1 --force
```

Expected stderr:

```
error: dominator computation needs <X> MB for 170877 objects but the budget is 1.0 MB
       raise it with --dominator-budget-mb, or index with --no-dominators
```

Process should exit non-zero.

## 6. Rebuild with dominators after `--no-dominators`

```bash
./zig-out/bin/hunt index fixtures/heapforge.hprof --index-dir /tmp/idx_dominators --force
ls -la /tmp/idx_dominators | grep -E 'dom_parent\.bin|dom_order\.bin|retained\.bin'
```

Files should reappear.

## 7. Reuse path still works

```bash
./zig-out/bin/hunt index fixtures/heapforge.hprof --index-dir /tmp/idx_dominators
```

Expected output: `{"status":"reused",...}`.

## 8. Dominator query commands

Requires an index built **with** dominators.

```bash
# Immediate dominator and retained size of a single object.
./zig-out/bin/hunt dominator 0x3000 --index-dir /tmp/idx_dominators

# Dominator chain from an object up to the virtual root.
./zig-out/bin/hunt dominator-tree 0x3000 --index-dir /tmp/idx_dominators
```

Both commands print JSON. `dominator-tree` is useful for understanding what keeps an object alive.

## 9. Retained reconciliation (sanity)

```bash
python3 - <<'PY'
import struct, os
d = '/tmp/idx_dominators'
with open(os.path.join(d,'retained.bin'),'rb') as f: retained = list(struct.unpack_from('<Q', f.read(), i*8) for i in range(os.path.getsize(f.name)//8))
with open(os.path.join(d,'dom_order.bin'),'rb') as f: order = list(struct.unpack_from('<I', f.read(), i*4)[0] for i in range(os.path.getsize(f.name)//4))
with open(os.path.join(d,'dom_parent.bin'),'rb') as f: parent = list(struct.unpack_from('<I', f.read(), i*4)[0] for i in range(os.path.getsize(f.name)//4))
print('retained[root] =', retained[order[0]])
print('n_reachable    =', len(order))
print('parent[root]   =', parent[order[0]])
PY
```

`retained[root]` should equal the previously reported `retained_total_bytes`.

## Notes

- `zig build test` in Debug is slow because the dominator tests include a 1,000,000-node chain and fixture end-to-end tests under Debug safety instrumentation. If a run appears stuck, ensure no stale `zig build test` process is running and clear caches with `rm -rf .zig-cache ~/.cache/zig`.
- The budget error message is printed by the CLI wrapper and names the required MB, object count, and budget MB.
