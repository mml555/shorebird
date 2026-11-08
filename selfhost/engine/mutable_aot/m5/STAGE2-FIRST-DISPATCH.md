# MAOT-5 (#69) — the trampoline executes: OLD → NEW → NEW2, correctly bound

## The fix

The trampoline now **names the cell's existing global-pool entry** instead of
registering the object again:

```asm
+24  ldr  x24, [x27, #<cell's real index>]   ; LoadWordFromPoolIndex
+28  ldur x24, [x24, #31]                    ; cell[1] = implCode
+32  ldur x16, [x24, #7]                     ; Code::entry_point_
+36  br   x16
```

#67's call-site lowering already places every referenced cell into the global
pool while the builder is live, so by the time trampolines are generated the
cell is *already* in the sealed 1560-entry pool. Adding it again put it in a
builder nobody reads while the emitted instruction indexed the sealed pool at
slot ~1 — an unrelated object, read as a `Code`, branched to as garbage.

A declaration whose cell is not in the pool (no call site referenced it) gets
**no trampoline**: one that cannot reach its own cell is worse than none.

## Smallest valid test — PASS

```text
N=1, trampoline on cls:OnlyShape::method:describe
snapshot rc 0
run rc 0                     <- process exits cleanly
devirt.1        = OLD-DEVIRT
install.devirt  = -3         <- #68 instance-dispatch escape still refuses
```

trampoline → cell → implCode → release body → **OLD**, clean exit.

## OLD → NEW → NEW2 through a trampoline — PASS

`--maot_trampoline_only=fn:tiny`, one declaration:

| | |
|---|---|
| `tiny.0` | `OLD-TINY` |
| `install.tiny` | `0` |
| `tiny.1` / `hot.tiny` | `NEW-TINY` / `NEW-TINY` |
| `install.tiny.v3` | `0` |
| `tiny.2` | `NEW-CONST` |
| `tiny.version.2` | `PATCH_CODE:v3` |

## Cross-wiring — PASS

Two declarations, **both** carrying trampolines:

| | A = `tiny` | B = `constantish` |
|---|---|---|
| start | `OLD-TINY` | `OLD-CONST` |
| **patch A only** | `NEW-TINY` | **`OLD-CONST`** |
| patch B too | `NEW-TINY` | `NEW-CONST` |

The fixture previously installed both before re-reading either, which would
have hidden shared-cell binding entirely. It now reads both immediately after
patching only A. This is the test that distinguishes *structurally distinct*
trampolines from *correctly bound* ones — and it is exactly what would have
failed while all trampolines deduplicated into one.

## Still failing: the population threshold

| N | snapshot |
|---|---|
| 1, 2, 3, 4 | ok |
| **5, 6, 7, 13** | **crash** |

The threshold moved from 6→7 to 4→5. **Two variables changed** — the
pool-index fix and the fixture (extended with the cross-wiring reads) — so
the shift is not attributable to either alone, and I have not separated them.

This is the serializer failure that was parked. It is independent of the
dedup invariant and of the pool-lifetime defect, both of which are now fixed.

## Trampolines are opt-in

`--maot_install_trampolines`, **default off**. #69 does not serialize above a
small population, and #66/#67/#68 are accepted work that must keep passing.
With the default:

| lane | result |
|---|---|
| m2 (#66) | `runtime_implementation_registry = ESTABLISHED` |
| m3 (#67) | exit 0 |
| m4 (#68) | 18 arms 0 failed, 23 conditions 0 failed, `ESTABLISHED` / `READY` |

## Not claimed

* No #64 cell moves. A trampoline on an *instance* declaration still cannot
  install — `install.devirt = -3` — because #68's instance-dispatch escape
  stands. Every replacement proven here went through a **static** declaration
  that happened to carry a trampoline, so this is not yet virtual dispatch.
* The population threshold is unexplained.
