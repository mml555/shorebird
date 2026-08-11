<!-- cspell:words dartaotruntime SBRBPTCH sbrbptch dynmod tearoff disqualifiers -->
<!-- cspell:words unvalidated noninteractive prepass jank recognise -->
<!-- cspell:words schedulable startable worktree oneline unheld diffstat -->

# Shorebird feature parity — the goal document

**What this is.** The definition of *done* for this fork, and an honest ledger of
how far along we are against it. [`ROUTE_B.md`](ROUTE_B.md) is the plan of record
for **how** iOS Dart code push works; this file is the record of **what still
stands between us and upstream Shorebird**, and it is the file to open when
deciding what to work on next.

**How it is organized.** Every section carries a named **goal** (`G1`…`G14`) with
its own done-condition and the resources it holds, so a goal can be picked up and
worked independently — *"we're on `G3.1` right now"*. §16 is the other half of
that: which goals can run **simultaneously** and which are mutually exclusive,
because the binding constraints here are physical (one phone per platform, one
engine checkout, one canonical fixture) rather than organizational.

**Last reviewed:** 2026-08-11 17:31, at `c57c6537`.

**Verification scope of this pass.** §2 (rung ladder) and §3 (Dart language
surface) were re-derived from the tree — commits, probes and evidence files.
Everything else carries forward from the prior review and is labelled with the
status that review gave it; a carried-forward status is a claim about the last
time someone looked, not about today.

> **⚠ This repo had two workers active on 2026-08-11.** Read **§17** before
> running anything, and check its claims table before taking the phone, the Route
> B checkout or the canonical fixture. The tree is shared — one worktree, one
> branch — so `git add -A` and `git stash` are actively dangerous here.

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
runs. Today it accepts these spellings inside a replaced method:

```dart
label     this.label     helper()     this.helper()     tagged('ARG')
```

…plus a self-contained body, a `dart:core` reference, a call to another public
top-level app function, and a private helper the replacement declares itself. It
**refuses** cascades, `super`, setters, private members of the application
library, and any access kind it does not recognise. Refusal is the designed
failure mode: erring costs a rejected patch, never a wrong one.

The last of those spellings is **new and not yet device-gated** — argument-
carrying receiver calls landed in `9192a594` (analyzer v5, cell `8ebaad05`) and
release `21.0.0+1` is the gate in flight. Everything before it is device-proven.

**Arguments were the wall, and the thing that made them hard is worth keeping in
view because it will recur.** `gen_kernel --aot` eliminates a parameter whose
argument is always the same constant, so in the release kernel `withArgs('x')`
genuinely reads as a zero-argument call to a zero-parameter method, while the
`--no-aot` kernel of the same source says one. The analyzer reads the AOT kernel
*by design* — that is the kernel that fed the release — so any gate built on
Kernel arity alone passes silently. The standing rule that falls out: **ask the
release kernel what a name MEANS; never ask it what the programmer typed.**
Syntax questions go to the source. See `TFA` notes in
[`engine/route_b/README.md`](engine/route_b/README.md).

The consequence for the fixture is not obvious and is easy to get wrong: an
argument-bearing target only keeps its parameter because the release declares a
dynamic interface retaining its library. Without that, `--aot` drops the
parameter and an interpreted `self.tagged('ARG')` would meet a compiled method
taking none.

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
| ◐ | **BUILT** Receiver call **carrying arguments** — `self.tagged('ARG')` | commit `9192a594`; coverage analyzer **v5**, cell `8ebaad05`. The producer copies the argument list verbatim, so its shape is not part of the lowering. **Device gate in flight on release `21.0.0+1`** — do not mark PROVEN from this row |

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
| ☐ | **NOT BUILT** Replacement methods with explicit source parameters | the replacement's **own** signature, distinct from the call it makes. The entry-point contract is 0-or-1 positional, and `9192a594` did not widen it |
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

### `G3` sub-goals, and why they are mostly a queue

