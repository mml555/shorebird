<!-- cspell:words dartaotruntime SBRBPTCH sbrbptch dynmod tearoff disqualifiers -->
<!-- cspell:words unvalidated noninteractive prepass jank recognise -->

# Shorebird feature parity — the goal document

**What this is.** The definition of *done* for this fork, and an honest ledger of
how far along we are against it. [`ROUTE_B.md`](ROUTE_B.md) is the plan of record
for **how** iOS Dart code push works; this file is the record of **what still
stands between us and upstream Shorebird**, and it is the file to open when
deciding what to work on next.

**Last reviewed:** 2026-08-11.

**Verification scope of this pass.** §2 (rung ladder) and §3 (Dart language
surface) were re-derived from the tree at `ec7974cf` — commits, probes and
evidence files. Everything else carries forward from the prior review and is
labelled with the status that review gave it; a carried-forward status is a claim
about the last time someone looked, not about today.

---

## The goal

Full **functional** parity with upstream Shorebird on:

* Android
* iOS

Deferred, deliberately, until those two are complete: macOS, Windows, Linux (§14).

Parity is **developer-visible behavior**, not internal structure. Our
implementation does not need to resemble upstream's — most notably, iOS code push
here runs through Route B bytecode replacement rather than upstream's private AOT
linker, and that is a permitted difference as long as the developer-facing
workflow matches. Parity means: *a source change upstream Shorebird would accept
and ship, we also accept and ship, through the same commands.*

---

## Where we are holding

**Android Dart code push is done.** Release, patch, download, execute, persist,
roll back — on our own engine, our own artifacts, our own control plane,
device-verified on CPH2551 / Android 16 / arm64. There is no known gap in the
core loop; what is unvalidated on Android is *configuration surface* (flavors,
defines, signing, tracks) rather than mechanism.

**iOS Dart code push is real, automatic, and narrower than Android.** The whole
chain works without upstream's private AOT linker: `shorebird release ios` → edit
one function → `shorebird patch ios` → control plane → updater → inflate →
install → lifecycle promotion → native pre-main activation → patched Dart running
→ relaunch still patched → rollback to pristine AOT. Nothing manual in between,
at +4.5 % size and +0.3 % median frame time with zero added jank. Both original
vetoes (size, frame time) are closed. **Delivery, container, updater, release
identity, performance and rollback are proven and should not be reopened.**

**The live boundary is the producer's Dart language surface.** Not delivery — a
body the producer refuses fails *before* a patch exists, and a body it accepts
runs. Today it accepts four spellings inside a replaced method:

```dart
label          this.label          helper()          this.helper()
```

…plus a self-contained body, a `dart:core` reference, a call to another public
top-level app function, and a private helper the replacement declares itself. It
**refuses** arguments, cascades, `super`, setters, private members of the
application library, and any access kind it does not recognise. Refusal is the
designed failure mode: erring costs a rejected patch, never a wrong one.

**The next wall is arguments, and it is a measurement, not an oversight.**
`gen_kernel --aot` eliminates a parameter whose argument is always the same
constant, so in the release kernel `withArgs('x')` genuinely reads as a
zero-argument call to a zero-parameter method, while the `--no-aot` kernel of the
same source says one. The analyzer reads the AOT kernel *by design* — that is the
kernel that fed the release — so an argument gate built on Kernel alone passes
silently. Widening past this means deciding the argument-carrying ABI without
trusting the release kernel's arity. See `TFA` notes in
[`engine/route_b/README.md`](engine/route_b/README.md).

**Beyond the language surface, the unvalidated mass is workflow, not mechanism:**
flavors, defines, obfuscation on iOS, signing, tracks/rollouts, the manual update
API, add-to-app, CI/noninteractive runs, and the failure/recovery matrix. Most of
these exist as inherited upstream code in the fork and have simply never been
exercised against our stack. That is a cheap-per-item, many-items problem — the
opposite shape of the Route B work, and worth batching once the language corpus
stops moving.

### Known documentation drift — fix before anyone new reads it

[`README.md`](README.md) is **behind this file and behind `ROUTE_B.md`**. Its
independence table still says *"iOS Dart code patches: NOT SHIPPABLE — the
compiler and retention layers work on a macOS host harness, nothing has run on
iOS"*, and its capability statement still describes the producer surface as *"a
single-function replacement whose body requires no external symbol resolution"*.
Both were true before the rung ladder was climbed; neither is true now. A reader
who starts at `README.md` will form a materially wrong picture of the project's
state.

