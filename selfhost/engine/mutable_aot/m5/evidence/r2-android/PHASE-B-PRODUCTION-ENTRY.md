# R2 Android — Phase B check 3 completed, and the production-entry mapping

Fork `5878283d55e`, clean. Two PM-directed items, then the answer to the
architectural question. **No code changed.**

---

## Part 1 — Check 3 is now COMPLETE (offline, no device)

The Android `gen_snapshot` produced an ELF AOT snapshot from the R2 fixture
kernel, and the Mutable-AOT pipeline ran inside it:

```
gen_snapshot --snapshot_kind=app-aot-elf --elf=libapp.so r2/app.dill
  rc=0, 5,016,584 B, 18.2 s
  [maot] DECLARATION_IDS entries=19 structured=19 roundtrip_ok=19 roundtrip_fail=0
  [maot] RELEASE_EDGES  recorded=50 consumed=50 missing=0 pending_at_end=0
```

### Snapshot configuration string, read from the snapshot bytes

```
a017f0159cc650151f56047aad3763ee
product no-code_comments no-dwarf_stack_traces_mode dedup_instructions
no-asan no-msan no-tsan no-shared_data  arm64 android  compressed-pointers
```

### Runtime configuration, read from `libflutter.so`

`Dart::FeaturesString` (runtime/vm/dart.cc) emits exactly one literal from each
of two `#if` chains: `" ia32"|" x64"|" arm"|" arm64"|" riscv32"|" riscv64"` and
`" android"|" fuchsia"|" ios"|" macos"|" linux"|" windows"`. So counting which
NUL-terminated literals exist in the binary identifies the compiled-in target.
Raw byte search (tail-merge safe), whole file:

```
OS     android=1  ios=0  macos=0  linux=0  windows=0  fuchsia=0
ARCH   arm64=1    x64=0  arm=0    ia32=0   riscv32=0  riscv64=0
```

### The probe falsifies in both directions

Same probe, three runtimes with three known-different targets:

```
android  libflutter.so    -> arm64 android
ios      Flutter          -> arm64 ios
host     dartaotruntime   -> arm64 macos     <- the artifact that failed iOS
```

It re-identifies the macOS host runtime that caused the earlier iOS mismatch,
so it is not a probe that says "android" regardless of input.

### Result

```
version hash        a017f0159cc650151f56047aad3763ee  ==  runtime
snapshot config     ... arm64 android compressed-pointers
runtime target      arm64 android
```

**Both dimensions now PASS on Android.**

---

## Part 2 — Two corrections to the Phase-B report

### 2a. Count: eight exports, not seven

`android_exports.lst` lists **eight** `shorebird_*` symbols. My Phase-B report
said seven. The list is lines 14–21 of that file; the count is `grep -c` = 8.

### 2b. The causal claim, narrowed — with a positive control

Dropping the `--icf=all` attribution as directed. The proven statement is:

> `android_exports.lst` excludes the wrappers from the public dynamic ABI, and
> the final link subsequently contains no surviving `Dart_Maot*` wrappers.

The same binary supplies a **positive control** that sharpens this without
needing a link map. `Dart_RouteBActivatePatchTraced` carries the same
`DART_ROUTE_B_EXPORT` treatment as `MAOT_TEST_EXPORT`, is equally absent from
the allow-list, and is equally `local` — yet it **survives**:

```
Dart_RouteB* in .dynsym  = 0          (local, exactly like Dart_Maot*)
Dart_RouteB* in .symtab  = 1          0xb03f3c  t  Dart_RouteBActivatePatchTraced
Dart_Maot*   in .symtab  = 0
```

The difference is not visibility and not the version script. It is that
`Dart_RouteBActivatePatchTraced` **has an internal caller inside
libflutter.so** — `flutter::InstallRouteBActivationHook`'s isolate-create
lambda, also present in `.symtab` — whereas every `Dart_Maot*` wrapper's only
intended caller is external FFI, which the version script forbids. A local
symbol with an in-library caller survives; a local symbol without one does not.

---

## Part 3 — Production-entry mapping

### The eight exported symbols

