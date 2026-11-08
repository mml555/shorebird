# Patch → Mutable-AOT ingestion: architecture trace

Fork `5878283d55e`. **No code changed.** Items A–D are complete and read
directly from source. Item E is PARTIAL — see the blocker at the end.

**Verdict: Option 3, with one large mitigating fact.** The production patch
format carries no AOT bodies. But it does carry independently usable
replacement bodies as **bytecode**, and those already materialize as real VM
`Function` objects inside the running isolate. So this is not "a compiler
output stage is missing from zero"; it is "the body that exists is the wrong
representation for the cell's executable half."

---

## A. What is actually in a production patch

Traced through `route_b_patch.cc` and `shorebird.cc`, by bytes and loaders.

### Container layout (`SBRBPTCH`, format version 1)

```
offset 0   magic[8]      "SBRBPTCH"
offset 8   u32 LE        formatVersion, must == 1
offset 12  u32 LE        headerLen
offset 16  headerLen     JSON header
offset 16+headerLen      payload blob region
```

JSON header, all fields required or the parse fails `kMalformed`:

```json
{ "release": { "buildId": "<string>" },
  "targets": [ { "library": "<uri>", "selector": "<name>",
                 "offset": <u64>, "length": <u64>, "sha256": "<hex64>" } ] }
```

Each payload is sha256-verified against its declared digest **before** any
attach. Zero targets is refused rather than treated as inert.

### What the payload bytes ARE

**Dart bytecode**, in the dynamic-modules format — not machine code, not
snapshot data, not kernel. Established by the consumer, not the field name:

```cpp
bytecode::BytecodeLoader loader(thread, typed_data);
loaded = loader.LoadBytecode();                       // -> Function
...
const auto& bc = Bytecode::Handle(zone, loaded.GetBytecode());
if (bc.IsNull()) return Dart_RouteB_InvalidBytecode;  // "payload carries no bytecode"
```

The whole implementation is inside `#if defined(DART_DYNAMIC_MODULES)`.

### Do changed declaration identities survive into it?

**Only as two loose strings.** A target is identified by `library` (URI) and
`selector` (name). Nothing else about identity is carried.

### Do replacement Function/Code-like objects exist after loading?

**A `Function` — yes. A `Code` — no.** `LoadBytecode()` returns a real, live
`Function` in the running isolate group, whose body is a `Bytecode` object.
It has no AOT `Code`.

---

## B. What exists at `Dart_RouteBActivatePatchTraced` time

Mechanical inventory, from `runtime/lib/object.cc:998` onward.

| thing | available? | how |
|---|---|---|
| patch path / handle | no | embedder resolved it already; only a byte pointer arrives |
| payload bytes | **yes** | `const uint8_t* payload, intptr_t payload_length` |
| owned copy of payload | **yes** | `::malloc` + `memcpy`, wrapped in an `ExternalTypedData` because "the loader keeps a reference beyond this call" |
| mapped executable regions | **no** | nothing is mapped executable; there is no relocation step |
| snapshot structures | no | the patch is not a snapshot |
| isolate / group | **yes** | `Thread::Current()`, `DARTSCOPE`, and a `SafepointWriteRwLocker` on `isolate_group()->program_lock()` |
| declaration metadata | **strings only** | `library_uri`, `target_name` |
| replacement `Function` | **YES — materialized** | `loader.LoadBytecode()` |
| replacement `Bytecode` | **YES** | `loaded.GetBytecode()` |
| replacement AOT `Code` | **NO** | never produced anywhere in this path |
| base target `Function` | **yes** | `ResolvePatchTarget(thread, zone, uri, name)` |
| base target's original `Code` | **yes** | `target.CurrentCode()`, saved by `RouteBSaveOriginalCode` |
| patch version | **no** | the container has `release.buildId`; no per-target version |

So the answer to the question that decides the architecture:

> **The replacement body is already materialized but unconnected — as a
> `Function` with a `Bytecode` body, not as AOT `Code`.**

What Route B does with it today is mutate the base function in place:

```cpp
RouteBSaveOriginalCode(thread, target, original);
target.AttachBytecode(bc);   // ends in SetInstructions(StubCode::InterpretCall())
```

That is a different mechanism from Mutable-AOT, not a smaller version of it:
Route B rewrites the *base* `Function`'s entry point to the interpreter, where
Mutable-AOT leaves every `Function` alone and swaps a dispatch cell.

---

## C. The exact missing edge

```
PATCH ARTIFACT  (SBRBPTCH container: JSON header + per-target payload)
      |
      v
route_b::Parse            magic, version, sha256 per payload
      |
      v
bytecode::BytecodeLoader::LoadBytecode()
      |
      v
Function  (body = Bytecode; CurrentCode() is NOT an AOT body)   <-- last object that definitely exists
      |
      X   <---- MISSING EDGE
      |
      v
Code      (a real, non-trampoline, pinned AOT body)             <-- what the cell's executable half requires
      |
      v
MaotRegistry::StageReplacement(..., const Function& implementation, ...)
      |
      v
cell.SetAt(kCellImplFunction, staged_impl)
cell.SetAt(kCellImplCode,     staged_body)
      |
      v
stable cell -> replacement Code
```

### Data type on each side of X