---

## Status vocabulary

| status | means |
|---|---|
| **PROVEN** | validated end to end through the real release/patch/runtime path, on device or the real target where applicable |
| **BUILT** | implementation exists with automated/host tests; full product-path validation incomplete |
| **INHERITED** | upstream functionality still present in the fork, never independently validated on our stack |
| **PARTIAL** | important cases work; the upstream feature surface is not yet covered |
| **KNOWN GAP** | understood incompatibility or unsupported behavior |
| **NOT BUILT** | implementation still required |
| **DEFERRED** | intentionally out of current scope |
| **SUPERSET** | functionality we have that upstream Shorebird does not currently provide |

---

## 1. Android core code push

> **`G1 · android-core` — CLOSED. Goal: hold the line.**
> No mechanism work remains. The goal is now *regression*: core Android push
> stays PROVEN after every configuration goal in §4–§10 lands.
> **Done when:** the Android leg still passes after each config goal, not once.
> **Owns:** `R2` Android device, `R9` `cps-android`.

| | item | evidence |
|---|---|---|
| ✅ | **PROVEN** Build Android release using our engine | CPH2551 / Android 16 / arm64, release `1.0.2+3`; `libflutter.so` sha256 `0da873a2…` identical to our build |
| ✅ | **PROVEN** Publish release to our control plane | |
| ✅ | **PROVEN** Build Dart code patch | patch reconstructed to `output_written=3146640b`, exactly `libapp.so`'s size |
| ✅ | **PROVEN** Download patch through updater | |
| ✅ | **PROVEN** Execute patched Dart | our marker printed from code absent from the installed APK |
| ✅ | **PROVEN** Patch persists across relaunch | |
| ✅ | **PROVEN** Roll back to original release code | |
| ✅ | **PROVEN** Engine identity verified as ours | |
| ✅ | **PROVEN** Own patch/diff artifact path | |
| ✅ | **PROVEN** Own engine artifacts served from our infrastructure | [`ENGINE_BUILD.md`](ENGINE_BUILD.md), `experimental:` in [`compatibility.yaml`](compatibility.yaml) |

**Android core code push: PROVEN.** Remaining Android work is the shared
configuration surface in §4–§10, not the mechanism.

---

## 2. iOS core code push

> **`G2 · ios-core` — CLOSED. Goal: keep it frozen.**
> Delivery, container, updater, release identity, activation, performance and
> rollback are proven. **No other goal may modify these layers.** A widening
> probe that starts editing them has misdiagnosed its own failure — that is a
> standing rule, not a preference.
> **Done when:** met today; re-verified by every acceptance run.
> **Owns:** `R1` iPhone, `R8` `cps-ios`.

### Release / runtime

| | item |
|---|---|
| ✅ | **PROVEN** Build iOS release using our engine |
| ✅ | **PROVEN** App launches to first frame |
| ✅ | **PROVEN** App communicates with our control plane |
| ✅ | **PROVEN** Release contains patchable AOT call sites (`--patchable_static_calls`) |
| ✅ | **PROVEN** Release patchability automatically verified |
| ✅ | **PROVEN** Release identity tied to App `LC_UUID` |
| ✅ | **PROVEN** Installed-release identity guard (`probes/assert_installed_release.sh`) |
| ✅ | **PROVEN** Route B compiler cell resolved from release provenance |
| ✅ | **PROVEN** Compiler cell immutable / content-addressed |
| ✅ | **PROVEN** Release dynamic interface generated and retained |
| ✅ | **PROVEN** Patch uses the exact release dynamic interface |
| ✅ | **PROVEN** Patch uses release-owned import/AOT kernels |

### Delivery / runtime activation

| | item |
|---|---|
| ✅ | **PROVEN** Produce Route B bytecode replacement |
| ✅ | **PROVEN** Pack deterministic `SBRBPTCH` container |
| ✅ | **PROVEN** Convert container into normal patch artifact |
| ✅ | **PROVEN** Publish through normal control-plane path |
| ✅ | **PROVEN** Updater downloads patch |
| ✅ | **PROVEN** Patch selected through normal lifecycle |
| ✅ | **PROVEN** Native pre-main activation (`settings.root_isolate_create_callback`) |
| ✅ | **PROVEN** `AttachBytecode` replaces AOT function |
| ✅ | **PROVEN** Patched code executes before first Dart-visible read |
| ✅ | **PROVEN** Patch persists across relaunch |
| ✅ | **PROVEN** Withdraw/rollback restores pristine AOT code |
| ✅ | **PROVEN** No Shorebird private AOT linker required |

