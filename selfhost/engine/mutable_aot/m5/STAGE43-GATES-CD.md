# STAGE43 — gates C and D, the production replacement regression, and the
# revised routing-neutrality gate

Fork `2ef1e62` lineage, clean and stamped at the time of each run.
Retention roots **OFF** in the neutrality arms; installation **ON** in Gate C.

```
Gate C   102 checks, 0 failures
Gate D   included in the same 102
Revised Gate A   STRONG_LOST_ROUTING = 0   STRONG_EXTRA_ROUTING = 0
                 weak inline-only delta = 1
```

## 1. Revised Gate A — strong exact, weak reported

Arms are the semantic control **C** (selection ON, non-inlining ON, call
indirection OFF, release edge OFF) and production **B** (same kernel and
semantics, indirection and release edge ON).

```
arm  retained   strong   weak
C    22972      21612    1360
B    22971      21611    1360

C - B = 1 declaration      B - C = 0
STRONG_LOST_ROUTING  = 0
STRONG_EXTRA_ROUTING = 0   (application declarations = 0)
weak inline-only delta: -1  dart:core::_StringBase.get:isNotEmpty
```

"Weak" is decided by **why** the declaration is retained, not by whether its
body contains calls. Every `AddTypesOf` site now names itself, and a
declaration is weak only when `retain:inline-tree` is the *only* name attached
to it.

**The first formulation of this gate was wrong and reported a failure that was
not one.** Differencing the two STRONG sets gave `LOST = 2, EXTRA = 1`; those
three declarations are retained by *both* arms and merely change class. The
gate is membership first, class second: only a declaration absent from the
other arm can be lost, and its class then decides whether the loss gates.

The class boundary is itself order-sensitive, and that is reported rather than
hidden — three `package:kernel` getters are retained by both arms with
different retention reasons:

```
package:kernel/ast.dart Class.get:isAbstract              C: call+inline   B: inline only
package:kernel/ast.dart Class.get:superclass              C: inline only   B: call+inline
package:kernel/library_index.dart _ContainerTable.get:containerName
                                                          C: call+inline   B: inline only
```

Same effect as Stage 42, now visible at the class boundary.

### The classification is not vacuous

Declarations carrying each retention reason in arm C:

```
retain:program-walk               20180
forced via flag (dispatch table)  11771
needed for symbolic stack traces   8939   (the static call table)
retain:inline-tree                 2605   <- weak site
local closure                       836
implicit closure                    494
static field initializer            205
entry point pragma                  194
retain:local-parent                 192
late field initializer              165
dynamic invocation forwarder        102
implicit getter / setter / static    85
called via selector                   3
invoke field dispatcher               1
called through getter                 1
retain:main                           1
```

2,605 declarations carry the weak site; 1,360 carry it *alone*. The exemption
class is populated, so a PASS cannot come from an empty class.

## 2. Gate C — the call sites are still cell-indirect

The caller is itself a mutable declaration and is never installed, which is
what makes its machine code readable: for a mutable declaration
`Function::CurrentCode()` is the trampoline, so the body holding the call sites
is only reachable through the registry's pinned body.

```
dispatch-cell pool byte offsets: top=224 inst=88 sharea=216 shareb=120 other=168

caller pinned-body digest   before = 4567790361758080694
                            v2     = 4567790361758080694
                            v3     = 4567790361758080694

[before] 107 words, 5 cell-indirect sites at pool offsets [88,120,168,216,224]
[v2    ] 107 words, 5 cell-indirect sites at pool offsets [88,120,168,216,224]
[v3    ] 107 words, 5 cell-indirect sites at pool offsets [88,120,168,216,224]
```

The sites are found by **decoding register dataflow** — load the cell from the
object pool, load through it, branch through the resulting register — not by
matching a fixed instruction window, so a scheduled instruction between them
cannot flip the verdict either way. Each site is resolved to a *declaration* by
the pool byte offset the runtime reports for that declaration's cell.

`id_release_body` is frozen across all three stages for every subject, so the
release reachability target is unchanged through both replacements.

