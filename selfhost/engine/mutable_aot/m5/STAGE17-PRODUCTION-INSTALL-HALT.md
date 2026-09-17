# STAGE 17 — first real instance StageReplacement: HALTED on a stop condition

Status: **STOPPED. Production architecture defect reported, not patched.**
Fork `66d1c4e2826`+ (diagnostic commits), trampolines ON. No diagnostic cell
swap anywhere in this fixture.

## 1. What passed

The production path worked, twice, through a warmed MegamorphicCache site:

```
version.0 = 1 (AOT)      alpha.0  = OLD-ALPHA
install.v2 = 0           alpha.v2 = NEW-ALPHA    version -102 = PATCH_CODE v2
install.v3 = 0           alpha.v3 = NEW2-ALPHA   version -103 = PATCH_CODE v3
beta.0 = BETA            beta.after = BETA
```

| | kind/version | current_impl | release_impl | cell agrees | halves agree |
|---|---|---|---|---|---|
| before | AOT v1 | `Alpha.v` | `Alpha.v` | True | False |
| after v2 | PATCH_CODE v2 | `AlphaNew.v` | `Alpha.v` | True | True |
| after v3 | PATCH_CODE v3 | `AlphaNew2.v` | `Alpha.v` | True | True |

`release.implementation` stays pinned to `Alpha.v` across both installs, so the
rollback pin survives. `installable=True`, `optimizer_escapes=0` throughout.

The megamorphic cache entry for Alpha was **not** rewritten: same cid 235, same
owner, `fn_addr=0x107c67141` byte-identical before and after both installs,
still converging on the trampoline. Beta's independent entry in the same shared
cache did not move.

## 2. THE STOP CONDITION: the install writes a TRAMPOLINE into cell.implCode

```
after v2                                 after v3
  cell.implFunction   = owner AlphaNew     cell.implFunction   = owner AlphaNew2
  cell.implCode == implFn.CurrentCode = YES
  implFn has own trampoline           = yes
  implFn.CurrentCode == its trampoline= YES
  cell.implCode == its own body       = no
```

Read together: `cell.implCode` is `AlphaNew.v.CurrentCode`, and that is
**AlphaNew's own trampoline**, not AlphaNew's body. So the live routing is

```
Alpha trampoline -> Alpha cell -> AlphaNew TRAMPOLINE -> AlphaNew cell -> AlphaNew body
```

an extra hop through a second declaration's cell, added by every install.

This is the PM's named stop condition, and it is not cosmetic:

- **Aliasing.** Alpha's behaviour now depends on AlphaNew's cell. A later
  install over `AlphaNew` would silently move `Alpha` too. Nothing in the
  fixture did that, so it is a latent hazard rather than an observed failure —
  but it is a cross-wiring channel between declarations that the architecture
  does not intend.
- **The self-cycle guard does not catch it.** `CellCodeWouldSelfCycle` refuses
  only THIS declaration's own trampoline in its own cell. Another
  declaration's trampoline passes, which is why the install returned 0.
- **It compounds.** Each install adds a hop; nothing collapses the chain.

Why it happens is visible in the mechanism rather than inferred: the
replacement is itself a `maot:mutable` declaration, so it is selected, so it
receives its own trampoline, so its `CurrentCode` IS that trampoline — and the
commit path stores `implFn.CurrentCode` into `implCode`.

Per the ruling I have not added invalidation, rewriting or special-casing, and
have not attempted to unwrap the chain.

## 3. A second finding: instrumentation goes blind after a production install

`IsMutableDeclaration` -> `DispatchCellForFunction` and `DeclarationIdOf` both
key on **`kCurrentImpl`**:

```c
candidate ^= FieldAt(thread, i, kCurrentImpl);
if (candidate.ptr() == function.ptr()) { ... }
```

A production install advances `kCurrentImpl` to the replacement, so afterwards
the **declaration** Function no longer matches any entry. Consequences:

- A post-install switchable-call miss whose target is the declaration Function
  is **not recorded** as a mutable-declaration observation.
- Therefore my `states.before == states.after` reading is **not load-bearing**
  for the post-install window: those counters could not have fired. The
  load-bearing evidence that the cache entry was untouched is the direct bucket
  reading, which does not depend on this path.
- It also produced a false `NO ENTRY` in my own inspector, which matched by
  declaration id. The entry was present the whole time.

**The five switchable-state proofs are unaffected.** `Dart_MaotDiagnosticCellSwap`
writes only `kCellImplFunction` and `kCellImplCode` and never touches
`kCurrentImpl`, so instrumentation stayed live throughout all of them. Checked,
not assumed.

## 4. Not claimed

`ARM64_AOT_INSTANCE_STAGE_REPLACEMENT_VERTICAL_SLICE` is **NOT** established.
The behaviour is right and the descriptor is right, but the routing the install
leaves behind is not the architecture's intended shape, and the mechanism that
was supposed to refuse exactly this does not see it.