**iOS core delivery/runtime: PROVEN.** First full-chain pass on release
`9.0.0+1` (hand-packed container); producer-generated since `19.0.0+1`.

### The rung ladder, as it stands

Each rung asks one question on device, through the ordinary `shorebird patch`
path: *can this replacement body bind and execute?*

| rung | question | status |
|---|---|---|
| **A0** | a named `dart:core` reference | **CLOSED ON DEVICE** — release `15.0.0+1`, `DateTime.now()` runs |
| **A** | replacement calls another public top-level app function | **CLOSED ON DEVICE** — release `16.0.0+1`, `NEW-helper` |
| **B** | public instance method, receiver present but unused | **CLOSED ON DEVICE** — release `17.0.0+1`, `NEW-B` |
| **C** | instance method that uses the receiver | **CLOSED ON DEVICE**, engine `54fb8772` — 0-or-1 positional arg on an entry point; the existing calling convention already delivers the receiver in arg0 |
| **C1** | producer *lowers* a receiver read on its own | **CLOSED ON DEVICE** — engine `3568f73c`, release `19.0.0+1`, `NEW-C1`, byte-identical to the hand-packed rung C payload |
| **C2** | producer lowers a receiver *call* | **CLOSED ON DEVICE** — engine `ebcf143f`, release `20.0.0+1`, `NEW-C2`, dispatching into the release's own AOT `helper()` |
| **D** | private / library-scoped references | **ANSWERED** — two independent walls, see §3 |

---

## 3. iOS Dart patch language surface

> **`G3 · lang-surface` — ACTIVE. This is the critical path.**
> **Goal:** every source change upstream Shorebird would accept, the producer
> either produces *correctly* or refuses with a reason naming the construct.
> Never a wrong patch — refusal is the designed failure mode.
> **Done when:** the parity corpus passes and no remaining refusal is one a
> common application pattern would hit.
> **Owns:** `R1` iPhone, `R6` canonical fixture, `R7` producer/analyzer source,
> and `R3` the Route B tree whenever a rung needs a compiler change.
> **Sub-goals are largely sequential** — they contend on all four. See §16.

This section answers the parity question directly:

> Can an ordinary source change accepted by upstream Shorebird also be produced
> automatically by Route B?

### Proven automatically

| | item | evidence |
|---|---|---|
| ✅ | **PROVEN** Top-level function replacement, self-contained body | first device gate, release `10.0.0+1` |
| ✅ | **PROVEN** SDK / core-library reference (`DateTime.now().millisecondsSinceEpoch`) | rung A0, release `15.0.0+1` |
| ✅ | **PROVEN** Call another public top-level app function | rung A, release `16.0.0+1` |
| ✅ | **PROVEN** Patch an instance-method target when the receiver is unused | rung B, release `17.0.0+1` |
| ✅ | **PROVEN** Implicit receiver getter read — `String value() => label;` auto-lowered to the synthetic receiver form | rung C1, release `19.0.0+1`, `evidence/lowering_*` |
| ✅ | **PROVEN** Implicit receiver method call — `String value() => helper();` → `self.helper()` | rung C2, release `20.0.0+1`, `evidence/call_*`, commit `b5aaeae1` |
| ✅ | **PROVEN** Unicode-safe source offsets | |
| ✅ | **PROVEN** Kernel resolution distinguishes receiver / local / top-level / static references | `probes/lowering_matrix.sh`, 13/13 against real Kernel |
| ✅ | **PROVEN** Compiler contract permits exactly 0 or 1 positional dynamic-module arguments | rung C engine relaxation |

### Built, awaiting a device round-trip

`label` and `helper()` are device-proven in their **bare** spelling. The `this.`
spellings are the same Kernel node and differ only in the lexical edit — an
insert versus a replace — so one passing says nothing about the other, and they
are host-proven only.

| | item | evidence |
|---|---|---|
| ◐ | **BUILT** Explicit `this.label` | `probes/lowered_forms.sh`, host, 8/8 |
| ◐ | **BUILT** Explicit `this.foo()` | `probes/lowered_forms.sh`, host, 8/8 |

