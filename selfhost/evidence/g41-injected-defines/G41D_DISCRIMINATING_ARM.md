<!-- cspell:words injdef killswitch -->
# G4.1c's discriminating arm — and the second link it found broken

**Host result. Earns BUILT for what it fixes and opens a KNOWN GAP for what it
finds.** No device, no release, no control plane; `~/.shorebird` was read only,
under a stamp guard.

## The one question

> Can a real, reachable Dart program whose behaviour depends on a
> Flutter-injected define be analysed and patched correctly, end to end, by the
> G4.1c path?

**It spans two different links, and today they have different answers.**

| link | mechanism | answer |
|---|---|---|
| **1 — analysis** | do Route B's prepass/import kernels describe the program Flutter compiles? | **YES.** Byte-identical, arm 1 |
| **2 — replacement** | is a PATCH BODY compiled with the defines the release around it holds? | **~~NO~~ → YES**, fixed 2026-08-15. See the addendum |

That the answer splits is the result. G4.1c threaded the injected defines into
the kernels and stopped there, and "the kernels are right" is not the same claim
as "a patch body compiled against them is right."

## Identity

| fact | value |
|---|---|
| repo commit | `a4bf3f2e` |
| rig CLI | `50ed19a7` (read only; nothing re-synced by this arm) |
| cell | `40eaa0ef6cb6485833bf2e10ac97224ca82cbf25` |
| pinned Flutter | `c15ef6379403a0a55531a058bdb2c8e55bc05c98` (3.44.8) |
| fixture | `selfhost/fixtures/injected_define_app`, **copied**; the committed tree was read only |
| stamp guard | `engine.version` `40eaa0ef…` before **and** after (arm 6); probe aborts if it is not the expected cell |
| probe | `probes/g41d_injected_define_patch.sh` — **10/10** |

## Link 1 — the fix, confirmed more strongly than expected

Arm 1 does not merely find the two kernels equivalent. Route B's kernel compiled
**with** the G4.1c threading is **byte-identical** to the kernel Flutter compiles:

```
routeb_on  sha256 = a6b4630341541c18ee4a0ef43c2da5d2dd82970633570f9a69630c76db861d0c
shipped    sha256 = a6b4630341541c18ee4a0ef43c2da5d2dd82970633570f9a69630c76db861d0c
```

Arm 2 is the negative control, and it is two-part so it cannot pass on an
incidental difference: with the threading removed the kernels **differ**, *and*
the injected value is present in exactly one of them — `3.44.8` appears in
`shipped` and is absent from `routeb_off`.

## Link 2 — THE DEFECT THIS ARM FOUND

`route_b_producer.dart:169` feeds the replacement compiler
`buildConfig.compilerArgs`; `route_b_build_config.dart:345` builds those from
`effectiveDefines` **alone**:

```dart
List<String> get compilerArgs => [
  for (final key in effectiveDefines.keys.toList()..sort())
    '-D$key=${effectiveDefines[key]}',
];
```

G4.1c deliberately kept the injected six **out** of `effectiveDefines`, on the
argument that a release and a patch on one pinned cell always agree on them and a
fingerprint entry could only compare a constant with itself. **That argument is
sound for COMPARISON and wrong for PROPAGATION.** The same field is also the
source of the `-D` flags handed to the patch compiler.

| arm | replacement body reads | flags passed | bakes the real value? |
|---|---|---|---|
| **3** | `FLUTTER_VERSION` | what the product passes today: the fingerprint's defines, i.e. none | **NO** |
| **4** | `PROBE_USER_KEY` (control) | the user define, as today | **YES** |
| **5** | `FLUTTER_VERSION` | the injected set as well | **YES** |

**Arm 4 is what makes arm 3 a finding rather than a misattribution.** A user
define reaches the replacement compiler perfectly well. So this is one missing
*family*, not a broken mechanism — and arm 5 shows the remedy is reachable by
passing the flags that already exist.

The consequence is the one `route_b_producer.dart`'s own comment describes for
user defines: *"a replacement reading a define would silently bake in the DEFAULT
while the release around it holds the real value — a divergence no runtime check
can see, because both are literals by then."*

**Scope, stated honestly.** It bites only a patch body that itself reads one of
the six. That is rarer than an ordinary patch, and **it is not demonstrated to
break any shipped app**. What is demonstrated is that such a body compiles
against the wrong value. It is the same class G4.1c closed one link earlier, and
it is not closed here — fixing it changes what a release records, and releases
already cut (including release 95) carry no such field.

## Two instrument findings, recorded so nobody rebuilds an arm on them

Both were caught by controls rather than by luck, and both invalidated a draft of
this probe.

