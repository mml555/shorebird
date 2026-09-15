# MAOT-5 (#69) — N=1 runtime fault: fault class D, pool lifetime

## Signal, independently established

`rc=-6` is SIGABRT, and I previously mis-described this as a segfault on that
basis alone. Under lldb the underlying fault is confirmed separately:

```text
thread #6, name = 'DartWorker'
stop reason = EXC_BAD_ACCESS (code=1, address=0x60d2800786c8)
frame #0: 0x000060d2800786c8
error: memory read failed for 0x60d280078600
```

**Frame #0 *is* the faulting address**: the PC itself is garbage, so the
process branched to an unmapped address. The VM's own banner printing
"Segmentation fault" is its handler's report; the `abort()` afterwards is what
yields `-6`. Both are now corroborated rather than assumed.

## Register state at the fault

| reg | value | expected |
|---|---|---|
| `pc` | `0x60d2800786c8` | a real code address |
| `x16` (TMP) | `0x60d2800786c8` | target entry point |
| **`x24` (CODE_REG)** | **`0x105066408` — EVEN** | a **tagged** `Code` (odd) |
| `x27` (PP) | `0x1052114b0` | global pool |
| `x0` | `0x1051e8a81` (odd ✓) | receiver |
| `x4` (ARGS_DESC) | `0x10510aa11` (odd ✓) | args descriptor |
| `lr` | `0x1050a2888` | caller |

Dart tags heap pointers with the low bit set. `x0` and `x4` are odd as
expected; **`x24` is even**, so the value the trampoline loaded as
`implCode` was never a tagged object. Argument-descriptor state is intact,
so class **C is not implicated**.

## The trampoline executed correctly up to the last instruction

Raw instruction words, entry at +24:

```text
+24  f9400b78  ldr  x24, [x27, #16]   ; load cell from the object pool
+28  f841f318  ldur x24, [x24, #31]   ; cell[1] = implCode
+32  f8407310  ldur x16, [x24, #7]    ; Code::entry_point_
+36  d61f0200  br   x16
```

The encoding is right: 8-byte array elements (so this build is *not*
compressed-pointer), `element_offset(1)` = 32 with the tag giving 31, and
`Code::entry_point_offset()` = 8 giving 7. Every load executed without
faulting. The fault is the final `br`.

So the failure is **class D — the cell/object-pool load resolves incorrectly
at runtime** — not A (wrong entry), not B (wrong `CODE_REG` seen by the body;
we never reach the body), not C.

## Root cause: the global pool is sealed before the trampoline is built

```text
[maot] at install: global_builder_len=0  materialized_pool_len=1560
```

`precompiler.cc:~712`:

```cpp
const auto& pool = ObjectPool::NewFromBuilder(*global_object_pool_builder());
IG->object_store()->set_global_object_pool(pool);
global_object_pool_builder()->Reset();
```

The real pool is materialized and the builder **Reset** at ~712.
`InstallMaotTrampolines()` runs at **757**. Every trampoline is therefore
assembled against an empty builder: its cell is added at local index 0 and
the emitted instruction is `ldr x24, [PP, #16]` — pool entry ~1. At runtime
`PP` addresses the real 1560-entry pool, where entry 1 is an unrelated
object. That object is read as a `Code`, `+7` is read from it, and the result
is branched to.

### This also corrects the distinctness result

The distinctness fix was real but succeeded for a degenerate reason: each
trampoline committed into the *reset* builder and received successive indices
0, 1, 2 …, so the instruction bytes differed and dedup stopped merging them.
`installed=N → distinct=N` still holds, but **every one of those references
was invalid**, before and after. Distinctness was necessary and is not
sufficient.

### The approved install window conflicts with the pool lifetime

The ruling's window — after `MaterializeMutableAotRegistry` (751), before
`FinalizeDispatchTable` (753) — lies entirely **after** the pool is sealed at
~712. The two constraints cannot both be met as the pipeline stands.

## Directions, none taken

1. Generate trampolines **before** the pool is materialized (< ~712). Cells
   exist from kernel load, so this is possible in principle, but it precedes
   registry materialization, so trampolines would have to survive the
   registry rebuild the way cells already do.
2. Reference the cell's **existing** pool index instead of adding a new
   entry. #67's call-site lowering already places every cell in the global
   pool via `LoadUniqueObject` while the builder is live — so the cell is
   *already* in the materialized 1560-entry pool. The trampoline would emit a
   load from that known index rather than registering the object again.

(2) looks smaller and does not move the install window. Neither is
implemented; this is reference construction, and the ruling reserves the
decision.

## Not claimed

* No dispatch form is proven; no #64 cell moves.
* The release body has still never been entered, so obligations 1, 2 and 3
  remain untested. The smallest valid test — trampoline → pinned release body
  → OLD — has not passed.
* The N ≥ 7 serializer failure remains parked and uninvestigated.
