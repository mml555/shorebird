# STAGE46 — declaration IDs stored as tuples: +5.12% → +3.77%

Fork clean and stamped. Option 2 as authorized: **the in-snapshot
representation changed, the identity contract did not.**

```
C - A   +817,600 B (+6.09%)   before any of this work
        +686,528 B (+5.12%)   after interning cc / escape strings
        +506,304 B (+3.77%)   after storing ids as tuples
```

## 1. What changed

A declaration id is `lib:<uri>::[cls:<owner>::]<kind>:<member>`. The registry
now stores the four components as Symbols in one `Array(4)` and renders the
canonical text from them on demand.

The entry stride is unchanged — the tuple lives in the existing
`kDeclarationId` slot — so **nothing about descriptor addressing moves**, which
was the risk that closed the scratch-field item. The kernel metadata, the
install API, the registry dump and every diagnostic still see the same bytes.

**Round-trip or nothing.** `EncodeDeclarationId` renders the tuple back and
compares it with the text it came from; a single differing byte means the text
is stored verbatim instead. Byte-for-byte reconstruction is therefore a
property of the stored value, not something a test hopes for afterwards.

Lookups compare tuples — four pointer tests instead of a 108-byte compare —
and the lookup path uses `Symbols::Lookup`, not `Symbols::New`, so an unknown
id cannot add a permanent symbol.

## 2. Identity equivalence

Emitted by the artifact at materialization:

```
[maot] DECLARATION_IDS entries=1853 structured=1853 verbatim=0
       roundtrip_ok=1853 roundtrip_fail=0
       duplicate_texts=0 duplicate_tuples=0
```

* all 1,853 ids reconstruct byte-for-byte — `roundtrip_fail=0`, `verbatim=0`;
* zero duplicate tuples;
* `duplicate_texts == duplicate_tuples == 0`, so no old id maps to two new
  ones and no new one maps to two old ones — a collapsing encoding would show
  as fewer distinct tuples than texts.

Independently re-derived in Python from the registry dump, against the same
grammar:

```
ids 1853, distinct 1853        distinct tuples 1853   round-trip failures 0
private members with an embedded URI   295   lib:...::fn:_escapePath@package:vm/kernel_front_end.dart
top-level, no cls: segment             126   lib:...::fn:declareCompilerOptions
unnamed constructors, empty member     192   lib:...::cls:ErrorDetector::ctor:
operators                               26   lib:...::cls:Selector::op:==
```

All four hard cases are in the corpus and all four survive: the member name is
everything after the first `:` of the tail, which is what keeps `op:==` and an
empty `ctor:` member exact, and the privacy suffix `@package:...` contains `:`
but never `::`, so the separators stay unambiguous.

## 3. Replacement behaviour, routing, retention

```
gates C and D + the production replacement regression   102 checks, 0 failures
OLD -> NEW -> NEW2            top, inst, sharea         all three
shared-body case              ShareA/ShareB still one Code, B untouched
frozen / moving identities    six frozen, three moving, unchanged
refusals                      78 of 1,853, unchanged
retained sets                 byte-identical to the pre-change dumps, all 3 arms
strong / weak deltas          -2 / +176 and -1 / +0, unchanged
installed / distinct          1853 / 1853, unchanged
body partition                1683 unique, 170 shared, remainder 0, unchanged
release edges                 recorded=3207 consumed=3207 missing=0 pending=0
traversal                     A NOT_EXERCISED, B and C PASS
```

## 4. Size

```
arm   MB        .text      .rodata    sel    elig   refused  installed  distinct
A     13.417    5785328    3810576    0      0      0        0          0
B     13.691    5828544    4044544    1853   1775   78       0          0
C     13.924    5909776    4082176    1853   1775   78       1853       1853

B - A   +273,896 B (+2.04%)   .text +43,216   .rodata +233,968
C - B   +232,408 B (+1.70%)   .text +81,232   .rodata  +37,632
C - A   +506,304 B (+3.77%)   .text +124,448  .rodata +271,600
```

C − B's **section** deltas are identical to the previous run (+81,232 /
+37,632); only the file-level figure moved, by 16,384 B of ELF alignment
against a smaller base. The trampoline cost has not changed.

## 5. Two measurements that said the prototype was wrong

Both were caught by the A/B, not by reasoning.

**First attempt: +49,152 B, a regression.** Interning is permanent, and
`Register` runs for every *candidate* declaration — 22,675 of them against
1,853 survivors — so the symbol table ended up holding the library, owner,
kind and member of twenty thousand declarations that materialization then
drops. `structured=22675` was the tell. Encoding now happens only during the
materializer's rebuild, when the surviving set is known.

**Second attempt: +65,544 B, still a regression.** The profile showed the full
id strings *still present*, 244,656 B over 1,854 objects, completely unchanged.
`kCurrentImplId` and `kReleaseImplId` hold the same declaration-id text, and
converting only `kDeclarationId` left those two fields keeping it alive — so
the change added 438 component symbols and 1,853 arrays on top of text that
never left. At registration the implementation *is* the declaration, so all
three fields now reference the one encoded tuple.

Neither failure was visible from the design. Both were visible in one profile
diff.

## Reproduce

```
selfhost/engine/mutable_aot/m5/lib/gatecd_m5.py     102-check regression
selfhost/engine/mutable_aot/m5/lib/stage43_m5.py    the A/B/C size matrix
selfhost/engine/mutable_aot/m5/lib/stage44_m5.py    profile reconciliation
```