* **Left of X:** `Function` whose `GetBytecode()` is a `Bytecode` object.
  Produced by `BytecodeLoader`. Lives in the isolate group. No `Code`.
* **Right of X:** `Code` — specifically `PinnedBodyCodeFor(thread, staged_fn)`,
  required non-null, required not to be any trampoline.

### Where it actually refuses

`StageReplacement` itself would **accept** a bytecode-bodied `Function`: it
stores `implementation` into `kStagedImpl` and never inspects its code. Its
seven gates are declaration existence, namespace, ABI descriptor equality,
`unrepresentable:` rejection, calling convention equality, `kEscapeCount == 0`,
and a strictly advancing version.

The refusal is one step later, in the commit:

```cpp
const auto& staged_body = Code::Handle(zone, PinnedBodyCodeFor(thread, staged_fn));
...
if (next_code.IsNull()) {
  // "No pinned body for the replacement. Refuse: a cell with no executable
  //  half, or one filled from a trampoline, is worse than a refused install."
  return false;
}
```

So the missing edge is **not** an exported symbol, and **not** the staging
contract. It is that nothing produces an AOT `Code` for a patch-delivered body.

---

## D. Identity correspondence

**The patch cannot currently map to a `DeclarationId` without fuzzy matching.**

| side | identity |
|---|---|
| container target | `library` (URI string) + `selector` (name string) |
| MAOT registry | 4-tuple `kIdLibrary` / `kIdOwner` / `kIdKind` / `kIdMember`, interned and round-trip verified |

The container carries the library URI, which plausibly corresponds to
`kIdLibrary`. It does **not** carry the owner (enclosing class), the kind
(getter/setter/method/constructor), or a member name separated from the owner.
`selector` is a single flat string.

Concretely: `kIdOwner` and `kIdKind` have no source in the container, so
recovering a `DeclarationId` from a target would require parsing `selector`
and guessing — exactly the fuzzy matching to avoid. And Route B's own
`ResolvePatchTarget` is a *name lookup*, not an identity match; it is why
`Dart_RouteB_TargetMissing` exists as a distinct code.

**Stated as instructed, with no second identity scheme invented:** current
patch metadata lacks the stable declaration ID.

Also absent: a per-target **version**. `StageReplacement` requires a strictly
advancing integer version, and the container has only a release `buildId`.

---

## E. Executable-code ownership — PARTIAL

What the trace established before access was lost:

* **Route B owns no executable code at all.** The payload is copied into
  malloc'd memory owned by an `ExternalTypedData`, which is a GC-visible heap
  object — that is the entire lifetime story. There is no executable mapping,
  no relocation step, and no `mprotect`/`PROT_EXEC` anywhere in the path,
  because the body is interpreted rather than jumped to.
* **GC reachability** for the replacement is via ordinary heap references:
  the `Bytecode` hangs off the `Function`, which Route B attaches to the base
  `Function`. Mutable-AOT's equivalent is the cell `Array(2)` and the registry
  entry, both ordinary heap objects.
* **Base↔patch cross-references** are already routine in this design, since
  both objects live in the same isolate group heap.

### Not established, and it blocks the rest of E

The remaining sub-questions — how the two platforms map executable AOT code
today, whether iOS and Android already solve relocation/ownership somewhere in
Route B, and behaviour across isolate shutdown — need the engine tree, and:

```
/Volumes/build  is mounted rw with no I/O errors, but every path under it,
including the mount root, returns EPERM ("Operation not permitted").
```

POSIX ownership and mode are intact (`drwxrwxr-x mendell staff`), the sandbox
is not the cause (the same read fails with it disabled), and `diskutil`
reports the volume healthy and writable. That signature is macOS TCC
withdrawing access to the volume for the calling process. It is not a disk
fault and not something this session can grant itself.

**One strong partial answer does exist:** the two production platforms take
*different* paths, which is itself relevant to "do not create a parallel
loader."

```cpp
#if SHOREBIRD_USE_INTERPRETER      // iOS
  settings.application_library_paths.insert(begin, active_path);
#else                              // Android
  if (PatchCarriesCode(active_path)) {
    settings.application_library_paths.clear();
    settings.application_library_paths.emplace_back(active_path);
  }
#endif
```

Android's ordinary (non-Route-B) patching replaces **the entire `libapp.so`
snapshot at boot**, before the VM starts. iOS uses the interpreter. Neither
loads new AOT machine code into a *running* isolate.

So the provisional answer to "does Shorebird already have an executable-code
loader we should not duplicate" is **no** — and that should be confirmed once
the volume is readable, because it is the fact that most constrains the
architecture.

---

## Which option this is

**Option 3.** The current production patch format does not carry independently
usable replacement *AOT* bodies. Mutable-AOT is missing a patch-format and
compiler-output stage, not merely a runtime hook.

Two things keep this from being the worst case:

1. The delivery, integrity, release-gating and activation machinery all exist
   and work, and the activation seam is already proven to survive Android's
   version script.
2. A replacement body genuinely materializes in the running isolate as a
   `Function`. The gap is representation (`Bytecode` vs AOT `Code`), not
   absence.

And, explicitly: **no precompiled-in-base test body is being used to disguise
this.** That is exactly what `Dart_MaotInstallForTesting` does, and it is why
the iOS PASS proves the mechanism rather than delivery.

Awaiting a ruling. Item E's remainder is queued behind volume access.