> *Corrected this pass.* The prior review listed `this.label` as PROVEN and
> `this.foo()` as NOT BUILT. Neither held: device evidence
> (`evidence/lowering_*`) is the bare `label` spelling, and `this.helper()` lowers
> and runs host-side. Both are now **BUILT** — one status, honestly applied to
> both, per the update rule at the bottom of this file.

### Refused today — the next language cases

Every entry here is an explicit, tested refusal in `probes/lowering_matrix.sh`,
not an untested guess. Ordered roughly by expected cost.

| | item | note |
|---|---|---|
| ☐ | **NOT BUILT** Instance calls with arguments | **the wall.** Kernel cannot be asked — TFA folds constant arguments away. Needs an argument ABI that does not trust the release kernel's arity |
| ☐ | **NOT BUILT** Replacement methods with explicit source parameters | same family as above; the entry-point contract is 0-or-1 positional |
| ☐ | **NOT BUILT** Setters / property assignments | |
| ☐ | **NOT BUILT** Increment/decrement of receiver fields | compound of read + setter |
| ☐ | **NOT BUILT** Cascades | |
| ☐ | **NOT BUILT** Closures capturing `this` | |
| ☐ | **NOT BUILT** `super` getter access | |
| ☐ | **NOT BUILT** `super` method calls | |
| ☐ | **NOT BUILT** Operators requiring receiver lowering | |
| ☐ | **NOT BUILT** More complex generic / type-context cases | |
| ☐ | **NOT BUILT** Broader async / closure corpus | |
| ☐ | **NOT BUILT** Extensions / mixins / records / pattern cases as applicable | |

### Private members

| | item |
|---|---|
| ✅ | **PROVEN** A replacement payload can declare and call its own private helper |
| ✅ | **KNOWN GAP** A synthetic replacement cannot call an *existing* private member of the application library |
| ✅ | **PROVEN** Retention alone does not solve this — Dart privacy is library-scoped, and a private member nothing calls is tree-shaken out of the `--aot` prepass kernel before it can be named |
| ☐ | **OPEN DESIGN** Decide whether full upstream parity requires solving existing app-private references |

That open design item is the one place where "our implementation may differ
internally" might not be enough. Real apps are mostly private code, so a
permanent inability to reference existing app-private members would be a
*developer-visible* parity gap, not an internal one. It needs a decision, not
more probing.

**Language parity: PARTIAL.** Normal application code is increasingly supported;
upstream still has broader arbitrary-Dart patch coverage.

---

## 4. Release / build configuration parity

### Basic release configuration

| | item |
|---|---|
| ✅ | **PROVEN** Standard Android release |
| ✅ | **PROVEN** Standard iOS release |
| ✅ | **PROVEN** Release-specific patch provenance |
| ✅ | **PROVEN** Plugin registrant inputs preserved in Route B release kernels |

### Dart defines

| | item |
|---|---|
| ◐ | **BUILT** `--dart-define` forwarded into Route B release/import generation |
| ☐ | **PARTIAL** Full `--dart-define` release → patch acceptance matrix |
| ☐ | **KNOWN GAP** `--dart-define-from-file` causes Route B patchability to be *declined* rather than supported |

### Flavors / schemes

| | item |
|---|---|
| ☐ | **INHERITED** Android flavors |
| ☐ | **INHERITED** iOS flavors / schemes |
| ☐ | **NOT VALIDATED** Release + patch, same Android flavor |
| ☐ | **NOT VALIDATED** Release + patch, same iOS flavor |
| ☐ | **NOT VALIDATED** Wrong-flavor patch rejection |

### Obfuscation / symbols

| | item |
|---|---|
| ◐ | **BUILT** Obfuscation-related symbol retention machinery |
| ✅ | **PROVEN** Android patched crash symbolication with an obfuscated patch |
| ☐ | **NOT VALIDATED** Route B iOS release + patch under obfuscation |
| ☐ | **NOT VALIDATED** Full upstream-equivalent obfuscation matrix |

### Other Flutter build arguments

| | item |
|---|---|
| ☐ | **NOT VALIDATED** Upstream-supported release arguments propagated correctly into patches |
| ☐ | **NOT VALIDATED** Unsupported release/patch configuration produces a clear failure rather than an incorrect patch |

**Build configuration parity: PARTIAL.**

---

## 5. Patch lifecycle / safety parity