| sub-goal | goal | blocked by | needs |
|---|---|---|---|
| **`G3.1 arg-abi`** | an instance call **written with arguments** lowers and runs | **BUILT, gate in flight** — `9192a594`, analyzer v5, cell `8ebaad05`, release `21.0.0+1` | `R7` producer, then `R1` for the gate |
| **`G3.2 this-spellings`** | `this.label` / `this.helper()` proven on device, not just host | — **ready now**, independent of `G3.1` | `R1`, `R6` — no code change at all |
| **`G3.3 setters`** | `label = 'x'` and property assignment | **`G3.1`'s ABI now exists** — unblocked once release 21 gates | `R7`, `R1` |
| **`G3.4 compound`** | `++`/`--` on receiver fields | **`G3.3`** — read + setter composed | `R7`, `R1` |
| **`G3.5 closures-super`** | closures capturing `this`, `super` reads and calls, cascades, operators | **`G3.1`** for anything argument-carrying; `super` reads are independent | `R7`, `R1` |
| **`G3.6 app-private`** | decide whether parity requires naming existing app-private members | — **ready now** | **nothing** — pure design |

Two things fall out of that table and they set the schedule:

**`G3.1` is the gate for four of the six.** Setters, compound assignment, and
most of the closure/operator corpus all carry arguments. Attempting any of them
before the argument ABI exists means inventing a partial ABI and then replacing
it — the most expensive ordering available.

**`G3.2` and `G3.6` are free wins that contend with nothing.** `G3.2` is a device
round-trip with no code change; `G3.6` is a decision with no hardware at all.
Either can be picked up by someone who cannot get the phone or the build tree.

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

> **`G4 · build-config` — goal:** a release built the way developers actually
> build (defines, flavors, obfuscation) yields a patch that installs and runs —
> or fails **at release time**, loudly, rather than producing a patch that is
> quietly wrong for that configuration.
> **Done when:** each configuration axis has a release→patch→run→rollback pass
> on both platforms, and each *unsupported* axis has a test proving it refuses.
> **Splits into three independently schedulable goals:**
> `G4.1 dart-defines` · `G4.2 flavors` · `G4.3 obfuscation-ios`

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

> **`G5 · lifecycle-matrix` — goal:** every failure path degrades to the
> pristine release, never to a broken app. Interruption, corruption, wrong
> release, wrong order — all land on working software.
> **Done when:** each NOT VALIDATED row below has a deliberately-induced
> failure and a verified recovery, on both platforms.
> **Owns:** `R1` or `R2` (one leg at a time), `R6` fixture.

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

> **`G6 · tracks` — goal:** a patch reaches exactly the devices its track
> selects, and no others.
> **Done when:** a device on one track provably does *not* receive another
> track's patch, and promotion/withdrawal move it as upstream's workflow does.
> **Splits by layer:** the server/CLI half needs **no hardware** (`R10`
> `code_push_server` source, own test suite) and is parallel-safe with almost
> everything; only the "device receives only selected track" row needs `R1`/`R2`.

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

> **`G7 · signing` — goal:** a patch that is not ours does not run.
> **Done when:** a validly-signed patch runs on both platforms, a tampered one
> is rejected on-device, and key rotation is a documented procedure someone
> other than its author has followed.
> **Splits by layer** like `G6`: signing/verification logic and the rejection
> tests are hardware-free; the on-device rejection proof needs `R1`/`R2`.
> **Route B wrinkle to check first:** the `SBRBPTCH` container is a distinct
> artifact shape from an Android diff — confirm what upstream's signing actually
> covers before assuming it wraps ours unchanged.

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

**Manual API parity: UNVALIDATED.**

> **`G8 · manual-api` — goal:** an app that drives updates itself, rather than
> letting the updater do it, behaves the same on our stack as on upstream's.
> **Done when:** check / download / disable-automatic all work from Dart on both
> platforms, and the restart-required state is documented for Route B.
> **The one real risk:** Route B activation is **native and pre-main**, so
> "restart required" may genuinely differ from Android in a developer-visible
> way. If it does, that is a §15 documentation obligation, not a bug to hide.
> **Needs its own fixture** — the canonical one has no update-driving UI — which
> makes this goal unusually parallel-friendly (see §16).

