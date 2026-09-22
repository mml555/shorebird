# STAGE44 — where the production-policy bytes are, and 131,072 of them removed

Fork clean and stamped. Attribution by `--write_v8_snapshot_profile_to`, which
attributes every serialized object to a type, a name and a byte count.

**The profile reconciles against the ELF sections** — profile total equals
`.text + .rodata` to within 80 bytes on every arm, and the `Instructions`
total equals `.text` to within 304 — so it is attribution and not a parallel
accounting.

```
arm   file        .text      .rodata    profile total   Instructions
A     13417440    5785328    3810576    9595824         5785024
B     14019016    5828544    4364176    10192640        5828248
C     14235040    5909776    4401808    10311504        5909476
```

## 1. B − A = +601,576 B — and it is not mostly retention

```
item                                              bytes     share  category
declaration-id strings  1,853 distinct, 0 dup     244,624   40.7%  REQUIRED (identity)
registry storage array  one node, 1,853 x 26      124,863   20.8%  REQUIRED (the registry)
calling-convention strings  1,853 obj, 51 values  118,608   19.7%  DUPLICATE
Instructions (.text)    +194 bodies                43,224    7.2%  CONSERVATIVE RETENTION
dispatch cells          +1,833 Arrays, 9 B each    16,497    2.7%  REQUIRED (routing)
other strings                                      13,120    2.2%  mixed
escape-reason prose     78 copies of 1 sentence     11,232    1.9%  DIAGNOSTIC
int, CanonicalString, ArtificialRoot, blob         ~12,500    2.1%  follows the above
Function +300 / ObjectPool +26 / Code +194 /
  CodeSourceMap +138                               ~12,900    2.1%  CONSERVATIVE RETENTION
```

Rolled up:

```
REQUIRED for replacement           385,984   64.2%
DUPLICATE / redundant metadata     118,608   19.7%
CONSERVATIVE RETENTION              56,124    9.3%
DIAGNOSTIC-only                     11,232    1.9%
incidental / follows the strings   ~29,600    4.9%
```

**The registry's own encoding is 84% of B − A. Conservative retention is
9.3%.** The 176 declarations that now have to exist as real bodies cost 43,224
bytes of `.text` and about 12,900 bytes of surrounding metadata — under a
tenth of the increment. Everything else is the cost of *describing* 1,853
replaceable declarations, not of keeping 176 more of them.

That is a different conclusion from the one the section split suggested, and
it moves the target: the useful work is in how a declaration is described, not
in what retention keeps.

### The duplication, counted rather than inferred

A value written once per declaration costs one object per declaration. The
profile reports every node separately, so the copies are countable:

```
value                                         objects   distinct   bytes
calling convention  cc1;fixed*;regs*;...        1,853        51    118,608
escape reason       "the dispatch cell has ..."    78         1     11,232
declaration id      lib:...::cls:...::...       1,853     1,853    244,624
abi                 "C"                             1         1         32
```

The single most common calling-convention shape,
`cc1;fixed2;regs2;nofactory;argstt;rett`, was stored **940 times**.

Declaration ids are the opposite case and are left alone: all 1,853 are
distinct, none is stored twice, and they are the identity the programme exists
to preserve.

## 2. Two candidates, applied and measured

Both are category-3 duplication. Neither merges a trampoline, shares a cell,
weakens identity, drops a body, or loosens a gate.

`String::New` → `Symbols::New` for the calling convention and the escape
reason. Nothing compares either by identity — every consumer uses
`String::Equals` (StageReplacement's ABI and calling-convention checks at
`maot_registry.cc:1387,1400`, the compatibility oracle at `:1689,:2009`) — so
equal contents stay equal.

### A/B