### The decoder is falsifiable

The same program built with `--maot_disable_call_indirection`:

```
92 words, 0 cell-indirect sites, 12 pc-relative BL, digest 4120356647174822875
install.top.v2 = -3   install.inst.v2 = -3   install.sharea.v2 = -3
behaviour frozen at OLD through v2 and v3
```

Zero sites where the sequence is not emitted, a different digest, and
**production StageReplacement refuses every install**. Replacement succeeds
only where the machine code routes through the cell — that is #68's escape
detection firing, not a coincidence.

## 3. Gate D — the reachability edge never becomes a binding

```
production                  codes=1596 tables_nonempty=1263 pcrel_total=5427
indirection disabled        codes=1596 tables_nonempty=1263 pcrel_total=5444
RELEASE_EDGES               recorded=17 consumed=17 missing=0 pending_at_end=0
```

**5444 − 5427 = 17 = the number of recorded release edges.** Turning the
indirection on removes exactly one pc-relative static-call-table entry per
recorded edge. A cell-indirect site contributes no static-call-table entry, so
the binder has nothing to bind.

### Two instruments are reported and set aside

* `call_via_code = 0` in both arms. In AOT every static call is pc-relative, so
  the binder's call-via-code path is never taken. "No mutable target was bound
  there" is true and carries no information on its own.
* `pcrel_mutable_targets = 0` in both arms — **including the arm where it had
  to fire**. It does not discriminate, so it is not used. It is reported here
  because a counter that reads zero for an unexplained reason is not evidence,
  and deleting it quietly would hide that.

### The edge list has no other consumer

Every reference to `pending_release_edges_`, attributed to the function
containing it:

```
<declaration>                              precompiler.h:426
Precompiler::Precompiler                   precompiler.cc:542   construction
Precompiler::NoteReleaseReachabilityEdge   precompiler.cc:1159  .Add
Precompiler::AddCalleesOf                  precompiler.cc:1171  .Length()
                                           precompiler.cc:1173  .Length()
                                           precompiler.cc:1174  .At
                                           precompiler.cc:1179  .SetLength
Precompiler::DoCompileAll                  precompiler.cc:776   .Length()
```

Every element-level use — `.Add`, `.At`, `.SetLength` — is the record site or
the drain. The one reference elsewhere reads the count for a diagnostic line
and cannot route anything. Asserted by attribution rather than by a count, so
it keeps working when a line moves.

```
reachability_edges_consumed_by_codegen = 0
```

## 4. Compact production replacement regression

Production `StageReplacement` via `Dart_MaotInstallForTesting`, which is the
same transaction — namespace, ABI, calling convention and version checks — not
the diagnostic cell swap.

```
subject  before          v2        v3
top      OLD:20          NEW:30    NEW2:17      a top-level declaration
inst     OLD:20          NEW:30    NEW2:17      an instance declaration
sharea   SHARED:40       NEW:30    NEW2:17      one half of a shared body
shareb   SHARED:40       SHARED:40 SHARED:40    the other half   (control)
other    OTHERDECL:50    OTHERDECL:50 OTHERDECL:50               (control)

install.*.v2 = 0   install.*.v3 = 0
version 1 -> -102 -> -103 for every subject
```

**The shared-body case arose naturally**: `ShareA.v` and `ShareB.v` were
canonicalized by Dedup onto the *same* release body object. Replacing `ShareA`
leaves `ShareB` identical in behaviour and in all nine identity fields, as does
the cross-wiring control `Other`.

Per subject: six frozen identities (declaration Function, declaration current
code, trampoline code, trampoline entry, dispatch cell, release body) unchanged
across all three stages, and three moving identities (cell impl function, cell
impl code, pinned current body) distinct at each stage.

## Reproduce

```
selfhost/engine/mutable_aot/m5/lib/gatecd_m5.py      gates C and D, regression
selfhost/engine/mutable_aot/m5/lib/strongweak_m5.py  revised Gate A
```

`SW_REUSE=1` re-classifies without re-running the snapshots.