---

## 9. Add-to-app / hybrid Flutter apps

> **`G9 · add-to-app` — goal:** Flutter embedded in a native host app patches,
> persists and rolls back exactly like a standalone app.
> **Done when:** release→patch→relaunch→rollback passes with Flutter embedded in
> a native host, on both platforms.
> **Splits cleanly by platform** — `G9.1 android` (AAR) and `G9.2 ios`
> (xcframework) share no hardware and no fixture, so they are genuinely
> concurrent with each other.
> **The iOS-specific unknown:** pre-main activation assumes the engine starts the
> way a standalone app's does. An embedded engine may not, and that is the row to
> attack first — everything else in `G9.2` is downstream of it.

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

> **`G10 · cli-ci` — goal:** the whole workflow runs unattended, with no
> interactive prompt, no ambient state, and **no silent wrong artifact**.
> **Done when:** a release and a patch both complete from a clean checkout with
> only a token in the environment, every auth failure names its cause, and the
> stale-IPA condition below is *detected* rather than uploaded.
> **`G10.1 stale-ipa` is the highest-value hardware-free goal on this list** —
> it is CLI code plus unit tests, it needs no device and no fixture, and it
> closes a hazard that has already shipped one wrong artifact.

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
| ✅ | **FIXED** `shorebird release ios` refuses a stale IPA left by an earlier build — commit `c57c6537` |
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

> **`G11 · ios-symbolication` — goal:** a crash inside patched Route B code
> symbolicates back to patch source, as it already does on Android.
> **Done when:** a deliberate crash in an interpreted replacement produces a
> symbolicated frame naming the patch's own function.
> **Not blocked by `G3`** — the current four spellings are enough to write a
> crashing body. **Open question to answer first:** interpreted bytecode frames
> may not appear in an Apple crash report the way AOT frames do, which would make
> this a different problem than the Android one rather than a port of it.

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

> **`G12 · ios-engine-assets` — goal:** iOS reaches Android's engine-level asset
> coverage — `rootBundle`, declared fonts, compiled shaders.
> **Done when:** each row Android has proven has an iOS equivalent on device.
> **Watch the resource cost:** the Android proofs needed engine work, so this may
> take `R3`/`R4` and a cell mint — which makes it contend with `G3`'s
> compiler-touching rungs despite looking unrelated.

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

> **`G13 · sealed-independence` — goal:** the newest Route B release *and* code
> patch both pass with every upstream network dependency physically unreachable.
> **Done when:** `airgap_run.sh` + `airgap_acceptance.sh` pass against a sealed
> CDN on a current release, including an iOS **code** patch (today's sealed proof
> covers releases and assets-only patches).
> **⚠ GLOBALLY EXCLUSIVE — this goal cannot share the machine.** Sealing the CDN
> is a host-wide change: every other goal's builds start failing the moment it is
> sealed. Schedule it alone, as the *last* thing in a batch, never alongside.

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

> **`G14 · desktop` — goal: none yet, deliberately.** Not scheduled, not
> resourced, not blocking §15. Listed so it is visibly deferred rather than
> forgotten. Do not start it to feel productive while a §3 device gate is
> waiting for the phone.

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

## 16. Working goals in parallel — what collides and what does not

Parallelism here is limited by **physical and rig resources**, not by ambition.
Two goals that look unrelated can still be mutually exclusive because they want
the same phone, the same engine checkout, or the same line of one YAML file.

### The contended resources