| | item |
|---|---|
| ✅ | **PROVEN** Patch check |
| ✅ | **PROVEN** Download |
| ✅ | **PROVEN** Install |
| ✅ | **PROVEN** Promotion |
| ✅ | **PROVEN** Persistent patch selection |
| ✅ | **PROVEN** Relaunch into patch |
| ✅ | **PROVEN** Withdraw patch |
| ✅ | **PROVEN** Roll back to pristine release code |
| ✅ | **PROVEN** Release-ID mismatch detected before interpreting device results |
| ✅ | **PROVEN** Invalid compiler-cell artifacts fail closed |
| ✅ | **PROVEN** Incompatible/unpatchable Route B release rejected by the producer |
| ☐ | **NOT VALIDATED** Automatic boot/crash rejection behavior parity |
| ☐ | **NOT VALIDATED** Interrupted download / recovery matrix |
| ☐ | **NOT VALIDATED** Corrupt downloaded patch behavior matrix |
| ☐ | **NOT VALIDATED** Multiple sequential patches and rollback matrix |
| ☐ | **NOT VALIDATED** Patch-from-older-release rejection matrix |

**Lifecycle parity: CORE PROVEN / EDGE-CASE MATRIX INCOMPLETE.**

---

## 6. Tracks / rollouts / release management

| | item |
|---|---|
| ☐ | **INHERITED** Basic upstream track concepts |
| ☐ | **NOT VALIDATED** Stable track |
| ☐ | **NOT VALIDATED** Beta / staging / custom track |
| ☐ | **NOT VALIDATED** Publish patch to a specific track |
| ☐ | **NOT VALIDATED** Device receives only the selected track |
| ☐ | **NOT VALIDATED** Promote / move a rollout between tracks |
| ☐ | **NOT VALIDATED** Rollback / withdraw within a tracked rollout |
| ☐ | **NOT VALIDATED** Progressive rollout behavior, if supported by the upstream workflow |

**Rollout parity: UNVALIDATED.**

---

## 7. Patch signing / security

| | item |
|---|---|
| ☐ | **INHERITED** Upstream signing machinery present in the fork |
| ☐ | **NOT VALIDATED** Signed Android release + patch |
| ☐ | **NOT VALIDATED** Signed iOS Route B release + patch |
| ☐ | **NOT VALIDATED** Invalid signature rejected |
| ☐ | **NOT VALIDATED** Key rotation workflow |
| ☐ | **NOT VALIDATED** Custom signing command |
| ☐ | **NOT VALIDATED** KMS-backed signing workflow where supported upstream |

**Signing parity: UNVALIDATED.**

---

## 8. Manual update / `shorebird_code_push` API

| | item |
|---|---|
| ☐ | **INHERITED** Upstream Dart package / API |
| ☐ | **NOT VALIDATED** Check for update manually |
| ☐ | **NOT VALIDATED** Download update manually |
| ☐ | **NOT VALIDATED** Disable the automatic update flow |
| ☐ | **NOT VALIDATED** Android manual update path |
| ☐ | **NOT VALIDATED** iOS Route B manual update path |
| ☐ | **NOT VALIDATED** Restart-required / update-state behavior |

**Manual API parity: UNVALIDATED.** Note the Route B wrinkle worth checking
first: activation is *native and pre-main*, so "restart required" semantics may
differ from Android's in a developer-visible way.

---

## 9. Add-to-app / hybrid Flutter apps

Both platforms distinguish add-to-app releases **only by the `arch` string**
under a shared `platform` (`aar` vs `aab`, `xcframework` vs `xcarchive`) — see
[`PLATFORM_MATRIX.md`](PLATFORM_MATRIX.md).

### Android

| | item |
|---|---|
| ☐ | **INHERITED** Upstream add-to-app support |
| ☐ | **NOT VALIDATED** Release |
| ☐ | **NOT VALIDATED** Patch |
| ☐ | **NOT VALIDATED** Relaunch |
| ☐ | **NOT VALIDATED** Rollback |

### iOS

| | item |
|---|---|
| ☐ | **INHERITED** Upstream add-to-app support |
| ☐ | **NOT VALIDATED** Route B release |
| ☐ | **NOT VALIDATED** Route B patch |
| ☐ | **NOT VALIDATED** Embedded Flutter engine patch activation |
| ☐ | **NOT VALIDATED** Relaunch |
| ☐ | **NOT VALIDATED** Rollback |

