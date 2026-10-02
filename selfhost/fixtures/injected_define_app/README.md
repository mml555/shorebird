# `injected_define_app` — G4.1c's discriminating fixture

The specimen the integration arm could not be. Release 40 of `airgap_app` showed
that the G4.1c CLI still traverses the real iOS release → patch path and could
show nothing else, because that fixture reads none of Flutter's injected defines
and its kernels are byte-identical with and without them.

**This fixture's behaviour depends on `FLUTTER_VERSION`, a define Flutter injects
into every build and no user may set.**

## The one question it answers

> Can a real, reachable Dart program whose behaviour depends on a
> Flutter-injected define be analysed and patched correctly, end to end, by the
> G4.1c path?

It spans **two different links**, and they have different answers today:

| link | mechanism | status |
|---|---|---|
| **1 — analysis** | do Route B's prepass/import kernels describe the program Flutter compiles? | **fixed** by G4.1c. Measured byte-identical |
| **2 — replacement** | is a PATCH BODY compiled with the defines the release around it holds? | **STILL BROKEN**. See below |

## Link 2 is a real, open defect — found by this fixture

`route_b_producer.dart:169` feeds the replacement compiler
`buildConfig.compilerArgs`, and `route_b_build_config.dart:345` builds those from
`effectiveDefines` **alone** — which G4.1c deliberately leaves the injected six
out of, on the argument that a release and a patch on one pinned cell always
agree on them.

**That argument is sound for COMPARISON and wrong for PROPAGATION.** The
fingerprint is also the source of the `-D` flags handed to the patch compiler, so
excluding the six from it excludes them from the patch body's compilation too. A
replacement reading `const String.fromEnvironment('FLUTTER_VERSION')` bakes the
**empty string** while the release around it holds `3.44.8`.

`route_b_producer.dart`'s own comment states the failure mode exactly, for user
defines: *"a replacement reading a define would silently bake in the DEFAULT
while the release around it holds the real value — a divergence no runtime check
can see, because both are literals by then."* It now applies to the injected
family.

Measured by `probes/g41d_injected_define_patch.sh`, arms 3–5, with a mechanism
control proving user defines **do** propagate — so this is a specific missing
family, not a broken mechanism.

## The three invariants this file must keep

Break any one and an arm on it proves nothing.

1. **REACHABLE, not merely present.** Retention is not reachability. A
   `String.fromEnvironment` read in dead code would satisfy a careless reading of
   "depends on an injected define" and demonstrate nothing.
   `injectedDefineProbe()` is called from `initState` and its result is displayed
   and beaconed.
2. **NOT CONSTANT-FOLDABLE AT THE CALL SITE.** A body returning one compile-time
   constant has its *result* substituted at the call site by the type-flow
   analysis even under `vm:never-inline` — the patched Function is still called
   and its answer overwritten, so a working mechanism reports as OLD. This has
   cost the project two investigations. Every value-bearing body routes through
   `DateTime.now()`.
3. **THE BRANCHES MUST RETAIN DIFFERENT SYMBOLS.** `versionGatedValue` and
   `unversionedValue` are separate functions, so the two programs cannot be
   confused.

## Two measured facts about the instruments, so nobody rebuilds an arm on them

* **`gen_kernel --aot` does NOT tree-shake.** Both branches are `reachable: yes`
  in both kernels; TFA runs later, at `gen_snapshot`. So "which symbol is live"
  is **not** a kernel-level observable — it becomes one only in a real AOT build,
  which is what makes the *device* arm meaningful and the host arm byte-based.
* **`route_b_analyze`'s `changed` does not see this difference.** A kernel built
  `-DFLUTTER_VERSION=zzz` and one built with the real value differ only in a
  constant inside `injectedDefineProbe`'s body, and the analyzer reports `NONE`.
  That is why the probe's link-1 arms compare **bytes**. `g41c`'s link-1 arms
  remain the analyzer-level proof — they put the branch in `main`, where it is
  seen.

## Preparing it

```sh
flutter create --platforms=ios --project-name injected_define_probe .
# flutter create overwrites lib/main.dart and pubspec.yaml — restore both
git checkout lib/main.dart pubspec.yaml
cp shorebird.yaml.template shorebird.yaml   # then fill in app_id and base_url
flutter pub get
```

`probes/g41d_injected_define_patch.sh` does exactly this into a **copy**; it never
writes to the committed tree.

## Release and patch forms

`lib/main.dart` is committed in its **RELEASE** form. The patch forms are
transient edits, and belong back the moment the patch is cut:

| target | release form | patch form |
|---|---|---|
| `versionGatedValue()` | `'OLD-gated'` | `'NEW-gated'` |
| `replacementReadsDefine()` | `'OLD-replacement'` | `'NEW-${const String.fromEnvironment('FLUTTER_VERSION')}'` |
| `replacementReadsUserDefine()` | `'OLD-user'` | `'NEW-${const String.fromEnvironment('PROBE_USER_KEY')}'` |

On a correct end-to-end path the device shows `injected-define probe: OLD-gated`
for a release — **never `OLD-unversioned`**, which would mean the shipped program
itself was compiled without Flutter's defines — and a patch of
`replacementReadsDefine` shows `NEW-3.44.8`, **not `NEW-`**.

## Status

**No release has been cut from this fixture and no device has run it.** The
host proof is `probes/g41d_injected_define_patch.sh` (10/10) and
`evidence/g41-injected-defines/`. The device/release arm waits for a clean rig
hand-back, exactly as the integration arm did.