```
arm   before        after         delta
A     13,417,440    13,417,440          0     <- unchanged, as it must be
B     14,019,016    13,887,944   -131,072
C     14,235,040    14,103,968   -131,072

B - A   +601,576 (+4.48%)  ->  +470,504 (+3.51%)
C - B   +216,024 (+1.54%)  ->  +216,024 (+1.56%)   unchanged
C - A   +817,600 (+6.09%)  ->  +686,528 (+5.12%)
.text                          unchanged in every arm
```

Predicted 126,416 B; measured **131,072 B** (the extra ~4,600 is the canonical
string bookkeeping that followed the copies).

**Arm A is unchanged to the byte** — a build with no registry has nothing to
intern, so the change cannot flatter the baseline.

**All three retained-set dumps are byte-identical before and after.** The
change is encoding only: retention, strong/weak classes, selected (1,853),
eligible (1,775), refused (78), installed and distinct (1,853/1,853), the body
partition and the release-edge accounting are all unchanged.

**Correctness re-run after the change: gates C and D and the production
replacement regression, 102 checks, 0 failures.** If interning had broken a
compatibility comparison, StageReplacement would have refused and the
regression would have failed.

## 3. C − B = +216,024 B — the true per-trampoline cost

```
type                    delta bytes   delta n   per trampoline
(RO) Instructions            +81,228    +1,853        43.84   the trampoline code
Code                         +18,530    +1,853        10.00   its Code object
(RO) String                  +14,944        +2         8.06   see below
Array                         +3,706         0         2.00   the cell contents
Function                        +337       +13         0.18
DispatchTable                   +131         0         0.07
```

`.text` +81,232 = **43.8 B of code per trampoline**; `.rodata` +37,632 =
**20.3 B per trampoline**.

Of that 20.3, ten bytes are the `Code` object and two are the cell update. The
remaining 14,832 bytes are the growth of the single packed character-data node
against only **two** new string objects (`get:_orderingTypePriority`,
`get:elementSizeInBytes`, 112 B between them). That is 6.9% of C − B and it is
**not explained**; it is recorded as measured rather than assigned to a
category.

`installed = distinct = 1853`: no trampoline was merged, which is intended.

## 4. Candidates that need a ruling before they are tried

* **Registry entry layout.** The storage array is 124,863 B for 1,853 entries
  of 26 fields — 67 B per declaration, 2.6 B per field, already tight per
  field. But **9 of the 26 fields are transaction scratch or counters**:
  `kStagedKind, kStagedVersion, kStagedImpl, kStagedAbi, kStagedCallConv,
  kStagedImplId` are null in a freshly serialized image, and
  `kCallSiteCount, kInlineRefusalCount, kInlineAdmissionCount` are diagnostic
  tallies. Allocating the staged block lazily bounds at roughly 43,200 B
  (7.2% of the original B − A). **Not attempted**: it changes the descriptor
  layout, which is adjacent to declaration identity, and the ruling on that is
  the PM's.
* **Declaration-id length.** 244,624 B over 1,853 ids, averaging 132 bytes,
  with the library URI repeated in every id. Any change here is a change to
  identity encoding and is explicitly out of scope until ruled on.

Not proposed at all, per the standing constraints: merging trampolines,
sharing cells, weakening identity, dropping bodies the replacement path
depends on, loosening refusal gates, or changing routing.

## 5. Also fixed

`PINNED_TRAVERSAL` now reports `NOT_EXERCISED(no pinned bodies)` where it used
to report `FAIL(no pinned bodies)`, so a baseline arm no longer carries a
failure verdict for being a baseline. The structural condition no longer
requires a non-empty pin set to be true.

## Reproduce

```
selfhost/engine/mutable_aot/m5/lib/stage44_m5.py    profile and reconcile
selfhost/engine/mutable_aot/m5/lib/stage44b_m5.py   strings and arrays
selfhost/engine/mutable_aot/m5/lib/stage44c_m5.py   copy counts
selfhost/engine/mutable_aot/m5/lib/stage43_m5.py    the A/B size matrix
selfhost/engine/mutable_aot/m5/lib/gatecd_m5.py     the correctness re-run
```