| id | resource | exclusivity |
|---|---|---|
| **R1** | iPhone 7 / iOS 15.8.8, **wired** | **one goal at a time.** Wired or simulator only — never a wirelessly-paired device |
| **R2** | Android CPH2551 / Android 16, **wired** | **one goal at a time**, but fully independent of `R1` |
| **R3** | `/Volumes/build/route-b` — the Route B engine checkout | **one build at a time.** `dart_patches.sh --verify` before every build, and again after any `gclient sync` |
| **R4** | `/Volumes/build/ios-engine` — the shipping iOS engine tree | **one build at a time**, independent of `R3`. Kept deliberately clean of the killgate SDK changes; **do not consolidate the two trees** |
| **R5** | the build SSD itself | shared by `R3` + `R4`. Two heavy concurrent builds are a media risk, not just a slow one — see [`MEDIA_PRESERVATION.md`](MEDIA_PRESERVATION.md) |
| **R6** | `selfhost/fixtures/airgap_app` — the canonical fixture | **the sharpest serializer.** See below |
| **R7** | `route_b_producer.dart` + `coverage/analyze_coverage.dart` | versioned **together** (currently v4). Two goals editing these conflict in source, not just in schedule |
| **R8** | `cps-ios` control plane, `:18080` | one iOS release-cutting goal at a time |
| **R9** | `cps-android` control plane, `:18081` | one Android release-cutting goal at a time; **separate instance from `R8` on purpose**, so the two legs' histories never contaminate each other |
| **R10** | `packages/code_push_server` source + tests | standalone package, own lockfile. Cheap to work on concurrently with anything |
| **R11** | the sealed CDN (docker compose) | **host-global.** Sealing it breaks every other goal's builds |

### Why the fixture is the real bottleneck

`R6` is a single app directory carrying three pieces of mutable per-run state:

1. **`shorebird.yaml`** is *generated*, and `prepare_airgap_fixture.sh --activate
   <leg>` stamps it immediately before a run. The script says why in its own
   comments: run the other leg concurrently and *"the last invocation is the one
   the next leg would silently use"* — wrong `app_id`, wrong control plane, and a
   result that looks valid.
2. **`pubspec.yaml` `version:`** is what derives `--release-version`, and the
   control plane **rejects a duplicate**. Two goals cutting releases race on one
   integer.
3. **`lib/main.dart`** is what every language rung edits. Two rungs in flight
   means two people editing the same function.

**So: the iOS leg and the Android leg cannot use the canonical fixture at the
same time.** That is by design, and it is the single constraint most worth
*engineering away* — a per-goal fixture clone with its own `app_id` and its own
version line would unlock most of the parallelism this document wants. Until
then, treat "who holds the fixture" as a thing to say out loud.

Note the happy accident: goals that need a **new** fixture anyway (`G4.2`
flavors, `G8` manual API, `G9` add-to-app) do not contend on `R6` at all, which
makes them *more* parallel-friendly than goals that look smaller.

### Hard exclusion rules

1. **One iPhone goal at a time.** `G3.x` device gates, `G4.3`, `G5`(ios), `G6`
   device row, `G7`(ios), `G8`(ios), `G9.2`, `G11`, `G12`, `G13` all want `R1`.
2. **One canonical-fixture leg at a time** — iOS *or* Android, never both.
3. **One `R7` editor at a time.** `G3.1`, `G3.3`, `G3.4`, `G3.5` all edit the
   analyzer/producer pair. This is a source conflict as much as a scheduling one.
4. **One `R3` build at a time**, and a cell mint is an `R3` operation — so
   `G12` and any compiler-touching `G3` rung exclude each other even though they
   share no subject matter.
5. **`G13` runs alone.** `R11` is host-global; sealing the CDN fails everyone
   else's builds. Last in a batch, never concurrent.

### Traps — pairs that look parallel and are not

| pair | why it collides |
|---|---|
| `G4.2 flavors`(android) + `G5 lifecycle`(android) | both want `R2` **and** the fixture version counter |
| `G3.1 arg-abi` + `G3.3 setters` | `R7` source conflict, *and* `G3.3` is genuinely blocked by `G3.1` |
| `G12 ios-engine-assets` + any compiler-touching `G3` rung | both want `R3` and a cell mint |
| `G11 ios-symbolication` + `G3.2 this-spellings` | both want `R1`; neither needs the other, so it is pure contention |
| anything + `G13` | `R11` is host-global |

