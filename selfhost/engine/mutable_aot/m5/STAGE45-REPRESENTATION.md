# STAGE45 — registry scratch fields, declaration-ID representation, and the
# last unexplained bytes

Measurement and design. **Nothing in this stage changes the artifact.**

## 1. The nine fields, mapped — and only six of them are transaction state

Every use of all nine is confined to `maot_registry.cc`, except two that leave
it. Those two decide the classification.

| field | writers | readers | needed before first replacement | persisted across transactions | observable through the API | needed by snapshot restoration |
|---|---|---|---|---|---|---|
| `kStagedKind` | `StageReplacement`, `CommitStagedForTesting`, `AbandonStagedForTesting` | `HasStagedFor`, `AnyEntryHasStagedOrAdvanced`, `CommitStaged`, `DumpToFile` | no | no — cleared on commit and on abandon | yes, via `Dart_MaotDumpForTesting` | no |
| `kStagedVersion` | same | `CommitStaged` | no | no | yes | no |
| `kStagedImpl` | same | `CommitStaged`, `ClassifyCodePointer` | no | no | yes | no |
| `kStagedAbi` | same | `CommitStaged` | no | no | yes | no |
| `kStagedCallConv` | same | `CommitStaged` | no | no | yes | no |
| `kStagedImplId` | same | `CommitStaged` | no | no | yes | no |
| `kCallSiteCount` | `NoteCallSiteEmitted` (backend), `SetCallSiteCountFor` (precompiler) | `CallSiteCountFor` (precompiler), **`CallSiteCountAt` — `runtime_entry.cc:3506`**, `DumpToFile` | **yes** | **yes** | yes | **yes** |
| `kInlineRefusalCount` | `NoteInlineVerdict` (inliner), `SetInlineCountsFor` | `InlineCountsFor` (precompiler), `DumpToFile` | yes (written before the image exists) | yes | yes | no decision reads it |
| `kInlineAdmissionCount` | same | same | yes | yes | yes | no decision reads it |

**`kCallSiteCount` is not diagnostic.** `runtime_entry.cc:3506` reads it on the
dynamic-invocation-forwarder route and fails closed when it is zero:

```cpp
const intptr_t sites = MaotRegistry::CallSiteCountAt(thread, entry);
converges = sites > 0;
```

It is durable descriptor state and is not a candidate. That removes one of the
nine before any design work.

The two inline counters are written by the inliner during precompilation and
read only by the precompiler and by `Dart_MaotDumpForTesting`. They are
API-observable, which is what the regression harnesses read, so removing them
from the image would change an observable surface for 2/26 of one array.

**Six fields are genuinely transaction-only**, and that they are null in every
serialized image is not an inference: `MaterializeMutableAotRegistry` rebuilds
the final registry from twelve kept vectors — ids, functions, abis, call
conventions, cells, call-site counts, pool indices, inline counts, escapes,
escape reasons, selection — and **none of them is a staged field**.

### The maximum is ~11 KB, not ~43 KB

The registry array is one node of 124,863 B holding 1,853 × 26 = 48,178 slots.
The snapshot writes each slot as a varint object reference, so a slot's cost
depends on its value: a null reference is a small base-object id (1 byte), a
String/Function/Code reference is a mid-table id (3 bytes). That model gives

```
20 populated slots x 3 B  +  6 null slots x 1 B  =  66 B per entry
66 x 1853 = 122,298 B     measured 124,863 B     (within 2%)
```

so removing six null slots per entry saves about **6 x 1,853 = 11,118 B**, not
the 2.6 B/slot average that the first estimate of ~43,200 B assumed. The
average is the wrong multiplier precisely because the slots being removed are
the cheapest ones in the array.

Cross-check on the same model: arm C's registry array is 128,569 B, +3,706
over arm B for the *same* 48,178 slots — 2.0 B per entry of pure re-encoding
as installed cells point at higher object ids. Slot cost is value-dependent,
as the model requires.

### Blast radius of the sidecar

The storage is flat — `storage.At(entry * kEntrySize + field)` — so a
variable-length row is not possible. A sidecar means:

* `maot_registry.h`: split `EntryField` into durable and staged, add
  `kDurableEntrySize`, declare `StagedFieldAt` / `SetStagedFieldAt`;
* `maot_registry.cc`: change the stride in `FieldAt`, `SetFieldAt` and
  `Length`; rewrite ~20 staged accesses across `StageReplacement`,
  `CommitStagedForTesting`, `AbandonStagedForTesting`, `HasStagedFor`,
  `AnyEntryHasStagedOrAdvanced`, `ClassifyCodePointer` and `DumpToFile`;
  add lazy allocation;
* a new GC root for the sidecar (an `ObjectStore` field, which is itself
  serialized).

That is a change to the stride of the array holding every declaration
descriptor — the structure the six frozen identities, the transaction path and
the fail-closed refusal gates all index into — for **11 KB, 0.08% of the 13.89
MB snapshot and 1.6% of the +686,528 B policy overhead**.