**Add-to-app parity: UNVALIDATED.**

---

## 10. CLI / CI workflow parity

| | item |
|---|---|
| ✅ | **PROVEN** `shorebird release android` |
| ✅ | **PROVEN** `shorebird patch android` |
| ✅ | **PROVEN** `shorebird release ios` |
| ✅ | **PROVEN** `shorebird patch ios` |
| ☐ | **NOT VALIDATED** Fully noninteractive CI release |
| ☐ | **NOT VALIDATED** Fully noninteractive CI patch |
| ☐ | **NOT VALIDATED** Token/auth failure produces a useful error |
| ☐ | **KNOWN ISSUE** An empty `SHOREBIRD_TOKEN` can surface as a JSON `FormatException` |
| ☐ | **KNOWN ISSUE** `shorebird release ios` silently uploads a stale IPA |
| ☐ | **NOT VALIDATED** `shorebird preview` |
| ☐ | **NOT VALIDATED** Normal upstream developer preview/testing workflow |

**The stale-IPA hazard, recorded because it already produced one wrong
artifact.** `flutter build ipa` fails its App Store export on this rig ("No
Accounts"), and `shorebird release ios` then picks up whatever stale `.ipa` is
lying in `build/ios/ipa/`. That is how release `19.0.0+1` published with release
18's IPA as its stored release artifact. The **device** result was unaffected —
the container is built against the installed App binary's `LC_UUID`, and the
installed app matched — but the control plane held the wrong bytes.
`--export-method development` exports properly, and deleting the stale `.ipa` is
what made the failure visible instead of silent. Nothing yet *detects* the
staleness, which is the actual fix. See commit `b5aaeae1`.

**CLI parity: CORE COMMANDS PROVEN / BROADER WORKFLOWS UNVALIDATED.**

---

## 11. Crash reporting / symbols — superset

Our additional capability, not an upstream parity requirement.

| | item |
|---|---|
| ✅ | **SUPERSET / BUILT** Patch-scoped crash ingestion |
| ✅ | **SUPERSET / BUILT** Per-patch symbol retention |
| ✅ | **SUPERSET / PROVEN** Android patch symbolication on a real device |
| ✅ | **SUPERSET / BUILT** Architecture-aware symbol selection |
| ✅ | **SUPERSET / BUILT** Read-time symbolication (`?symbolicate=true` → `stack_symbolicated`) |
| ☐ | **SUPERSET / NOT VALIDATED** iOS Route B patched-crash symbolication end to end |

---

## 12. Asset patching — superset

### App-level assets

| | item |
|---|---|
| ✅ | **SUPERSET / PROVEN** Android asset patch |
| ✅ | **SUPERSET / PROVEN** iOS assets-only patch path |
| ✅ | **SUPERSET / BUILT** Full `flutter_assets` overlay |
| ✅ | **SUPERSET / BUILT** Fallback to the release asset when the patch lacks a key |
| ✅ | **SUPERSET / BUILT** Patch-number-scoped asset cache |

### Engine-level assets

| | item |
|---|---|
| ✅ | **SUPERSET / PROVEN** Android `rootBundle` engine overlay |
| ✅ | **SUPERSET / PROVEN** Android patched declared font |
| ✅ | **SUPERSET / PROVEN** Android patched compiled shader |
| ☐ | **SUPERSET / NOT VALIDATED** Equivalent engine-level asset matrix on iOS |

---

## 13. Self-hosting / independence

| | item |
|---|---|
| ✅ | **PROVEN** Own control plane |
| ✅ | **PROVEN** Own database / state |
| ✅ | **PROVEN** Own artifact / CDN path |
| ✅ | **PROVEN** Own Android engine artifacts |
| ✅ | **PROVEN** Own iOS engine artifacts |
| ✅ | **PROVEN** Own Dart / frontend / backend toolchain for supported engine cells |
| ✅ | **PROVEN** Compiler-cell provenance |
| ✅ | **PROVEN** Immutable compiler cells |
| ✅ | **PROVEN** Own patch differ path |
| ✅ | **PROVEN** Own Flutter source mirror |
| ◐ | **BUILT** Artifact ownership audit |
| ◐ | **BUILT** Air-gap fixture / sealed infrastructure |
| ☐ | **NOT VALIDATED** Full latest Route B release + code patch acceptance with every upstream network dependency physically unavailable |

One dependency we cannot reproduce remains: `pkg/aot_tools`, upstream's AOT
linker, used only by the Apple patchers. Route B exists precisely so that it is
not required — see §2, *No Shorebird private AOT linker required*.

**Independence: SUBSTANTIALLY PROVEN.**

---

## 14. Desktop platforms — deferred

Intentionally out of scope until Android/iOS parity is complete. See
[`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md).

| platform | release | Dart patch | persistence | rollback | signing | language corpus |
|---|---|---|---|---|---|---|
| **macOS** | DEFERRED | DEFERRED | DEFERRED | DEFERRED | DEFERRED | DEFERRED |
| **Windows** | DEFERRED | DEFERRED | DEFERRED | DEFERRED | DEFERRED | DEFERRED |
| **Linux** | DEFERRED | DEFERRED | DEFERRED | DEFERRED | — | DEFERRED |

Worth knowing before starting: macOS registers a **multi-arch** patch (`aarch64`
*and* `x86_64`, both must upload and verify), and Windows/Linux register a patch
arch that differs from their release arch (`win_archive` → `x86_64`, `bundle` →
`x86_64`). Details in [`PLATFORM_MATRIX.md`](PLATFORM_MATRIX.md).

---

## 15. Definition of full Android/iOS parity

We may claim **full Android/iOS Shorebird parity** only when every line below is
checked:

| | gate | current |
|---|---|---|
| ✅ | Core Android code push proven | §1 |
| ✅ | Core iOS code push proven | §2 |
| ☐ | Representative Dart-language parity corpus passes | §3, PARTIAL |
| ☐ | No common application source pattern exposes Route B implementation restrictions | §3 |
| ☐ | Flavors pass on Android and iOS | §4 |
| ☐ | Dart defines / build configuration parity passes | §4 |
| ☐ | Obfuscation passes | §4 |
| ☐ | Patch signing passes | §7 |
| ☐ | Tracks / rollouts pass | §6 |
| ☐ | Manual update API passes | §8 |
| ☐ | Add-to-app passes on Android | §9 |
| ☐ | Add-to-app passes on iOS | §9 |
| ☐ | CI / noninteractive workflow passes | §10 |
| ☐ | Rollback / rejection / failure matrix passes | §5 |
| ☐ | Every unsupported upstream workflow is explicitly documented rather than silently failing | this file |

Two of fifteen. The two hardest, and the thirteen remaining are mostly breadth.

---

## Immediate parity queue

Do these in order unless evidence changes the priority.

1. **Dart language corpus** — next: **instance calls with arguments**, and with
   them the argument ABI. The gate cannot be built on Kernel arity (TFA folds
   constant arguments away), so the design question comes before the code.
2. Explicit source parameters / broader function ABI — same family as 1.
3. Close the two host-only spellings (`this.label`, `this.helper()`) with device
   round-trips. Cheap, and it removes an asterisk from a claim we already make.
4. Setters and assignments.
5. Closures / cascades / `super` / generic cases.
6. Resolve or explicitly scope app-private-member parity (§3, OPEN DESIGN).
7. Flavors.
8. Dart defines / build argument matrix.
9. Obfuscation — iOS Route B is the untested half.
10. Patch signing.
11. Tracks / rollouts.
12. Manual update API.
13. Add-to-app.
14. CI / noninteractive workflows.
15. Failure / recovery matrix.
16. Desktop platforms.

Off-queue, small, and it prevents a class of wrong releases: make `shorebird
release ios` **detect** the stale-IPA condition in §10 instead of uploading it.

Also off-queue and nearly free: reconcile [`README.md`](README.md) with this
file — see *Known documentation drift* above.

---

## Rule for updating this file

Do **not** upgrade an item to **PROVEN** because:

* unit tests pass;
* a compiler accepts it;
* a container was generated;
* a host harness works;
* the code exists in the upstream fork.

For runtime features, **PROVEN** means the relevant real product workflow
completed and the observable result was verified. A host probe earns **BUILT**.

Two spellings that produce the same Kernel node are still two items: they differ
in the lexical edit, so one passing says nothing about the other. That rule is
what demoted `this.label` in §3, and it is the rule most likely to be broken
again by someone in a hurry.

When an item becomes PROVEN, record beside it whichever of these apply:

* engine hash;
* release version;
* patch number;
* platform / device;
* evidence or probe name;
* the commit containing the implementation and its gate.