### Lanes that genuinely run at once

Four concurrent lanes, contending on nothing:

| lane | goal | resources held |
|---|---|---|
| **Device — iOS** | `G3.1 arg-abi`, then its device gate | `R1`, `R3`, `R6`(ios leg), `R7`, `R8` |
| **Device — Android** | `G4.2 flavors`(android) on its **own** flavored fixture | `R2`, `R9` |
| **Hardware-free code** | `G10.1 stale-ipa` detection | CLI source + unit tests |
| **Hardware-free design** | `G3.6 app-private` decision | nothing |

Add a fifth when someone is available: the **server halves** of `G6 tracks` and
`G7 signing` (`R10` only, no hardware, own test suite).

That is the honest ceiling right now: **roughly four**, of which two are the
device lanes and two need no hardware. Raise the ceiling by fixing `R6` — nothing
else on this list buys as much parallelism per hour spent.

---

## 17. Two workers, one working tree — the coordination protocol

§16 says which goals *may* run at once. This says how two workers actually avoid
destroying each other's work, because as of 2026-08-11 that is not hypothetical:
two sessions were working this repo simultaneously, and the second discovered the
first only by reading `git status`.

**The shared-state fact that governs everything below:** `git worktree list`
returns exactly one entry, `/Users/mendell/shorebird`. Both workers edit the same
files on the same branch. There is no isolation unless someone creates it.

### The five rules, in order of how much damage they prevent

1. **Stage explicit paths. Never `-A`, never `commit -a`.** The other worker's
   in-flight edits are sitting unstaged in the tree. A broad stage commits their
   half-finished device gate inside your unrelated commit.
2. **Never `git stash`, `git restore .`, `git checkout .`, or switch branches in
   the shared tree.** Each silently discards work in progress that belongs to
   someone else. `git stash` is the worst of them: it looks reversible and is not,
   once the other worker's next command writes over the same file.
3. **Code work belongs in its own `git worktree`.** Anything under `packages/` or
   `selfhost/engine/route_b/` — the code both workers are likely to touch. Docs
   that only one worker owns (this file) are fine in the shared tree.
4. **Claim before you take an exclusive resource** — see the table below. `R1`
   (the phone) and `R3` (the Route B checkout) cannot be shared and **cannot be
   detected**; there is no way to tell someone is mid-device-run except by them
   having said so.
5. **Read the tree before acting.** `git log --oneline -5` and `git status` cost
   nothing and would have prevented the duplicated work described below.

### The tell: how to spot a device gate in flight

An **uncommitted `fixtures/airgap_app/pubspec.yaml` version bump** together with
a **fresh line in `selfhost/cdn/experimental_hashes.map`** means someone has
minted a cell and is cutting a release right now. Back off `R1`, `R3` and `R6`
until those changes are committed. That exact pair appeared at 17:29 on
2026-08-11 — release `21.0.0+1`, cell `8ebaad05` — while this document was being
written two directories away.

### What it cost to learn this — and it already happened

Two things went wrong on 2026-08-11, both benign by luck rather than by design.

**Duplicated planning.** Two of the four goals this file listed as *"start now —
nothing blocks these"* were completed by the other session **while the list was
being written**: `G3.1 arg-abi` (`9192a594`) and `G10.1 stale-ipa` (`c57c6537`).

**A broad stage swallowed another worker's files.** `9192a594` is a commit about
receiver call arguments. Its diffstat also contains all 649 lines of the first
draft of *this file* and a one-line `README.md` index entry — neither of which has
anything to do with arguments, and neither of which its author wrote. Nothing was
lost, so this reads as harmless; reverse the timing and the same broad stage
commits a half-finished device gate, or a `git stash` discards one.

The lesson is not "coordinate more". It is that **an unclaimed resource looks
exactly like an available one, and an unstaged file looks exactly like yours.**

### Claims

Update this table in the same commit as the work. Stale rows are worse than no
rows, so **clear your row when you stop**, even mid-goal.

