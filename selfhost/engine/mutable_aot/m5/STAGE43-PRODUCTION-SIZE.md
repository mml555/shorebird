# STAGE43 — the production-policy size

Fork clean and stamped. Workload: `pkg/vm/bin/gen_kernel.dart` compiled to AOT,
then run to produce a kernel from a real source file. All three arms succeeded.

Policy v2 = root-package ownership (`MAOT_SELECT_ALL_NON_SDK=1`,
`MAOT_SELECT_URI_PREFIX=package:vm/`) with `--maot_disable_retention_roots`, so
selection **consumes** retention instead of causing it.

| arm | policy | indirection | release edge | installation |
|---|---|---|---|---|
| A | baseline | n/a | n/a | OFF |
| B | policy v2 | ON | ON | OFF |
| C | policy v2 | ON | ON | ON |

**Every arm was given the identical diagnostic flag set.** Stage 31 cost four
rounds because a diagnostic ran on one arm and not another; that is not
repeated by leaving a dump flag on a single arm.

## 1. The matrix

```
arm   MB        .text      .rodata    sel    elig   refused  installed  distinct  workload
A     13.417    5785328    3810576    0      0      0        0          0         ok
B     14.019    5828544    4364176    1853   1775   78       0          0         ok
C     14.235    5909776    4401808    1853   1775   78       1853       1853      ok
```

Retention, split by the revised gate's classes:

```
arm   retained   strong   weak
A     22799      21349    1450
B     22972      21612    1360
C     22972      21612    1360
```

Body partition and traversal:

```
A  traversal=FAIL(no pinned bodies)   entries=0
B  traversal=PASS   entries=1853 unique_body=1683 shared_body=170 no_body=0
                    body_is_trampoline=0 sum=1853 remainder=0
C  traversal=PASS   entries=1853 unique_body=1683 shared_body=170 no_body=0
                    body_is_trampoline=0 sum=1853 remainder=0

release edges    A recorded=0     B and C recorded=3207 consumed=3207
                 missing=0 pending_at_end=0 in every arm
```

> Arm A's traversal verdict prints `FAIL(no pinned bodies)`. The condition is
> correct — a baseline with no mutable declarations pins nothing — but the
> label is wrong for that case and should read as "not exercised", the way the
> leaf-only verdict does. **Reported as a label defect in the diagnostic, not
> as a result.** It does not affect any number above.

## 2. Derived costs

```
B - A     +601,576 B   (+4.48%)    .text  +43,216    .rodata  +553,600
          strong retention  -2 / +176      weak inline-only  -1 / +0
          selection + non-inlining + routing

C - B     +216,024 B   (+1.54%)    .text  +81,232    .rodata   +37,632
          strong retention   0 / 0         weak inline-only   0 / 0
          trampoline and installation

C - A     +817,600 B   (+6.09%)    .text +124,448    .rodata  +591,232
          strong retention  -2 / +176      weak inline-only  -1 / +0
          THE PRODUCTION-POLICY COST
```

**This replaces the Stage 34 number permanently.**

Two things the split makes visible that a single percentage did not:

* **B − A is 92% read-only data, not code.** `.rodata` grows by 553,600 B
  against 43,216 B of `.text`. The cost of selection and non-inlining is
  overwhelmingly metadata and constants for the 176 declarations that now have
  to exist as real bodies, not the bodies themselves.
* **C − B changes no retention at all** — strong and weak deltas are both zero
  in both directions. Installation adds 1,853 trampolines and nothing else:
  216,024 B for 1,853 declarations, of which 81,232 B is `.text`, about 44
  bytes of code per declaration.

`installed = distinct = 1853`: no two trampolines were merged by Dedup, so
every declaration has its own routing object.

Eligibility is 1,775 of 1,853 (95.8%); the 78 refusals are declarations the
escape and disposition checks decline, and they are refused rather than
silently installed.

## 3. Diagnostics are enabled and not serialized — measured

The same two arms rebuilt with **every** diagnostic flag removed:

```
                     file bytes      .text sha256-24        .rodata sha256-24
A  diagnostics ON    13,417,440      3e6851e2b4bed97f6df7e5f3  4c80be319e6213f7d691fe32
A  diagnostics OFF   13,417,448      3e6851e2b4bed97f6df7e5f3  4c80be319e6213f7d691fe32
C  diagnostics ON    14,235,040      4c6e8aae115b4630ff5471a6  fee76594e1dd290daf1b3352
C  diagnostics OFF   14,235,048      4c6e8aae115b4630ff5471a6  fee76594e1dd290daf1b3352
```

`.text` and `.rodata` are **byte-identical** with the diagnostics on and off,
on both arms, and every named section has the same size. The remaining 8-byte
file difference lies outside the loaded sections and is the same 8 bytes on
both arms, so it cancels in every delta above. The Stage 39 split — the
decision log moved out of the ObjectStore into malloc'd memory — is what makes
this true, and this is the measurement of it rather than a restatement.

## Reproduce

```
selfhost/engine/mutable_aot/m5/lib/stage43_m5.py    the matrix
scratchpad diagneutral.sh (vendored below)          the diagnostics control
```
