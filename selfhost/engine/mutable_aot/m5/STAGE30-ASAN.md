# STAGE30 — ASan on REALAPP_MAOT_SELECTION_PRECOMPILER

Fork `24fdf304b74` (clean). Diagnostic ASan build at
`out/maot_asan` (`is_asan=true`, `enable_lto=false`, `stripped_symbols=false`,
`is_official_build=false`). **Diagnostic instrumentation, not evidence of
production correctness.** No MAOT semantics were changed to make it build.

## 1. Paired result

| arm | kernel sha256[:16] | result |
|---|---|---|
| A control (normal selection) | `611e686fa80474b1` | **rc=0, clean under ASan** |
| B select-all, install OFF | `8085f498edf0a673` | **SEGV, ASan report** |

Only B reports. Per the ruling's control, that is strong localization: this is
not ordinary precompiler sanitizer noise.

**A constraint on the control, stated rather than glossed:** selection is baked
into the kernel by `MAOT_SELECT_ALL_NON_SDK` at `gen_kernel` time, so "the same
kernel with select-all off" is not constructible. Arm A is a separate kernel
from the same source, differing only by that env var.

## 2. The first invalid operation

```
ERROR: AddressSanitizer: SEGV on unknown address 0x2e6c69e475677461
The signal is caused by a READ memory access.
    #0 dart::CodeRelocator::ScanCallTargets(Code const&, Array const&, long)
    #1 dart::CodeRelocator::Relocate(bool)
    #2 dart::Serializer::PrepareInstructions(CompressedStackMaps const&)
    #3 dart::Serializer::Serialize(SerializationRoots*)
    #4 dart::FullSnapshotWriter::WriteProgramSnapshot(...)
    #5 dart::FullSnapshotWriter::WriteFullSnapshot(...)
```

`x[20] = 0x2e6c697475657461` — the register holding the faulting operand is
also ASCII-like text.

**ASan reported no earlier memory-safety violation** — no use-after-free, no
overflow, no use-after-scope. Its first and only report is this SEGV.

## 3. A retraction

STAGE29 concluded that relocation completes, because `RELOC_WRAP END Relocate`
printed twice. That marker does wrap the real `CodeRelocator::Relocate` call,
and it did print twice — but the ASan stack puts the fault **inside**
`ScanCallTargets`, under `Relocate`.

Both observations are real because **the two builds fault at different
points**:

| build | si_addr | where |
|---|---|---|
| production (LTO, official) | `0x617a696c61697265` stable | after relocation, before `POST END PrepareInstructions` |
| ASan (no LTO, unstripped) | `0x2e6c69e475677461` | inside `ScanCallTargets` |

A defect whose manifestation point moves with build layout is consistent with
corruption rather than a deterministic bad statement. The marker-derived
location in STAGE29 described the production build only and must not be read
as the defect's location.

## 4. Where this points

`ScanCallTargets` reads `destination_ = GetTarget(call)` from a Code's
static-call target table, and `GetTarget`'s `ASSERT(target_.IsCode())` is
compiled out in these builds. A table entry holding something that is neither
Code nor AbstractType would flow through `Code::Cast` and be dereferenced —
which matches a faulting address made of text.

That is a **lead, not a finding**. It has not been measured.

This is the same function as the STAGE20 defect, but that defect is not
implicated: this configuration installs **no trampolines**, so there are no
registry pins in the walk.

## 5. The authorized class measurement: two hypotheses, both refuted

**Measurement 1 — the target slot.** Instrumented immediately before
`GetTarget(call)` would consume it: raw value printed before any
classification (classifying reads the object header, which is what may fault),
plus class id, `IsCode`, `IsAbstractType`, owner, index, kind, return-pc
offset, and neighbouring entries.

**Result: no `BAD_SCALL_ENTRY` ever fired, and it still crashed.** Every target
slot reached was Code, AbstractType, or null. The §4 lead — that the slot holds
something of the wrong shape — is **refuted**.

**Measurement 2 — the other two inputs.** The kind/offset Smi is read *before*
the target slot, and a bad offset feeds
`code.PayloadStart() + call_instruction_offset`, which reads raw instruction
memory — a better match for a text-like fault address than the target cast.
Checked: the entry is a Smi, the decoded offset lies within `code.Size()`, and
the table length is a multiple of `kSCallTableEntryLength`.

**Result: no `BAD_SCALL_SHAPE` ever fired, and it still crashed.** Refuted too.

One input remains unvalidated, and it weakens measurement 2: `code.Size()` is
derived from the caller Code's own `instructions_`. If that pointer is corrupt,
the bounds check passes vacuously. Validating the caller Code itself is the
next measurement, and it is the STAGE20 signature reached by a different route
— though this configuration installs no trampolines.

## 6. Address behaviour differs between builds

| build | address |
|---|---|
| production/LTO | `0x617a696c61697265`, identical every run |
| ASan | `0x2e6c69e475677461`, `0x747265706f72703a`, `0x205d74726164` — varies per run |

All are ASCII-like. ASan randomises allocator layout, so varying addresses
there do not by themselves establish nondeterminism.

## 7. Next

UBSan, per the ruling's priority order, plus the caller-Code validation above.

ASan produced a stack but **no memory-safety violation at all** — no
use-after-free, overflow, or use-after-scope — which together with three
refuted input hypotheses is approaching the stated debugger triggers (1) and
(3). Not requesting the debugger yet: UBSan is owed first.