| resource | held by | goal | since | notes |
|---|---|---|---|---|
| `R1` iPhone 7 | `shorebird-a0` | `G3.1` device gate | 2026-08-11 17:29 | release `21.0.0+1` |
| `R3` route-b tree | `shorebird-a0` | `G3.1` | 2026-08-11 | cell `8ebaad05` minted |
| `R6` canonical fixture | `shorebird-a0` | `G3.1` | 2026-08-11 17:29 | `tagged(String x)` added, version → 21 |
| `R7` producer/analyzer | `shorebird-a0` | `G3.1` | 2026-08-11 | analyzer **v5** |
| `R8` `cps-ios` | `shorebird-a0` | `G3.1` | 2026-08-11 | |
| this file | *docs session* | §15–17 | 2026-08-11 | docs only; holds no device, tree or fixture |
| `R2` Android device | — | — | — | **free** |
| `R4` ios-engine tree | — | — | — | **free** |
| `R9` `cps-android` | — | — | — | **free** |
| `R10` server source | — | — | — | **free** |
| `R11` sealed CDN | — | — | — | **free** — and `G13` needs it exclusively |

> Rows above were inferred from the working tree, not declared by their holder.
> Treat them as best-effort until `shorebird-a0` confirms.

### What is safe to pick up right now

Given those claims, the free lanes are the **Android device** (`R2`, `R9` — so
`G4.2 flavors`(android)), the **server halves** of `G6`/`G7` (`R10`, no
hardware), and `G3.6 app-private` (no resources at all). Everything on the iOS
critical path is held.

---

## Immediate parity queue

**This is a priority order, not a schedule.** What can run *simultaneously* is
§16's question, and the answer there is roughly four lanes. Read both.

### Start now — nothing blocks these, and they contend with nothing

**Check §17's claims table first.** As of 2026-08-11 17:29 the entire iOS
critical path is held by another session.

| goal | lane | status |
|---|---|---|
| ~~**`G3.1 arg-abi`**~~ | iOS device | **taken** — `9192a594`, device gate in flight on release 21 |
| ~~**`G10.1 stale-ipa`**~~ | code, no hardware | **done** — `c57c6537` |
| **`G3.6 app-private`** | design, no hardware | **free.** A decision, not a probe. It may redefine what §15 requires |
| **`G4.2 flavors`**(android) | Android device | **free** — `R2`/`R9` are unheld, and a flavored fixture avoids `R6` entirely |
| **`G6`/`G7` server halves** | `R10`, no hardware | **free** — own package, own test suite |
| **`G3.2 this-spellings`** | iOS device | **blocked on `R1`** — no code change needed, but the phone is held |

### Then, in priority order

5. **`G3.3 setters`** → **`G3.4 compound`** — both blocked by `G3.1`.
6. **`G3.5 closures-super`** — `super` reads are startable earlier than the rest.
7. **`G4.2 flavors`** — Android half needs no `R1`, so it can run in the Android
   lane alongside iOS work today.
8. **`G4.1 dart-defines`** matrix.
9. **`G4.3 obfuscation-ios`** — the untested half; Android is proven.
10. **`G7 signing`** — server half is hardware-free and startable any time.
11. **`G6 tracks`** — same split.
12. **`G8 manual-api`** — needs its own fixture, so it does not contend on `R6`.
13. **`G9 add-to-app`** — `G9.1`/`G9.2` are concurrent with each other.
14. **`G10.2 noninteractive`** CI workflows.
15. **`G5 lifecycle-matrix`** — the failure/recovery matrix.
16. **`G13 sealed-independence`** — **last, and alone.** It seals the CDN.
17. **`G14 desktop`** — deferred; do not start it early.

### Off-queue and nearly free

* Reconcile [`README.md`](README.md) with this file — see *Known documentation
  drift* above. Ten minutes, and it stops the fork's front door from
  understating the project by several rungs.
* Give the canonical fixture per-goal clones (`R6`, §16). The single highest
  parallelism-per-hour item on this page.

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