**1. `gen_kernel --aot` does NOT tree-shake.** The first design gated on *which
symbol is live* — `versionGatedValue` vs `unversionedValue`. Measured: **both are
`reachable: yes` in both kernels.** TFA runs later, at `gen_snapshot`. So "which
branch survives" is not a kernel-level observable at all; it becomes one only in
a real AOT build. This is exactly why the *device* arm is worth running and why
the host arm compares bytes.

**2. `route_b_analyze`'s `changed` does not see a constant-only body
difference.** A kernel built `-DFLUTTER_VERSION=zzz` and one built with the real
value differ *only* in a constant inside `injectedDefineProbe`'s body, and the
analyzer reports `changed: []`. An earlier draft's link-1 arms were built on that
observable and **passed for the wrong reason** — the two `.dill` files genuinely
differed by 24 bytes while the instrument reported agreement.

`g41c`'s link-1 arms remain the analyzer-level proof and are unaffected: they put
the branch in `main`, where the difference *is* seen. The two probes are
complementary rather than redundant — `g41c` proves the defect and fix at the
analyzer layer, `g41d` proves link 1 at the byte layer and link 2 at the
replacement layer.

## The fixture, and why it is a third one

`selfhost/fixtures/injected_define_app` — `flutter analyze lib` clean, no
release cut, no device run. It is separate from `airgap_app` for the reason
`flavored_app`'s pubspec already records: `R6` carries the phone-and-release
counter, and `airgap_app`'s `value()` is load-bearing for six other arms whose
invariants a new conditional would silently perturb.

Its three invariants — reachable not merely present, not constant-foldable at the
call site, branches retaining different symbols — are documented in its README
with the reason each exists.

## What is owed

1. **The link-2 fix**, which is a design decision and not a mechanical change:
   the injected defines must reach `compilerArgs` **without** entering the
   fingerprint comparison, since a release recorded before this change has no
   such field and must stay comparable. Separating *propagation* from
   *comparison* is the shape of it.
2. **The device/release arm on this fixture**, which waits for a clean rig
   hand-back exactly as the integration arm did. On a correct path the device
   shows `OLD-gated` for a release and `NEW-3.44.8` for a patch of
   `replacementReadsDefine` — never `OLD-unversioned`, and never `NEW-`.

Until both, **G4.1c stays BUILT** and link 2 is a **KNOWN GAP**.


---

# ADDENDUM 2026-08-15 — link 2 closed

**Propagation and comparison are now two fields.** `RouteBBuildConfig` gains
`injectedDefines`, feeding `compilerArgs` and nothing else — absent from
`canonicalText`, `fingerprint` and `agreesWith` **by construction**, so release 95
and everything before it stays comparable to a patch cut today.

**The legacy rule is narrow, and the narrowness is a mechanism argument.** A
replacement referencing the app's own `const` resolves it through the import
kernel, which carries the real values since link 1. The only expression compiled
against these `-D` flags is a `fromEnvironment` in the replacement source itself.
So a pre-record release refuses **only** an environment-reading replacement, by
name, and stays patchable otherwise. Refusing all of them would have stranded
releases 89–95 and every `killswitch_probe` permanently, to guard against a
construct almost none contain.

`recordsInjectedDefines` keeps *recorded none* distinct from *predates the
field*: Flutter omits `FLUTTER_ENABLED_FEATURE_FLAGS` when empty, so an empty
recorded map is a fact rather than an absence.

## A vacuity fix, named rather than quietly corrected

**This probe's first draft would have kept passing after the defect was fixed.**
Its patch-replacement arm hand-simulated the product's flags — passing none,
because that is what `compilerArgs` was known to produce — and asserted the value
came out wrong. Nothing connected it to the code under test, so the fix could not
have turned it red.

`probes/compiler_args.dart` now prints `RouteBBuildConfig.compilerArgs` itself,
the same getter `route_b_producer.dart` splices into the `dart2bytecode`
invocation. Arm 3 goes red if the product stops threading.

## Result: `g41d` 14/14

| arm | claim |
|---|---|
| 3 | a replacement reading `FLUTTER_VERSION` **gets** the real value, via the product's flags |
| 3b | a **pre-record** release cannot give it one, and is marked `RECORDS false` |
| 4 | user-define control still passes |
| 5 | both families survive together |
| 6 | stamp guard held at `40eaa0ef` |

**Two negative controls, each confirmed RED in its final form:** reverting
`compilerArgs` to `effectiveDefines` alone fails 2 tests; disabling the legacy
guard fails 1. **The two in-group controls stayed GREEN in both states** — an
ordinary replacement against a pre-record release still compiles, and the same
environment-reading replacement is *accepted* when the release did record. Without
those, the refusal test would mean only "refuses everything".

2513 passed / 1 skipped / 0 failed; analyze `--fatal-warnings` exit 0; format
clean.

**Still BUILT.** The device arm on `injected_define_app` is what an upgrade needs,
and it is now unblocked: `NEW-3.44.8` is the correct expected value rather than
`NEW-`.