**Stopping here, under the standing rule**: the measured maximum is well under
the 43 KB threshold and the implementation is invasive by the only definition
that matters — it moves descriptor addressing. The prototype is described
above rather than built; say the word and it gets built, but the recommendation
is not to.

## 2. Declaration IDs — decomposition and three options

1,853 ids, all distinct, **201,004 characters**, costing **244,624 B** in the
image (23.5 B of per-object header and padding on top of the characters).
Length: min 49, median 104, mean 108.5, max 203.

```
component                          bytes    share   avg/id
lib: prefix + library URI        102,883    51.2%     55.5
member kind + name                55,344    27.5%     29.9
cls:<Owner> segment               35,617    17.7%     19.2
"::" separators                    7,160     3.6%      3.9
```

Distinctness — this is where the cost is:

```
library URIs      71 distinct    3,547 chars   repeated across 1,853 ids
owner names      207 distinct    3,681 chars
member names     998 distinct   33,804 chars
kinds              9 distinct    ctor enum factory fn get method mixin op set
```

Storing each library URI once instead of 1,853 times recovers **99,052
characters — 49% of the id text — on its own.** A further 16,005 characters
(8.0%) are library URIs embedded a *second* time inside the member name, as
the privacy disambiguator on 295 private members
(`...::method:_transform@package:vm/...`). There are no `@<digits>` hash
disambiguators at all.

### Option 1 — keep the canonical text

| | |
|---|---|
| bytes | 244,624 (baseline) |
| deterministic across builds | yes |
| collisions | impossible; the text is the identity |
| debuggability | full — every refusal, dump and API call names the declaration |
| migration / versioning | none |
| external tooling | consumes it today: kernel metadata (`writeStringReference`), `Dart_MaotInstallForTesting`, `Dart_MaotCurrentVersionForTesting`, the registry dump, every harness |

### Option 2 — interned components plus a record (recommended)

Store `{library, owner, kind, member}` as references into interned tables; the
id text is reconstructed on demand.

| | |
|---|---|
| bytes | ~93–115 KB (1,276 interned strings, 41,032 chars, plus a 4-slot record per declaration) |
| saving | **~130–152 KB** |
| deterministic across builds | yes — same components, same order |
| collisions | impossible; the 4-tuple *is* the id |
| debuggability | full — the text is reconstructible exactly, so dumps and refusals read as they do today |
| migration / versioning | **none at any boundary.** Kernel metadata and the install API keep passing text; only the VM-side storage changes |
| external tooling | unaffected |

The 295 private members would also stop paying for their embedded URI twice,
since the owning library is already a component.

### Option 3 — compact hash-backed identity

A 16-byte digest per declaration in one flat `TypedData`.

| | |
|---|---|
| bytes | 29,648 + one header |
| saving | **~215 KB** |
| deterministic across builds | yes, if the digest is taken over the canonical text |
| collisions | ~1e-34 by the birthday bound at 1,853 items, but *collision-safe canonical resolution* means keeping the text to verify against — which returns most of the saving unless the check happens at build time and a collision fails the build |
| debuggability | **lost at run time.** A refusal names a hash; a side map must ship separately or in a debug build |
| migration / versioning | **required.** The digest becomes part of the patch format: the install API and the kernel metadata must agree on it, and patches from older tooling stop matching |
| external tooling | anything inspecting a patch sees hashes rather than names |

**Recommendation: option 2.** It captures 60–70% of option 3's saving, changes
no format at any boundary, keeps every diagnostic readable, and has no
collision story to get wrong. No implementation is proposed; this is the
design note the ruling asked for.

## 3. The C − B character data is explained

The 14,832 B was never string metadata. The 630 KB `(RO) String` node has
exactly one in-edge, from `<artificial root>`, named
**`<instructions-table-rodata>`** — it is the instructions table, and the
profile types it as a string because it is a raw byte region.

```
arm   <instructions-table-rodata>   Instructions objects
A     630,528                       19,899
B     631,808   (+1,280)            20,093   (+194)
C     646,640   (+14,832)           21,946   (+1,853)
```

`14,832 / 1,853 = 8.00` bytes **exactly** per added `Instructions` object. It
belongs to the trampoline cost, not to an unexplained category, and the
per-trampoline `.rodata` now accounts in full:

```
Code object                 10.00 B
instructions-table rodata    8.00 B
dispatch cell contents       2.00 B
Function / DispatchTable     0.25 B
                            ------
                            20.25 B   measured 20.3 B
```

The B − A ratio is 1,280 / 194 = 6.6 B rather than 8.0, consistent with the
170 shared bodies sharing table entries and with alignment. The C − B step has
no sharing and lands on 8.00 exactly.

**Open attribution items: none.**

## Reproduce

All three sections read the profiles Stage 44 already wrote, plus the arm B
registry dump:

```
selfhost/engine/mutable_aot/m5/lib/stage44_m5.py
selfhost/engine/mutable_aot/m5/lib/stage44b_m5.py
selfhost/engine/mutable_aot/m5/lib/stage44c_m5.py
```