| # | symbol | signature | impl | external caller | in activation? | patch/version/declaration data reaching it | can host StageReplacement? |
|---|---|---|---|---|---|---|---|
| 1 | `shorebird_init` | `(const AppParameters*, FileCallbacks, const char*) -> bool` | `c_api/engine.rs:123` | engine C++ `updater.cc:113`; exported for embedders | setup only | release version, libapp paths, storage/cache dirs, yaml — **no patch bytes, no declarations** | **No** — runs before any isolate exists |
| 2 | `shorebird_free_string` | `(const char*) -> void` | `c_api/engine.rs:113` | engine `updater.cc:125`, and FFI callers | no | nothing | **No** — deallocator |
| 3 | `shorebird_free_update_result` | `(UpdateResult*) -> void` | `c_api/dart.rs:132` | `shorebird_code_push` via FFI | no | nothing | **No** — deallocator |
| 4 | `shorebird_check_for_downloadable_update` | `(const char* channel) -> bool` | `c_api/dart.rs:97` | `shorebird_code_push` via FFI | query only | channel name; returns a bool | **No** — downloads nothing |
| 5 | `shorebird_update_with_result` | `(const char* channel) -> const UpdateResult*` | `c_api/dart.rs:115` → `updater::update` (`updater.rs:767`) | `shorebird_code_push` via FFI | **downloads + installs, sets `next_boot`** | channel in; `{status, message}` out. Patch bytes touch disk, **never the caller** | **No** — see below |
| 6 | `shorebird_next_boot_patch_number` | `() -> uintptr_t` | `c_api/dart.rs:82` | `shorebird_code_push` via FFI | query only | patch **number** only | **No** |
| 7 | `shorebird_current_boot_patch_number` | `() -> uintptr_t` | `c_api/dart.rs:71` | `shorebird_code_push` via FFI | query only | patch **number** only | **No** |
| 8 | `shorebird_validate_next_boot_patch` | `() -> void` | `c_api/engine.rs:158` | engine-side; exported for embedders | validate/tombstone | nothing in, nothing out | **No** |

Note on #5, the only plausible candidate: `updater::update()` downloads,
validates and installs to disk and sets `next_boot`. Its own header states the
contract — *"It will boot from the update on the next app launch."* Making it
activate in-process would preserve the C signature while inverting the
documented semantics, which is an ABI change in everything but the symbol table.

### The production activation boundary is not any of the eight

It already exists, and it is entirely internal:

```
Updater::PrepareNextBootPatch()                    [C++; shorebird_prepare_next_boot_patch,
                                                    which is NOT in android_exports.lst]
  -> ConfigureShorebird(): route_b::SniffFile(active_path)     content sniff, boot-safety
  -> InstallRouteBActivationHook(settings, route_b_path)       "SEAM 6", shorebird.cc:347
  -> settings.root_isolate_create_callback                     fires once the root isolate exists
       -> route_b::Parse + payload sha256
       -> Dart_RouteBReleaseBuildId() vs container release id
       -> Dart_RouteBActivatePatchTraced(bytes, len, library, selector, ...)  per target
```

Every step is an in-library call. **Nothing in this path needs a dynamic
export, and the path is already proven to survive the Android link** (Part 2b).
That is a stronger position than the PM's preferred architecture: the boundary
is not an exported ABI that must be widened, it is an internal seam.

### But nothing can flow through it yet — the real blocker

`MaotRegistry::StageReplacement` has exactly **two** callers in the entire
tree:

```
maot_registry.cc:1481   MaotRegistry::InstallForTesting   <- reached only by Dart_MaotInstallForTesting
maot_registry.cc:2018..2173  MaotRegistry::RunSelfTest    <- self-test
```

Nothing under `shell/` calls it; every other match in the tree is a comment.
And `InstallForTesting` takes an **`implementation_id`** which it resolves with
`IndexOf(thread, implementation_id)` — i.e. the replacement body must be a
declaration **already compiled into the running release**. It swaps declaration
A's dispatch cell to declaration B's body, where A and B both shipped.

So Mutable-AOT has **no patch-ingestion path at all**. The Route B seam
delivers *container bytes* to an interpreter attach; StageReplacement consumes
an *in-snapshot `Function`*. There is no bridge, on any platform.

### Answer to the question asked

> Can Mutable-AOT replacement be placed behind an existing Shorebird production
> activation boundary?

**Architecturally yes; functionally not yet.** The boundary is
`InstallRouteBActivationHook`, it is internal, and it survives Android's
version script today. What is missing is not an export — it is that no
production path exists which turns patch content into a stageable
implementation. The 12 `Dart_Maot*` wrappers are not an under-exported
production API; they are the *only* API, and 11 of the 12 are diagnostics.

This is the PM's fallback case. Evidence is brought back; **nothing invented,
nothing implemented.**

### What this means for the R2 Android smoke

R2 cannot exercise a production entry that does not exist. The available
options, not chosen here:

1. Run the Android smoke through `MaotRegistry::RunSelfTest`, which is already
   an internal caller and therefore already survives the version script with no
   ABI change at all. It exercises real `StageReplacement` calls. It is a
   self-test, not the production replacement path — so it would be a
   **conformance** result (the Android runtime stages and commits correctly),
   explicitly not a production-replacement result.
2. Define the ingestion path first and make R2 exercise that. Larger, and it is
   the thing actually missing.
3. Record Android as blocked on ingestion and keep iOS's PASS scoped to what it
   proved — which, given the above, was also `Dart_MaotInstallForTesting`
   swapping between two in-release declarations.

**Option 3 has a consequence for a result already accepted:** the iOS R2 PASS
demonstrated the *runtime mechanism* on device, not production patch delivery.
That was true when it was accepted and the Android work is what surfaced it.
Flagging it rather than restating the iOS conclusion unchanged.

Awaiting a ruling.
