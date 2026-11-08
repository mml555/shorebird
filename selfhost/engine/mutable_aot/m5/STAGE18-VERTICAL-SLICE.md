# STAGE 18 — production instance StageReplacement after the two fixes

Status: **all acceptance-gate items measured and passing.** Reported for the
PM's disposition; the milestone is the PM's to establish.

## 1. The two defects, and what changed

**Body pin.** `CommitStagedForTesting` set both `kCurrentCode` and the cell's
Code half from `stagedFunction.CurrentCode()`. The replacement is itself a
selected declaration, so once #69 attaches its trampoline that expression IS
the trampoline. It now stores the pinned BODY via `PinnedBodyCodeFor`, which
reads the replacement's own registry pin -- captured at materialization before
`AttachCode`, canonicalized in Dedup -- and refuses ANY trampoline rather than
only a literal self-cycle.

The compile-time path already had this rule: `RepinCurrentCode` returns early
when a trampoline exists, with a comment naming this exact hazard. The runtime
commit path did not. One rule, applied in one of the two places that needed it.

**Stable identity.** `DeclarationIdOf`, `IsMutableDeclaration` and
`DispatchCellForFunction` keyed on `kCurrentImpl`, which every install
advances, so a declaration stopped being a declaration once it was installed
over. They now key on `kReleaseImpl`, captured once at registration. The other
meaning became `DeclarationIdSuppliedBy` rather than an overload.

## 2. The pin flip, read directly

| | before fix | after fix |
|---|---|---|
| `cell.implCode == implFn.CurrentCode` | YES (the trampoline) | **NO** |
| `cell.implCode == its own body` | no | **YES** |
| `implFn has own trampoline` | yes | yes (unchanged, and legitimate) |

Both after v2 (`owner AlphaNew`) and after v3 (`owner AlphaNew2`).

## 3. The production sequence

```
version.0  = 1      (AOT)        alpha.0  = OLD-ALPHA
install.v2 = 0                   alpha.v2 = NEW-ALPHA    version -102 = PATCH_CODE v2
install.v3 = 0                   alpha.v3 = NEW2-ALPHA   version -103 = PATCH_CODE v3
beta.0 = BETA                    beta.after = BETA
```

| | kind/version | current impl | release impl | cell agrees | installable |
|---|---|---|---|---|---|
| before | AOT v1 | `Alpha` | `Alpha` | True | True |
| after v2 | PATCH_CODE v2 | `AlphaNew` | `Alpha` | True | True |
| after v3 | PATCH_CODE v3 | `AlphaNew2` | `Alpha` | True | True |

## 4. Declaration identity survives both installs

The inspector locates the megamorphic entry BY declaration id. Before the fix
it reported `NO ENTRY` after each install; it now finds the entry at every
stage, which is `DeclarationIdOf(Alpha declaration Function)` resolving
correctly through v2 and v3. `IsMutableDeclaration` and
`DispatchCellForFunction` now route through the same
`EntryForDeclarationFunction`, so they answer from the same stable key.

## 5. The MegamorphicCache entry is untouched

```
afterWarm  cid=236 owner=Alpha addr=0x103767531 CurrentCode_IS_trampoline=YES tramp=0x1035c6784
after v2   cid=236 owner=Alpha addr=0x103767531 CurrentCode_IS_trampoline=YES tramp=0x1035c6784
after v3   cid=236 owner=Alpha addr=0x103767531 CurrentCode_IS_trampoline=YES tramp=0x1035c6784
Beta       cid=232 owner=Beta  addr=0x103767671 CurrentCode_IS_trampoline=YES tramp=0x1035c68a4  (first and last)
```

Byte-identical cached Function address across both installs; the Alpha
declaration Function's `CurrentCode` remains Alpha's trampoline; Beta keeps its
own entry and its own distinct trampoline.

## 6. Cross-wiring regression: Alpha is independent of the replacement's cell

After v3 Alpha runs `AlphaNew2`'s body, so `AlphaNew2` is the declaration Alpha
would be coupled to. Perturbing **`AlphaNew2`'s own cell** -- not `AlphaNew`'s,
which after v3 would test a dependency that does not exist even in the broken
build and would pass vacuously:

```
xwire.swapAlphaNewCell   = 0            AlphaNew2's cell -> Interloper
xwire.retainInterloper   = INTERLOPER   the perturbation is real
xwire.alphaAfter         = NEW2-ALPHA   Alpha did NOT follow it
```

Alpha stays on the body pinned into Alpha's own cell. The accidental dependency
is removed, not merely shortened in this fixture.

## 7. One diagnostic now reads backwards -- flagged, not silently left

`dispatch_cell_halves_agree` compares `cell.implCode` against
`implFunction.CurrentCode()`. It read **True** after installs while the defect
was live (both were the trampoline) and reads **False** now that the fix is in
(implCode is the body, CurrentCode is the replacement's trampoline).

So the correct state now displays as a disagreement. The field is not wrong,
but its name invites the opposite reading, and a future reviewer seeing
`halves_agree=False` would reasonably suspect a defect. It wants renaming or
re-describing to something like "implCode equals implFunction.CurrentCode
(expected FALSE once trampolines are installed)". Not changed here: it is a
#66-era diagnostic and renaming it is not part of this authorization.
