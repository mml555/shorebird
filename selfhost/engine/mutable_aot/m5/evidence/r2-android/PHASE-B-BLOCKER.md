# R2 Android — Phase B: production API visibility FAILS

Checks 1–3 pass. Check 4 fails, and the cause is an explicit engine export
policy, not a Mutable-AOT defect and not the visibility attributes.

**Stopped as instructed. No JNI wrapper, no `--export-dynamic`, no visibility
change, no version-script exception, no additional shared library, no test
bridge.**

## 1. Runtime provenance — PASS

```
fork                5878283d55e, clean tree (0 dirty files)
libflutter.so       174,394,544 bytes, built 2026-09-25 03:33
                    ELF64, AArch64
   sha256           6b542d5366d65879dc773bfb55c526f3f24c09545eafcb1d7b6c7a634b142954
args.gn             target_os=android target_cpu=arm64 dart_target_arch=arm64
                    flutter_runtime_mode=release dart_version=5878283d55e
```

## 2. Generator provenance — PASS

```
out/android_release_arm64/clang_arm64/gen_snapshot
   7,288,880 bytes, built 2026-09-25 03:29
   sha256   8959594397bda0272a8d62177051ee54155a872f01ea49788bed95a9d0b75a84
   Mutable-AOT implementation present (35 maot_ flag strings; the stronger
   evidence would be a generated fixture, which check 4 blocks)
```

## 3. Snapshot version agreement — PASS

```
generator version hash   a017f0159cc650151f56047aad3763ee
runtime   version hash   a017f0159cc650151f56047aad3763ee
```

Identical, and the same value as the iOS pair. The **target configuration**
half of the rule could not be completed: on Android the configuration string
is assembled at runtime rather than stored contiguously, so it can only be
read out of a generated snapshot — which requires getting past check 4.

## 4. Production API visibility — FAIL

```
libflutter.so .dynsym    562 symbols, Dart_Maot* = 0, Dart_* = 0
libflutter.so .symtab    152,932 symbols (NOT stripped)
                         Dart_*        = 115
                         Dart_Maot*    = 0
                         MaotRegistry::= 20 mangled symbols
                         maot_ flag strings = 45
```

So `maot_registry.o` **is** linked into the production library — its class
methods and flag strings are present — and only the `extern "C"` entry points
are gone.

### The declarations are unchanged and identical to the iOS build

```cpp
#define MAOT_TEST_EXPORT \
  extern "C" __attribute__((visibility("default"))) __attribute__((used))
```

### They are present in the intermediate object

```
obj/flutter/third_party/dart/runtime/vm/libdart_vm_aotruntime.maot_registry.o
   Dart_Maot* symbols = 12
   Dart_MaotInstallForTesting -> defined, T (external text)
```

### The linker configuration is what removes them

From `obj/flutter/shell/platform/android/flutter_shell_native.ninja`:

```
ldflags = -Wl,--version-script=../../flutter/shell/platform/android/android_exports.lst
          -Wl,--fatal-warnings -Wl,-z,defs -Wl,--no-undefined -Wl,--icf=all ...
```

`flutter/shell/platform/android/android_exports.lst` is an **allow-list**:

```
{
  global:
    JNI_OnLoad;
    _binary_icudtl_dat_start;
    _binary_icudtl_dat_size;
    InternalFlutterGpu*;
    kInternalFlutterGpu*;
    shorebird_init;
    shorebird_free_string;
    shorebird_free_update_result;
    shorebird_check_for_downloadable_update;
    shorebird_update_with_result;
    shorebird_next_boot_patch_number;
    shorebird_current_boot_patch_number;
    shorebird_validate_next_boot_patch;
  local:
    *;
};
```

Every symbol not named here is `local`, which is why **all 115** `Dart_*`
symbols are unexported, not just the Mutable-AOT ones. Being local and
unreferenced, and with `--icf=all`, the entry points are then discarded
entirely, which is why they are missing from `.symtab` too while the
internally-referenced `MaotRegistry::` methods survive.

### Why iOS behaved differently

The iOS framework links with `-dead_strip` and **no engine-wide export
allow-list** — the only `exported_symbols_list` on that link is libcxxabi's
`new-delete.exp`. On Mach-O, `__attribute__((used))` emits `.no_dead_strip`,
so `visibility("default")` is sufficient and the symbols survive.

On ELF with an explicit version script, visibility attributes are irrelevant:
only membership of the allow-list matters. **This is a platform export-policy
difference, not a difference in the Mutable-AOT code.**

## The decision this needs

`android_exports.lst` already carries seven `shorebird_*` entries, so adding a
platform's entry points to this list is an established pattern here — the
direct analogue of iOS's pre-existing `_Dart_RouteBActivatePatchTraced`.

But adding to it changes the **public ABI surface of the production
`libflutter.so`**, which is a product decision rather than a build fix, and the
symbols in question are named `...ForTesting`. That is the ruling required.
