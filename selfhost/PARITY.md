<!-- cspell:words dartaotruntime SBRBPTCH sbrbptch dynmod tearoff disqualifiers -->
<!-- cspell:words unvalidated noninteractive prepass jank recognise -->
<!-- cspell:words schedulable startable worktree oneline unheld diffstat -->
<!-- cspell:words overclaim DFLUTTER Diagnosticable -->
<!-- cspell:words demangled specializer devirtualizes rationalised synthesises -->
<!-- cspell:words subshell theorised generalises generalisable symbolicator unrunnable -->
<!-- cspell:words characterisation backout NONAOT Wonderous analysed -->

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

**Last reviewed:** 2026-08-11 18:4x, at `fa40f6ca`.

**Verification scope.** §2 (rung ladder), §3 (Dart language surface) and — as of
2026-08-11 — **§5, §6, §7, §8, §9, §10, §11 and §13** have been re-derived from the
tree: commits, probes, evidence files and source. Sections still carrying a status
forward from an earlier review say so where it matters.

> **What that pass cost, and why it was worth it.** Eight sections were verified
> row by row and **the statuses moved in both directions**. Rows filed as
> *NOT VALIDATED* turned out to be **KNOWN GAP** — a device run would not have
> closed them, because the code already answers. Rows filed as *BUILT* were
> **PROVEN** and had been understating themselves. And two of my own recent
> "corrections" were **wrong** and are called out where they sit: §6's `BLOCKED`
> and its "no test has ever…" claim. The verifiers' proposals were then attacked
> by two adversarial passes, which killed four — including one that claimed no CI
> workflow invokes the CLI, contradicted by `e2e.yaml` driving it end to end.
>
> The generalisable part: **an unvalidated row invites "we should test that", while
> a gap invites "we should decide whether we ship that."** Mislabelling the second
> as the first is how a project keeps scheduling device time against questions the
> source already settled.

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

All five spellings are device-proven, the last of them as of release `21.0.0+1`
(engine `8ebaad05`, commit `edbbd80b`) — in the bare spelling; the two `this.`
forms remain host-proven only, which §3 keeps separate on purpose.

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

**The project is at a transition point, and the queue reflects it.** Core mechanism
work is largely done; **structural coverage and safety semantics are now the real
constraints**. Delivery and runtime are closed. Lexical widening is closed *and
parked* — three rungs landed in one afternoon and the reach barely moved, because
the limit was never syntax. What remains is two coverage questions (privacy scope,
method ABI — near-equal, measured from two directions) and one safety question (the
once-per-process activation model, `G15`, which turns one mechanism into three
product failures).

**Beyond the language surface, the unvalidated mass is workflow, not mechanism:**
flavors, defines, obfuscation on iOS, signing, tracks/rollouts, the manual update
API, add-to-app, CI/noninteractive runs, and the failure/recovery matrix. Most of
these exist as inherited upstream code in the fork and have simply never been
exercised against our stack. That is a cheap-per-item, many-items problem — the
opposite shape of the Route B work, and worth batching once the language corpus
stops moving.

### Documentation drift — reconciled 2026-08-11

[`README.md`](README.md) had fallen **behind this file and behind `ROUTE_B.md`** by
several rungs: its independence table said *"iOS Dart code patches: NOT
SHIPPABLE"*, its capability statement said the **producer** was what was missing,
and its status table listed *"iOS Dart code patch produced by `shorebird patch`"*
as **NOT BUILT**. All three predated the rung ladder. A reader starting at the
front door formed a materially wrong picture.

Now reconciled, and the warning it carries was **retargeted rather than deleted**.
It used to say *"do not let 'iOS code push works on the device' become 'iOS code
push works'"* — a producer caveat that no longer applies. It now says *"do not let
'iOS code push works' become 'any iOS patch works'"*, which is the same discipline
pointed at the limit that is actually live: the ~7 % language surface. The lesson
generalises — when a caveat is overtaken by progress, the honest move is usually to
re-aim it at the new boundary, not to drop it and declare the thing done.

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
| ✅ | **PROVEN** Kernel resolution distinguishes receiver / local / top-level / static references | `probes/lowering_matrix.sh`, **26/26** against real Kernel as of `cb50590d` |
| ✅ | **PROVEN** Compiler contract permits exactly 0 or 1 positional dynamic-module arguments | rung C engine relaxation |
| ✅ | **PROVEN** Receiver call **carrying arguments** — `String value() => tagged('ARG');` → `self.tagged('ARG')` | engine `8ebaad05`, release `21.0.0+1`, iPhone 7, `evidence/arg_*`, commit `edbbd80b`. No new mechanism: the edit is still `tagged` → `self.tagged`, and `('ARG')` crossed over as source text nothing parsed |
| ✅ | **PROVEN** Explicit `this.label` | release `21.0.0+1` patch 2, `evidence/this_1_label_NEW-C1.png`, commit `8907239a` |
| ✅ | **PROVEN** Explicit `this.<method>(args)` | release `21.0.0+1` patch 3, `evidence/this_2_call_NEW-ARG.png`, commit `8907239a`. **Proven as `this.tagged('ARG')`, not `this.helper()`** — see the note below |
| ✅ | **PROVEN** Receiver **write** — `String value() => slot = 'NEW-SET';` → `self.slot = 'NEW-SET'` | engine `aa915584`, release `22.0.0+1`, iPhone 7, `evidence/set_*`, commit `fa40f6ca`. Same `self` mechanism as reads and calls, no new transport |

Two evidence notes worth keeping, because both are the kind of thing that decays
into an overclaim:

**The `this.` call was proven with arguments, not without.** `8907239a` used
`this.tagged('ARG')` rather than `this.helper()`, deliberately: on release 21
nothing names `helper`, so the kernel prepass would tree-shake it and the patch
would have failed for a **retention** reason while looking like a lowering one.
The lexical edit is identical either way, so nothing is lost — but the defensible
claim is `this.<method>(args)`, and `ROUTE_B.md` lists `this.helper()`.

**The lowered artifact cannot distinguish the two spellings.** Both branches of
the producer converge on byte-identical output, so what separates a `this.` arm
from a bare arm is the *input source*, recorded in the commit message. Earlier
gates shipped a `*_replacement.dart` beside the screenshots; these did not.

### Superseded — the demotion that held

> *Kept because the arc is the lesson, not the outcome.* A prior review listed
> `this.label` as PROVEN and `this.foo()` as NOT BUILT. Neither held: the device
> evidence at the time (`evidence/lowering_*`) was the **bare** `label` spelling,
> and `this.helper()` lowered and ran host-side. Both were demoted to a single
> honest **BUILT**, and `8907239a` then earned PROVEN for both within the hour by
> running two patches on release 21. The rule paid for itself twice: it caught an
> overclaim, and the correction cost one release's worth of rig time — because
> both spellings rode an **existing** release rather than needing a new one.

### Refused today — the next language cases

Every entry here is an explicit, tested refusal in `probes/lowering_matrix.sh`,
not an untested guess. Ordered roughly by expected cost.

| | item | note |
|---|---|---|
| ☐ | **NOT BUILT** Replacement methods with explicit source parameters — **`G3.7 param-abi`, worth 33.2 %** | the replacement's **own** signature, distinct from the call it makes. The entry-point contract is 0-or-1 positional and the receiver already claims the one slot; `9192a594` did not widen it. **This single item is worth more than the entire privacy problem** — see the measurement above |
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

| sub-goal | goal | status | needs |
|---|---|---|---|
| ~~**`G3.1 arg-abi`**~~ | an instance call **written with arguments** lowers and runs | **CLOSED ON DEVICE** — `9192a594` + `edbbd80b`, analyzer v5, cell `8ebaad05`, release `21.0.0+1` | released |
| ~~**`G3.2 this-spellings`**~~ | the explicit `this.` spellings on device, not just host | **CLOSED ON DEVICE** — `8907239a`, two patches on release `21.0.0+1`, no new release and no cell mint | released |
| ~~**`G3.3 setters`**~~ | `label = 'x'` and property assignment | **CLOSED ON DEVICE** — `cb50590d` + `fa40f6ca`, analyzer v6, cell `aa915584`, release `22.0.0+1` | released |
| **`G3.4 compound`** | `++`/`--`/`+=`/`??=` on receiver fields | **REFUSED BY DERIVATION, not blocked** — see below | new mechanism, not a gate relaxation |
| **`G3.5 closures-super`** | closures capturing `this`, `super` reads and calls, cascades | `super` writes now refuse explicitly (`cb50590d`); the rest untouched | `R7`, `R1` |
| ~~**`G3.6a app-private-decision`**~~ | **is it reachable at all** | **ANSWERED 2026-08-11 — yes.** The CFE already has the mechanism (`resolveInLibrary`), Route B is denied it by one line, and the `dyn:`-forwarder objection is void in AOT. See below | done, no resources consumed but `R3` read-only |
| **`G3.6b app-private-holes`** | close the two accepted-then-failed holes | unblocked by `G3.6a` | `R7` **and a cell mint** — `analyze_coverage.dart` is in the manifest |
| **`G3.6c dynamic-receiver`** | emit `dynamic` instead of a private class name | **BUILT, host-proven as a pair with `G3.6d`** — `probes/private_receiver.sh` 4/4, a patch on a private class runs. Device round-trip outstanding | done at `R7`; no mint |
| **`G3.6d private-retention`** | retain private classes, procedures **and fields** in the dynamic interface | **BUILT, host-proven and shown LOAD-BEARING by a negative control.** Cost measured: **+0.01 %** | generator only, as predicted — no validator or CFE change |
| **`G3.6e resolve-in-library`** | thread `resolveInLibrary` through dart2bytecode | **BUILT — rung D falls.** `probe D` 4/4, `a53029c9`, patch `0005`. Hand-written replacement; needs `G3.6b` for the producer path, then a device gate | done at `R3`; mint pending with `G3.6b` |
| **`G3.7 param-abi`** | a replacement method may declare **its own parameters** | **the largest single unlock: 33.2 %**, and unlike `G3.6` its feasibility is *known* — the entry-point contract is a patch we already own (`0004`) | engine (`R3` + a mint), `R7`, `R1` |

Three things fall out of that table, and two of them correct earlier drafts of
this file.

**The setters rung did not open the next rung — it closed it.** `cb50590d`
derives its refusal as *two accesses reported at one source offset*, measured on
real Kernel: `label += 'X'` SET@240/GET@240, `count++` SET@269/GET@269,
`maybe ??= 'Z'` GET@315/SET@315, against the legitimate `label = label + 'Y'` at
SET@447/GET@455. So compound assignment, increment and if-null are refused
**uniformly and by derivation** rather than by an enumerated operator list — which
also catches forms nobody enumerated. `G3.4` is therefore not "unblocked because
`G3.3` closed"; it needs a mechanism that can distinguish two edits at one offset,
and the lexical model cannot. An earlier draft of this table predicted the
opposite.

**`G3.6` is not "pure design", and calling it that is why it kept getting
scheduled as filler.** An earlier draft listed it as holding *nothing*, resources
*"nothing — pure design"*. Both halves are wrong. Its decisive step is a
**measurement**, not a decision. And its remediation touches
`coverage/analyze_coverage.dart`, which is **one of the compiler cell's seven
manifest files**, so it forces an analyzer version bump, an `R3` build and a cell
mint. Splitting it into `G3.6a` (free: the measurement, the layer map, the
decision) and `G3.6b` (expensive: the hole-closures) is what makes the free half
actually free.

**The ladder has no cheap next rung, and the two big prizes are elsewhere.**
`G3.1`, `G3.2` and `G3.3` all closed within hours of each other; `G3.4` is refused
by derivation; `G3.5` is real work with no leverage. The measurement says the reach
is bounded by two things the ladder does not touch: **privacy** (`G3.6`, →29.8 %)
and **the parameter ABI** (`G3.7`, →33.2 %). Neither alone breaks a third; together
they reach ~100 %.

**`G3.6a` is answered, so the ordering is now settled by cost rather than by
uncertainty:** `G3.6c` (dynamic receiver — CLI-only, no mint) → `G3.6d`
(private retention — generator only) → `G3.7 param-abi` → `G3.6e`
(`resolveInLibrary` — the full fix) → `G3.5`, `G3.4` last and possibly never.

That order is not the order of *value*, it is value per resource. `G3.6c` is the
only item on the page that widens real reach with **no cell mint, no new release
and no engine change**, and the empirical study says its band — private `State`
classes — is the single largest real-world blocker.

### Private members

| | item |
|---|---|
| ✅ | **PROVEN** A replacement payload can declare and call its own private helper |
| ◐ | **BUILT** A replacement **can** call an existing private member of the application library — `probe D` 4/4, `a53029c9`. Hand-written replacement; producer path and device gate outstanding |
| ✅ | **PROVEN** Visibility and retention are **separate** requirements — the interface names a member, but TFA drops one nothing calls before the `--aot` prepass kernel reaches the generator |
| 🐞 | **KNOWN GAP** A retained private **instance** member of a never-allocated class has **no executable body** — the name resolves and the call enters an unreachable stub, silently. Mode 3 below |
| ☐ | **NOT BUILT** A mechanism probe for mode 3 — until one exists, `probe D` cannot distinguish it from success |
| ☐ | **NOT BUILT** The producer emits it automatically — **`G3.6b`**, gated on the retention policy below, not merely on the analyzer |
| ☐ | **OPEN DESIGN** An explicit release retention policy, with its emitted **and skipped** sets recorded in the supplement — see the ordered gate below |

> **Superseded 2026-08-12.** The second row read **KNOWN GAP: "a synthetic
> replacement cannot call an existing private member"**, and the fourth was an OPEN
> DESIGN question about whether parity required solving it. Both are retired: it
> can, the front end always could, and what remains is automation plus retention.
> Kept visible because the gap was load-bearing in several earlier decisions — the
> `dynamic self` workaround (`G3.6c`) exists because of it, and it was cited as the
> reason the ~7 % reach figure had a hard ceiling.

### How much of real Dart Route B can reach — measured from kernel

Reproduce with [`coverage/measure_private_reach.dart`](engine/route_b/coverage/measure_private_reach.dart):

```
dart --packages=$DART_TREE/.dart_tool/package_config.json \
  selfhost/engine/route_b/coverage/measure_private_reach.dart \
  selfhost/fixtures/airgap_app/build/app.dill \
  --package package:flutter/src [--all-concrete]
```

It walks a real component, counts only the shape the entry-point contract can
address, and classifies each body by the privacy its references would need. It
excludes synthetic mixin applications (`_AppBarTheme&InheritedTheme&Diagnosticable`
— the CFE composes those, nobody patches one) and abstract/external members, which
are not patch targets under any future ABI. **An earlier draft of this section
carried a regex estimate; these figures replace it.**

Measured on `app.dill` from the release-22 build:

| | `package:flutter/src` | `package:flutter/src/material` |
|---|---|---|
| concrete instance methods | 6,862 | 1,133 |
| — excluded as synthetic mixin applications | 2,953 | 739 |
| **patchable today** | **7.1 %** (486) | **2.4 %** (27) |
| ceiling if **privacy** were fully solved, one-parameter ABI standing | 29.8 % (2,046) | 28.2 % (320) |
| ceiling if the **parameter ABI** were fully widened, privacy standing | **33.2 %** (2,275) | **32.8 %** (372) |
| declares its own parameters (out of contract) | 70.1 % (4,808) | 71.6 % (811) |
| generic | 0.1 % (8) | 0.2 % (2) |

**Two limits, near-equal, and independent.** Solving *either* alone leaves about
two-thirds of real methods unreachable. Solving both reaches ~100 %. That is the
finding, and it corrects a claim an earlier draft of this file made.

**Do not extrapolate one from the other — measured, and the assumption fails.**
Among in-contract (zero-parameter) methods only **8.4 %** are privacy-clean; among
*all* concrete methods **33.2 %** are. Parameter-declaring methods are markedly
more privacy-clean, because zero-parameter instance methods in Flutter skew toward
`initState`/`dispose`/private-`State` helpers while parameter-taking methods skew
toward public API. A projection from the first number to the second understates
the parameter ABI's value by ~4×, which is exactly the error that would mis-rank
the two goals.

**The `acceptedThenFails` figure is the bug's blast radius, not a gap's size:**
**183** methods framework-wide (47 in material) that the analyzer **accepts** and
the producer then breaks on, by emitting a private class name as a parameter type.
It should be zero. See the two holes below.

**What this does to §15.** The gate *"no common application source pattern exposes
Route B implementation restrictions"* is not reachable by the rung ladder — at
7.1 % it is not close. But it is not privacy alone either: it needs `G3.6`
**and** a parameter ABI, which is why the latter is promoted to `G3.7` below rather
than left as one bullet among twelve.

**The stopping rule that follows, recorded so it survives enthusiasm.** Do **not**
resume lexical rung work unless real compatibility data identifies a lexical blocker
at meaningful frequency. Phase 0 measured compound writes at **0** occurrences and
`super` at **2** across ten real commits, against private members at **39** in 9 of
10 patches. Every rung costs a cell mint and a scarce device gate, so the default is
now **no**, and only frequency evidence reopens it. `G3.4` and `G3.5` are parked
under this rule rather than queued.

### `G3.6e` — RUNG D FALLS 2026-08-12. Privacy was never one wall.

`probe D`, 4/4 with `RETAIN_PRIVATE=1 RESOLVE_IN_LIBRARY=1`: a replacement in its
own synthetic library called an **existing private member of the release**, and the
value reached the app's own call site — `OLD-a` → `NEW-D`. Commit `a53029c9`.

**Privacy was two separable requirements, not a fundamental limitation:**

1. **compile the replacement in the target library's private namespace** — solved
   cleanly by `resolveInLibrary`, a front-end mechanism that already existed for
   debugger expression evaluation and was hard-coded off for normal compiles;
2. **ensure the referenced private member still exists in the release** — a
   *retention* question, entirely separate from visibility.

**The runtime failure of (2) is the strongest evidence for (1).** Without retention
the error was `bytecode_reader.cc:1172 Unable to find function
_privateHelper@17057535 in Library:'package:dynamic_modules/container_target.dart'`
— the VM looked for the **keyed private symbol in the app library**, not in the
synthetic module. Private identity is being carried correctly; the symbol was simply
absent. A privacy failure and a retention failure look nothing alike, which is why
separating them was worth the extra knob.

#### Invariants — deliberate properties, not incidental ones

Each of these was chosen, and each would be tempting to "simplify" away by someone
who did not pay for it:

| invariant | why |
|---|---|
| `--resolve-private-names-in-library` stays **off by default and explicit** | it widens name resolution; nothing should get that by accident, and an ordinary compile must behave exactly as before |
| a **missing library is a hard failure**, never a silent fallback | falling back compiles with narrower resolution than asked for, and the resulting "private member not found" points at the *replacement source* — sending the reader to debug the lowering when the fault is a missing `--import-dill` |
| `RETAIN_PRIVATE` stays **separate** from privacy resolution | conflated, a passing probe cannot say whether visibility or reachability did the work; separated, each failure names its own wall |
| status stays **BUILT** until the analyzer/producer path **and** a device round-trip both pass | today's arm is a hand-written replacement, exactly as rung C was proven before the producer caught up |

#### The retention half — THREE failure modes, not two

The interface generator reads the **`--aot` prepass** kernel by design — that is the
kernel that fed the release. But TFA has already dropped anything unreachable, so a
private member *nothing in the release calls* is gone before the generator can name
it. `--private-dill` enumerates from the **non-AOT** kernel instead, and the
interface being an *input* to the release build is what makes TFA keep what it names.
Proven: `probe D` 4/4 with `PRIVATE_FROM_NONAOT=1` and no `RETAIN_PRIVATE`.

**A third failure mode exists that the probe cannot currently detect, and it is the
one the product will actually hit.** Found by an adversarial pass over this design
(read from source, `high` confidence, mechanism not refuted):

| # | failure | how it presents |
|---|---|---|
| 1 | **visibility** — the replacement cannot name the member | compile error: *"the getter '_secret' isn't defined"* |
| 2 | **retention** — the member is not in the release | load error: `bytecode_reader.cc:1172 Unable to find function` |
| 3 | 🐞 **dead body** — the member is retained, and its body is not | **nothing.** The name resolves and the call enters an unreachable-code stub |

Mode 3 comes from the difference between a `DirectSelector` and an
`InterfaceSelector`. A private **top-level or static** member named in the interface
becomes a raw direct call, so TFA analyses and retains its body — that is
`_privateHelper`, the proven shape. A private **instance** member whose enclosing
class is never *allocated* becomes an interface selector over the class's cone type;
with nothing allocated in that cone the body never becomes reachable, and TFA pass 2
keeps the declaration while replacing the body (`transformer.dart:2348-2360`
`_makeUnreachableBody`, or `isAbstract = true` with a null body at `:2294-2302`).
`gen_snapshot` then records a retain reason and emits no code
(`precompiler.cc:1667-1675`).

**So existence in the AOT kernel does not imply an executable body**, and mode 3 is
silent — which makes it strictly worse than the two loud failures it hides behind.
`probe D` cannot tell it from success, because `probe D`'s target is top-level.

#### Ordered gate before any cost number

Cost is the *last* question, not the next one. A measurement taken before the
contract is closed prices "whatever a particular generator happened to enumerate"
rather than a policy. In order:

| | step |
|---|---|
| ☐ | **A never-allocated mechanism probe** — a `_NeverAllocated._secret()` arm whose *expected* result is pinned as **"name resolves, body was TFA-replaced with unreachable code."** Mode 3 gets its own negative control instead of resting on source inspection |
| ☐ | **`--private-dill` landed as CORRECTNESS infrastructure**, not an optimization knob — control and treatment must reason about the same pre-TFA program shape, or `get:_file` versus `_file` means the experiment measures cross-kernel disagreement rather than retention policy |
| ☐ | **An explicit release retention policy**, recorded in the supplement with its exact emitted **and skipped** sets — not "whatever non-AOT enumeration finds" |
| ☐ | **Then** Wonderous prices *that* contract |

#### The policy shape, and the bar for its second category

Two categories, and the second is conditional on evidence that does not exist yet:

```
private patchability:
  - top-level/static     proven: DirectSelector, body analysed and retained
  - live-instance        REFUSED until "live" is mechanically provable
```

**"Live-instance" must not mean "the class and member exist in the AOT kernel."**
Mode 3 is precisely existence coexisting with a dead stub. Until there is a reliable
signal that the class was actually allocated and the body remained executable, that
category is **refused** rather than accepted optimistically — refusing costs a
rejected patch, accepting costs a silent no-op at runtime.

#### `G3.6b`'s contract follows from this

Not "private members are supported". Mechanically:

> **Accept a private reference only when the release supplement proves that concrete
> private target was retained and permitted.**

Per-target, from recorded evidence, not per-category from a policy name. A
category-level rule would accept `_FooState._bar` because "private instance members
are retained" while that specific `_bar` sat in the skipped set — or worse, was
retained as a dead stub.

#### An intentional coupling, documented rather than split

The dynamic interface currently does **two jobs**:

1. **retention** — what code survives TFA into the release;
2. **permission** — what a future patch is allowed to reference, since the same
   `DynamicInterfaceSpecification` is what the validator checks a patch against.

That coupling is now load-bearing, and it is **deliberately not split yet**.
Broadening retention and permission together is *useful* at this stage because it
forces the product decision to be visible: "retain every private" and "let a patch
call any private member of the app" become the same sentence, which is the honest
framing of what is being chosen.

**Split them when, and only when, the two requirements diverge** — if broad retention
turns out to be technically necessary while narrower patch permissions are wanted.
At that point retention specification and patch allowlist become separate documents.
Recorded here so that a future reader finds a decision rather than an accident.

### `G3.6a` — ANSWERED 2026-08-11. It is reachable, and the mechanism already exists.

The question was whether a synthetic replacement library can ever name an existing
app-private member. **Yes**, and the front end already has the knob — it is used
today for debugger expression evaluation.

**Where the wall actually is: source-level scope construction in the CFE, and
nowhere else.** `dill_library_builder.dart:220-230` puts every dill top-level
declaration — private classes included (`:274-278`) — into the library's own name
space, but guards the **export** name space with
`if (!name.startsWith("_") && !name.contains('#'))`. Imports iterate only the
export name space (`import.dart:106`), so `_MyHomePageState self` fails
`typeNotFound`. Below the CFE there is **no privacy machinery for a class at all**:
kernel's `Class.name` is a plain `String`, not a library-keyed `Name`, and
dart2bytecode derives the key from the class node itself —
`object_table.dart:2177-2187` emits `_PrivateNameHandle(library, node.name)` using
the **app** library regardless of who references it. So P1 needs no retarget pass;
it needs only for the name to resolve.

**The knob.** `SourceCompilationUnitImpl(resolveInLibrary:)`, documented at
`source_library_builder.dart:155-166`: *"A library to use for Names generated when
compiling code in this library. This allows code generated in one library to use
the private namespace of another, for example during expression compilation
(debugging)."* With it set, a synthetic library statically resolves **every**
category of another library's privates with zero errors — proven in-tree by
`testcases/expression/private_stuff.expression.yaml.expect` (`Errors: {}`):
private method, private field get *and* set, private getter, private setter,
private static method, private static field, private named constructor, private
top-level method, and a private extension. `expression_suite.dart:701-719` runs
each of those a **second** time against a dill-bootstrapped compiler, so it holds
for a library arriving via `--import-dill` — which is exactly Route B's shape.

**Route B is denied it by one line.** `source_loader.dart:425` hard-codes
`resolveInLibrary: null` for normal compilation. Verified in the tree.

**The cheapest useful change is CLI-only and forces no cell mint.** Emit `dynamic`
instead of the private class name at `route_b_producer.dart:243`, so the private
*class* never appears in the synthetic library — the CFE accepts any name on a
dynamic receiver with no privacy test (`inference_visitor_base.dart:6088-6089`).
`route_b_producer.dart` is **not** in the cell manifest (`mint_route_b_cell.sh:57-65`
lists only the seven build artifacts), so this buys the P1 band with no mint, no
engine hash and no new release — its device confirmation rides an existing release
as one more patch.

**The forwarder objection is dead, and this is the important one.** The sharpest
argument against `G3.6` was that a probe could not distinguish a wrong
private-library key from a missing `dyn:` invocation forwarder, since both surface
as `NoSuchMethodError`. **In AOT that confound does not exist.**
`resolver.cc:56-72` probes for the forwarder with `create_if_absent=false` and, on
a miss, falls through to the **unguarded** `lookup(cls, *demangled_name)` at
`:66-67` — only the lazy *creation* at `:69-74` sits inside
`#if !defined(DART_PRECOMPILED_RUNTIME)`. So a missing forwarder makes the call
**succeed**. Its one observable form is the abort at `resolver.cc:117-121`, a
`RELEASE_ASSERT` with file:line — never a `NoSuchMethodError`. Therefore
**`NoSuchMethodError` ⇒ not a forwarder**, deducible with no instrument at all.
Both adversarial refuters returned *not refuted* at high confidence, and this one
strengthened the claim rather than surviving it.

**The real second wall is retention, and it is three shapes rather than one.**
`Precompiler::PruneDictionaries` (`precompiler.cc:3226-3350`, PRODUCT-only)
physically **removes** objects — library-dictionary entries (`:3271-3288`), each
class's `functions()` array (`:3312-3331`), and each class's `fields()` array
(`:3333-3345`) — unless `HasApiUse`, which is populated only from entry-point
pragmas. That rejects **absent** symbols, not retargeted names, so it refines the
answer rather than reversing it. The consequence worth acting on: a private
**field** needs a pragma on the `Field` itself (`precompiler.cc:1642-1649`), a
shape `gen_dynamic_interface.dart` emits nothing for. The widening is not "also
walk `lib.classes`" — it is private classes, private instance procedures, and
private fields, separately.

Encouragingly, the retention half needs **no** validator or CFE change:
`LibraryIndex` resolves a private member as private to its named library
(`library_index.dart:118-122`), so a dynamic-interface spec may legally name
`#RouteBThing._secret`. It is a generator change only.

**Two caveats, recorded rather than smoothed over.** Whether `PruneDictionaries`
runs for Route B's exact artifact is *not* established — `out/host_release_arm64`
contains both `gen_snapshot` and `gen_snapshot_product`, and which one the iOS
release pipeline invokes was not determined. And the probe's app-side key oracle as
first designed is likely inoperative: `aot_call_specializer.cc:794-806`
devirtualizes `(RouteBThing() as dynamic)._echo()` from the propagated receiver
cid, so no runtime resolution occurs and no trace line prints. Read the **module's**
key instead — the module runs interpreted and the interpreter never devirtualizes.

### `G3.6c` is built — and a prediction, recorded before anyone books the rig

`route_b_producer.dart` now emits `dynamic self` when the receiver class is
private and keeps the concrete type when it is public, so every spelling already
proven on device lowers to byte-identical source. 42 CLI tests green, including a
regression guard for the public case. **That is BUILT, not PROVEN** — it is a text
transformation verified by unit test.

**Prediction: `G3.6c` alone will fail, and for a retention reason.** Recorded now
so the result scores against it rather than being rationalised afterwards.

`gen_dynamic_interface.dart:143-144` walks `lib.procedures` — **top-level**
privates only — and never walks `lib.classes`. A `library:` item retains, per
pkg/vm's own spec, *"all **public** classes and members"*. So for
`class _RouteBState { String label; }`:

* the class is not public, so the `library:` item does not retain it;
* its members are not named individually, because the generator's private loop
  never descends into classes.

Nothing retains it. And per `Precompiler::PruneDictionaries` the objects are
**physically removed**, not merely unnamed — so the runtime dynamic lookup cannot
find them however the name is keyed. `G3.6c` fixes the **compile** half (the
private class name no longer has to resolve); the **runtime** half is `G3.6d`.

**So `G3.6c` and `G3.6d` are one goal in two files, not a sequence.** Shipping
`G3.6c` by itself converts a compile-time failure into a runtime one, which is
strictly worse per this file's own standards. Do them together, and expect the
first host arm to fail until `G3.6d` lands.

This also explains a detail in the empirical study that would otherwise look
incidental: every blocked `_FullscreenVideoViewerState` method in `fe3959bf` is
blocked by a private **member** as well as sitting on a private class. The
P1-only band — private class, clean body — is structurally real (183 methods
framework-wide) but rare in the edits developers actually make. `G3.6c`'s value is
that it removes one of two walls cheaply, not that it ships a capability alone.

### `G3.6d` — built, and verified against the real annotator

The prediction above held: the retention half was a **generator change only**, no
validator and no CFE change. `gen_dynamic_interface.dart` now emits three shapes
it previously did not, and the emission was verified end to end on the host by
running `gen_kernel --aot --dynamic-interface` over a program containing every
shape and reading `--dump-detailed-dynamic-interface` back:

| shape | emitted as | annotated? |
|---|---|---|
| private class | `class: '_Hidden'` | ✅ — **and its PUBLIC members** (`pub`, `publicMethod`), which is precisely `G3.6c`'s runtime need |
| private method of a private class | `class: '_Hidden'` + `member: '_privMethod'` | ✅ |
| private getter / setter | `member: 'get:_privGetter'` / `'set:_privSetter'` | ✅ |
| private field, mutable and `final` | `member: '_privField'` / `'_privFinal'` | ✅ |
| private member of a **public** class | `class: 'Public'` + `member: '_alsoPrivate'` | ✅ |
| private top-level function | `member: '_topLevelPrivateFn'` | ✅ (already worked) |
| private top-level **field** | `member: '_topLevelPrivateVar'` | ✅ — **a pre-existing gap**: the loop read only `lib.procedures`, so a private top-level variable was named by nothing |

Three mechanics worth keeping, each measured rather than assumed:

**A field is named BARE, not `get:`/`set:`.** `library_index.dart:320-326` applies
the accessor prefixes only to a `Procedure`; a `Field` is indexed under
`member.name.text`. Naming the field is also sufficient for both directions —
`precompiler.cc:1642-1651` adds the field and synthesises its implicit getter and
setter. Guessing `get:_x` here, by analogy with the private-accessor case already
in the generator, would have failed the whole interface.

**A `class:` item is the exact analogue of a `library:` item, one level down.**
`dynamic_interface_annotator.dart:221-235`: `visitClass` annotates the class and
then only `_visitPublicMembers` of its constructors, procedures and fields. So a
class item buys a private class's public surface, and its private members still
need naming one by one.

**A private class resolves at all because the index does not filter classes.**
`library_index.dart:189-190` keys containers by plain `class_.name`; the privacy
filter at `:329-332` applies to *members*, and even there only to members whose
name belongs to a *different* library — never true for an app's own privates.

### The pair, proven on the host — with a negative control

`probes/private_receiver.sh`, **4/4**. A patch replaced a method on a **private
class** end to end: producer → interface → release → container → install → the
app's own call site reading the patched value. This is the first time Route B has
touched the shape Flutter code actually uses, since a `StatefulWidget`'s `State`
class is private by convention.

```
retained      (product path)          not_retained  (--no-private-classes)
  private classes in interface: 15      private classes in interface: 0
  lowered: dynamic self          ✅     lowered: dynamic self          ✅  ← identical
  APPLY ok: 1 target(s)                 APPLY refused: target _Hidden.value
  hidden = NEW-PRIV              ✅       did not attach; rolled back 0
                                        hidden = OLD-priv              ✅
```

**The control is the point, and it says three things the positive arm cannot.**
The lowering is *byte-identical* in both arms, so the control's failure is
retention and not a lowering regression — the two walls really are separable.
`G3.6d` is therefore **load-bearing**, not decoration: strip the `class:` items and
the patch stops working. And the failure mode is the good one — the container
**refuses at attach time and rolls back**, so an under-retained release keeps
running its own code rather than crashing or silently doing nothing.

Recorded because the prediction was scored: `G3.6c` alone was predicted to fail
for a retention reason, and this is that prediction confirmed by construction
rather than by argument.

### The cost, measured — and it is free

`measure_real_app.sh` now crosses two axes instead of one: library breadth (app
only vs every library) × private-class breadth. On the real fixture, host AOT
snapshots, deltas being the transferable part:

| configuration | bytes | vs baseline |
|---|---|---|
| baseline (stock AOT) | 5,737,800 | — |
| + call form | 5,934,664 | **+3.43 %** |
| + app-only retention, no private classes | 5,991,488 | +4.42 % |
| + app-only retention — **the shipping policy** | 5,992,176 | **+4.43 %** |
| + ALL libraries, no private classes | 21,566,704 | +275.79 % |
| + ALL libraries retained | — | **DOES NOT BUILD** |

**The private-class axis, isolated: +0.01 % — 688 bytes.** Same order as the
private top-level members already shipping, so the shape is free and `G3.6d` is
shippable on cost. The whole shipping policy moves +4.39 % → **+4.43 %**, still
inside the budget the step-7 veto was judged on. The +275.79 % reproduces the
+275.58 % the earlier sweep recorded for naive all-library retention, which is the
check that both sweeps measured the same thing.

### What the sweep broke, which is why it was worth running

`G3.6d`'s first version was verified on a **toy** program and was wrong on real
code. A single unresolvable entry fails the *whole* interface, and the framework
produced two distinct kinds:

* **`ThemeMode._enumToString`** — the front end synthesises enum machinery whose
  `Name` is private to `dart:core`, not to the library declaring the enum, and
  `library_index.dart:329-332` refuses to index a member whose name belongs to
  another library. **112 entries.**
* **`ScaffoldMessengerState.set:_accessibleNavigation`** — a Setter *Procedure* in
  the `--aot` prepass kernel the generator reads, resolvable there as `set:…`,
  with no such key in the pre-transform component the annotator indexes.

The fix is structural rather than a pair of special cases: the generator now
**validates every candidate through the same `LibraryIndex.getMember` the
annotator uses** and reports the skips instead of swallowing them — 120 on the
framework, **0 on the app-only shipping policy**, which is exactly why only the
all-libraries arm ever failed.

**The limit that remains, stated rather than smoothed.** That check indexes the
kernel it is *given* — the `--aot` prepass — while the annotator indexes a fresh
pre-transform component. Where AOT has reshaped a class the two disagree, and no
filter available in the generator predicts the other component's shape. It does
not affect the shipping policy (0 skipped, arm builds); it kills the naive
all-libraries breadth, which now reports **DOES NOT BUILD** rather than a size.
That is a stronger argument for the app-only policy than a number would have been.

Two harness bugs were found and fixed alongside: `try_kernel` has to run
`kernel` in a **subshell**, because `kernel` calls `die` and an `if kernel …`
took the whole script down with it; and a first hypothesis about field-lowering
was reverted rather than kept, because the entry count did not move — the shape
was inspected directly instead of theorised about a third time.

### Empirically corroborated, by a different method

`fe3959bf` ran ten real commits through the frozen analyzer: **0/10 publishable**,
with `private app member` the largest blocker at **39 occurrences across 9 of 10
patches** — and the prediction recorded before the run did not name it. Seven of
fourteen blocked targets were methods of one private `State` class, because in
Flutter the `State` class is private *by convention*. Idiomatic `StatefulWidget`
code collides with the synthetic-library model for reasons unrelated to syntax.

That study and this section's structural measurement are independent methods and
they agree: privacy first, the parameter ABI second (`signature/arity`, 8
occurrences across 6 of 10 patches → `G3.7`), and **compound writes 0, `super` 2**
— so `G3.4` and `G3.5` are empirically costing approximately nothing, which is the
same conclusion the structural numbers reached from the other side.

It also found a **third** accepted-then-failed hole, at the verdict level: the
coverage verdict is computed from unreachable/unknown/added targets and never asks
whether a representable target can be **lowered**, so it said `accept` for 5 of 10
patches the producer would refuse. Safe — the producer throws — but any tool
trusting the verdict overstates acceptance.

### Two accepted-then-failed holes — bugs, not gaps

Both verified in the tree. Each is worse than a missing feature, because the
analyzer **accepts** the target and the failure lands later, wearing a lowering
bug's clothes — the most expensive failure class on this rig, since attributing it
costs a full mint → release → repin → gate cycle.

| | hole | mechanism |
|---|---|---|
| 🐞 | **A private receiver class is emitted verbatim as a parameter type** | `coverage/analyze_coverage.dart:490` emits `'receiverType': cls.name` with no privacy check; `route_b_producer.dart:243` inserts it straight in: `edits.add((open + 1, 0, '${lowering.receiverType} self'))`. A method on `_MyHomePageState` yields `_MyHomePageState self` in a synthetic library that cannot name it, and dies in dart2bytecode. **This is the ~15 % private-class band.** |
| 🐞 | **Static and top-level bodies are never inspected** | the lowering pass at `coverage/analyze_coverage.dart:190-192` walks only `cls.procedures` and does `if (!changed.contains(key) \|\| p.isStatic) continue;`. For a static or top-level target the verdict is `accept` on **reachability alone** — a reachability statement wearing a language-surface statement's clothes. |

Fixing either is `G3.6b`: both files are `R7`, and `analyze_coverage.dart` is in
the cell manifest, so the fix costs a mint. Neither should be attempted while a
rung's device gate holds those resources.

That open design item is the one place where "our implementation may differ
internally" might not be enough. Real apps are mostly private code, so a
permanent inability to reference existing app-private members would be a
*developer-visible* parity gap, not an internal one. It needs a decision, not
more probing.

**Language parity: PARTIAL, and narrower than the row count suggests.**

An earlier draft said *"normal application code is increasingly supported."* That
sentence is an accidental contract and the measurement above retires it. What is
true: **the supported spellings are increasingly complete within a 4–7 % slice of
real method shapes.** Reads, calls, argument-carrying calls, explicit `this.`, and
writes are all device-proven — and essentially none of them can be used on a
method that touches app-private code, which is 93–96 % of them.

Upstream Shorebird patches arbitrary Dart. We patch a well-understood subset whose
boundary is not the rung ladder but library-scoped privacy.

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
| ✅ | **PROVEN** Standard iOS release — on the acceptance fixture |
| 🐞 | **KNOWN GAP** A Route B iOS release of a **real third-party app** does not build: Wonderous fails its retention-interface annotation even at app-only breadth (`get:_file` for `ThrottledSaveLoadMixin`, where the annotator's component has `_file` bare). Enumerating privates from the non-AOT kernel avoids it |
| ✅ | **PROVEN** Release-specific patch provenance |
| ✅ | **PROVEN** Plugin registrant inputs preserved in Route B release kernels |

> **The fixture was hiding this.** Standard iOS release was PROVEN on
> `airgap_app` — one library, no mixins, no lowered private fields — and the first
> real third-party app tried does not compile. Two distinct defects, one now fixed:
> the CLI asked for **every** library (fixed, `d40de830`, and it had **no test**
> asserting the argv that decides the whole retention policy), and app-only breadth
> is **still** not sufficient because the same cross-kernel shape mismatch recurs
> inside an app's own libraries. `--private-dill` is therefore correctness
> infrastructure, not an optimization knob.

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
| ☐ | **KNOWN GAP** Route B never sees the flavor at all — `grep flavor` across `route_b*.dart` returns **zero** hits |

> **`G4.2` has a false-green trap, and it is the reason to do the host probe
> first.** `forwardedArgs` forwards only `--dart-define=` and
> `--enable-experiment=`; `--flavor` is added to the `flutter` command separately
> and never enters `buildArgs`. So Route B's prepass (which generates the retention
> interface), its import kernel (which the patch binds against), and its
> dart2bytecode invocation all compile with `appFlavor == null` while the shipped
> release has a real value. A minimal flavored fixture that never *reads*
> `appFlavor` turns both device rows green with the gap fully intact — buying an
> accidental contract instead of a capability. Prove it host-side with
> `-DFLUTTER_APP_FLAVOR` before booking `R2`.
>
> Worth lifting **out** of `G4.2` and doing first, because `G4.1` and `G4.3` both
> reuse it: record the release's define set in provenance and thread it through the
> prepass, the import kernel and dart2bytecode. That is mechanism; flavors is a
> validation errand that happens to need it.

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

**Verified against the code 2026-08-11.** Every row below was checked rather than
carried forward, and six changed. The platform is now named per row, because the
section previously implied both and several rows only ever held for one.

| | item | platform |
|---|---|---|
| ✅ | **PROVEN** Patch check | Android + iOS |
| ✅ | **PROVEN** Download — the installed artifact was pulled back off the phone and was byte-identical to the published container | Android + iOS |
| ✅ | **PROVEN** Install | Android + iOS |
| ✅ | **PROVEN** **Lifecycle** promotion to `next_boot` — `lifecycle.rs:752-770` | Android + iOS |
| ✅ | **PROVEN** Persistent patch selection | Android + iOS |
| ✅ | **PROVEN** Relaunch into patch | Android + iOS |
| ✅ | **PROVEN** Withdraw patch | Android + iOS |
| ✅ | **PROVEN** Roll back **to the pristine release** | Android + iOS |
| 🐞 | **KNOWN GAP** Roll back to an **earlier patch** is impossible by construction | both |
| ✅ | **PROVEN** Release-ID mismatch caught by a **host pre-flight probe** (`probes/assert_installed_release.sh`) | iOS only — test discipline, not a shipped property |
| 🐞 | **KNOWN GAP** A wrong-release patch is downloaded, installed, promoted and **reported as a successful install** before anything refuses it | iOS |
| ✅ | **PROVEN** Invalid compiler-cell artifacts fail closed | iOS only — no Android analogue |
| ✅ | **PROVEN** Unpatchable release **detected** on real shipped bytes | iOS |
| ◐ | **BUILT** …and **refused inside the patcher** — host tests only, never run against an unpatchable release through the product path | iOS |
| 🐞 | **KNOWN GAP** Automatic boot/crash rejection — a patch that crashes in Dart is **never backed out** | iOS/Route B; narrow on Android |
| 🐞 | **KNOWN GAP** Interrupted download — cross-cycle resume is structurally unreachable | both |
| ◐ | **PARTIAL** Corrupt patch **in transit** — refuse-permanently established in source, device demo missing | both |
| 🐞 | **KNOWN GAP** Corrupt patch **at rest** — refused silently forever: no tombstone, no event, retried every boot | iOS |
| ◐ | **PARTIAL** Multiple sequential patches — three on one release are device-proven | iOS |
| ☐ | **NOT VALIDATED** Patch-from-older-release rejection matrix | both |

**Three of those gaps are safety claims that were filed as merely untested, and
each is decidable from source without a device.**

**Boot/crash rejection: the mechanism exists but its window closes before any Dart
runs.** `ReportLaunchStart` fires during snapshot resolution
(`runtime/dart_snapshot.cc:160`) and `ReportLaunchSuccess` fires in the **`Shell`
constructor** (`shell/common/shell.cc:535-537`) — the engine's own test proves that
path executes no Dart at all (`shell_unittests.cc:5119-5137` yields exactly
`['ReportLaunchStart','ReportLaunchSuccess']`). The root isolate, and therefore
`root_isolate_create_callback` where Route B activates, is created later via
`Shell::RunEngine` (`shell.cc:750,782`). So "launch succeeded" is recorded before
the patch has had a chance to fail.

**Wrong-release patches are not refused by the updater on iOS, and a probe comment
says otherwise.** The Route B artifact is deliberately **base-independent**
(`0003-4b-lifecycle-delivery.patch:1067-1092`), so `check_hash` passes on any
device, the patch installs, promotes, and reports `__patch_download__` and
`__patch_install__`. Only the pre-main hook refuses it (`kWrongRelease`, same patch
`:829-844`). `probes/assert_installed_release.sh:63-67` claims the updater "will
correctly refuse a patch built for another release" — **that comment is wrong** and
should be fixed where it sits.

**Rollback lands only on the base release.** `record_boot_success` calls
`cleanup_older_than(n)` (`lifecycle.rs:624-634`), deleting every patch below the one
that booted, and `recompute_next_boot` (`:722-748`) falls back to `last_booted`
only — its own doc-comment says it will not scan for other installed patches.
Confirmed on device: withdrawing patch 1 showed `code patch: none`, not patch 0.

**Lifecycle parity: CORE PROVEN / SAFETY EDGES ARE GAPS, NOT UNKNOWNS.**

---

## 6. Tracks / rollouts / release management

> **`G6 · tracks` — goal:** a patch reaches exactly the devices its track
> selects, and no others.
> **Done when:** a device on one track provably does *not* receive another
> track's patch, and promotion **adds** a track / withdrawal removes one, as
> upstream's workflow does. *(The verb is `add`, not `move` — settled by reading
> `promote`, which supersedes only within the target channel.)*
> **Splits by layer:** the server half needs **no hardware** (`R10`
> `code_push_server` source, own test suite) and is largely **already built**;
> only the "device receives only selected track" row needs `R1`/`R2`.

| | item |
|---|---|
| ☐ | **INHERITED** Basic upstream track concepts |
| ☐ | **NOT VALIDATED** Stable track |
| ☐ | **NOT VALIDATED** Beta / staging / custom track |
| ☐ | **NOT VALIDATED** Publish patch to a specific track |
| ☐ | **NOT VALIDATED** Device receives only the selected track — reachable today, see below |
| ◐ | **BUILT** Promote a rollout to another track — and the verb is **ADD**, not move |
| ◐ | **BUILT** Rollback / withdraw within a tracked rollout — channel-scoped, server-side |
| ☐ | **NOT VALIDATED** Progressive rollout behavior, if supported by the upstream workflow |

**Rollout parity: SERVER LARGELY BUILT / DEVICE UNVALIDATED.**

> **Two corrections to an earlier version of this section, both of them mine.**
>
> **I called the device row `BLOCKED` and said auto-update was "permanently
> stable-only." That was wrong.** `compileShorebirdYaml` does copy only `base_url`,
> `auto_update` and `patch_verification`, and it does omit `channel` — but the
> conclusion does not follow: the row is reachable today by other means, so it is
> **NOT VALIDATED**, not blocked. "Permanently" was the overreach. I had verified
> one fact and inferred a second, which is the exact failure this document warns
> about two sections earlier.
>
> **I also wrote that "no test has ever created a non-`stable` channel," and that
> the server half of `G6` is "real, absent work."** Also wrong — the server half is
> largely **done**. `grep beta` returning nothing was a bad proxy for coverage, and
> I should not have promoted a negative grep to a claim about what exists.
>
> **What does hold:** tracks are real server-side, superseding is correctly scoped
> `WHERE channel_id = @c`, and the promote semantics are settled by reading the
> code — `promote` supersedes only *within* the target channel, so setting a track
> **adds** one. Fix the language wherever it says "move", including in `G6`'s goal
> statement above, before anyone writes a test that freezes the wrong reading.

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

**Verified against the code 2026-08-11**, and the result is worse than "unvalidated".

| | item |
|---|---|
| ☐ | **INHERITED** Upstream signing machinery present in the fork |
| 🐞 | **KNOWN GAP** The default `patch_verification: install_only` performs **no signature verification anywhere on the production path** |
| ☐ | **NOT VALIDATED** Signed Android release + patch |
| ☐ | **NOT VALIDATED** Signed iOS Route B release + patch |
| ☐ | **INHERITED** Invalid signature rejected — **`Strict` mode only, and only at the NEXT BOOT**, after the patch has been downloaded, installed, promoted and reported as a successful download |
| 🐞 | **KNOWN GAP** Key rotation — there is nothing to validate; no rotation mechanism exists |
| ☐ | **NOT BUILT** A documented rotation procedure |
| ☐ | **NOT VALIDATED** Custom signing command (`--sign-cmd`) |
| 🐞 | **KNOWN GAP** The signing algorithm is fixed — a constraint the "KMS-backed" row assumed away |
| ☐ | **NOT BUILT** KMS-backed signing — **aspirational**, folded into `--sign-cmd` rather than standing as its own parity obligation |

**Signing parity: THE DEFAULT VERIFIES NOTHING.** That is the headline, and it is
**inherited**, not a fork regression — worth saying plainly, because an
unvalidated row invites "we should test that" while a gap invites "we should decide
whether we ship that." The security boundary is the **device**, and only in
`Strict` mode; the server stores and echoes `hash_signature` and verifies nothing.

The Route B worry is resolved in our favour, and that part survived re-checking.

> **`SBRBPTCH` is covered for free, and this closes a question §7 previously
> raised.** `vendor/updater/library/src/cache/signing.rs:37` is
> `check_signature(message: &str, signature: &str, public_key: &str)` — it takes
> the hash as a **string**, so signing is *structurally incapable* of caring
> whether the artifact is an Android diff or a Route B container. No investigation
> needed; the earlier note asking whether upstream's signing wraps our container
> unchanged is answered yes.
>
> **`G7`'s server half is nearly empty**, so §16 oversells it as a peer lane to
> `G6`. The server stores `hash_signature` verbatim and echoes it back; the package
> depends on `archive`, `crypto` and `jose` and carries **no RSA library at all**.
> `G7` reduces to one CLI test plus a `SIGNING.md` — do not size it as a
> multi-day lane.

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
| 🐞 | **KNOWN GAP** Restart-required / update-state behavior — decided by the same once-per-process activation guard as §5 and §9, so what the API reports on iOS can be **wrong**, not merely unverified |

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

**Verified 2026-08-11, and it is blocked earlier than anyone thought.**

| | item |
|---|---|
| 🐞 | **KNOWN GAP** Upstream add-to-app support — the control plane's **arch gate** rejects the iOS add-to-app arch strings, and it fires *before* the `aot_tools` blocker everyone was expecting |
| ☐ | **NOT BUILT** Route B release — nothing wires Route B to the `ios-framework` path, and the arch gate above blocks it regardless |
| ☐ | **NOT BUILT** Route B patch |
| 🐞 | **KNOWN GAP** Embedded engine activation — a **second, independently constructed `FlutterEngine` never arms the hook** and runs unpatched AOT |
| ☐ | **NOT VALIDATED** Relaunch |
| ☐ | **NOT VALIDATED** Rollback |

**Add-to-app parity: iOS is BLOCKED, not unvalidated.** Two independent blockers
sit in front of it, and the second is the one worth planning around: Route B arms
its activation hook **once per process**, so an add-to-app host that creates a
second engine — a common pattern — silently runs the *unpatched* code in it. Silent
divergence between two engines in one app is a worse failure than a refusal.

That same once-per-process guard is what decides §5's boot/crash gap and §8's
restart-required behavior. **One mechanism, three sections** — now tracked as a
single project, [`G15 · activation-model`](#14b-the-activation-model--g15-and-the-first-cross-cutting-goal),
rather than as a third of a diagnosis in each of three places.

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
| ◐ | **BUILT** `shorebird release ios` refuses a stale IPA left by an earlier build — commit `c57c6537`. Narrower than it sounds: the guard compares the `.ipa` against the `.xcarchive` produced moments earlier by the same invocation |
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
| ✅ | **SUPERSET / PROVEN** Patch-scoped crash ingestion |
| ✅ | **SUPERSET / PROVEN** Per-patch symbol retention |
| ✅ | **SUPERSET / PROVEN** Android patch symbolication on a real device |
| ✅ | **SUPERSET / PROVEN** Architecture-aware symbol selection |
| ✅ | **SUPERSET / PROVEN** Read-time symbolication (`?symbolicate=true` → `stack_symbolicated`) |
| 🐞 | **SUPERSET / KNOWN GAP** iOS Route B patched-crash symbolication is **structurally unavailable**, not merely untried |

**Four rows upgraded BUILT → PROVEN**, verified against the recorded device runs
2026-08-11: they had automated tests *and* real device evidence, so BUILT was
understating them.

**The iOS row moved the other way, and it is the more important change.** An
interpreted bytecode frame does not appear in a native crash report the way an AOT
frame does, so there is nothing for the symbolicator to resolve. This is a
different problem from the Android one, not a port of it — filing it as
`NOT VALIDATED` implied a device run would close it, and it would not.

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
> **⚠ PREREQUISITES, in this order, before sealing anything:** run
> `prepare_airgap_fixture.sh` (the committed seed has drifted from the fixture);
> get the ownership audit green for the cell in use; and add an iOS **code**-patch
> stage to the harness, which it does not have. Two of the three are `NOT BUILT`
> rather than merely undone — see the gates at the end of this section.

| | item |
|---|---|
| ✅ | **PROVEN** Own control plane |
| ✅ | **PROVEN** Own database / state |
| ✅ | **PROVEN** Own artifact / CDN path |
| ✅ | **PROVEN** Own Android engine artifacts |
| ◐ | **PROVEN for the audited cell `70974f81`** Own iOS engine artifacts — **NOT VALIDATED for the Route B cells actually in use**, which clone their engine artifacts from a donor hash |
| ◐ | **PROVEN for the two audited EXPERIMENTAL cells** Own Dart / frontend / backend toolchain — see the vocabulary warning below |
| ✅ | **PROVEN** Compiler-cell provenance |
| ✅ | **PROVEN** Immutable compiler cells |
| ✅ | **PROVEN** Own patch differ path |
| ✅ | **PROVEN** Own Flutter source mirror |
| 🐞 | **BUILT but currently RED** Artifact ownership audit — failing for `macos-ios`, and never run against any Route B cell |
| 🐞 | **BUILT but STALE** Air-gap fixture — the pub seed no longer matches the fixture's `pubspec.lock` |
| ☐ | **NOT BUILT** A sealed **iOS code-patch** stage — the harness has none; both its iOS patch invocations pass `--assets-only` |
| ☐ | **NOT VALIDATED** The sealed run itself, on a current release |

**Verified 2026-08-11, and "SUBSTANTIALLY PROVEN" was doing too much work.**

**The word "supported" in that toolchain row is inverted.**
`compatibility.yaml:79` says `engine_from_source: false — the SUPPORTED pin still
consumes Shorebird's prebuilt engine`, and reserves **EXPERIMENTAL** for engines we
build ourselves. So the row as written claimed independence precisely for the cells
that do *not* have it. What is proven is the two audited experimental cells.

**Two rows are actively broken rather than merely incomplete.** The ownership audit
is real — it reads its matchers out of the Caddyfile rather than copying them, and
exits non-zero on unprotected artifacts — but it is **red right now** for
`macos-ios`, and has never been pointed at a Route B cell. And the air-gap seed has
drifted from the fixture it seeds, so the next sealed attempt would fail for a
bookkeeping reason and cost a debugging session to attribute. `prepare_airgap_fixture.sh`
should be re-run before anyone books that work.

**The open independence row split in two, and the harness half is the blocker.**
It was filed as one NOT VALIDATED row, implying someone need only *run* the sealed
acceptance. But the harness has **no iOS code-patch stage at all** — both of its iOS
patch invocations pass `--assets-only`. So the row was unrunnable as written, which
is a NOT BUILT, and only then a NOT VALIDATED.

One dependency we cannot reproduce remains: `pkg/aot_tools`, upstream's AOT
linker, used only by the Apple patchers. Route B exists precisely so that it is
not required — see §2, *No Shorebird private AOT linker required*.

**Independence: PROVEN FOR THE AUDITED CELLS / UNAUDITED FOR THE CELLS IN USE.**

### The three gates before this section may claim more

*"Substantially proven"* is too strong while any of these is false, and the section
stays conservative until **all three** are true again. This is a deliberate ratchet:
the phrase was correct when written and drifted without anyone editing it, so the
conditions are now written down instead of remembered.

| | gate |
|---|---|
| ☐ | The **ownership audit is green** for the Route B / iOS cell actually in use — not only for the historically audited `70974f81` |
| ☐ | The **air-gap fixture and its pub seed are current** with each other |
| ☐ | The **sealed harness actually exercises iOS code patching** — today both its iOS patch invocations pass `--assets-only` |

**Do not refresh the seed today.** `prepare_airgap_fixture.sh` is a **pre-run
prerequisite**, not maintenance: it regenerates the fixture and reseeds the pub
cache, and doing that while nobody is booking the sealed path churns the fixture
for no result — `R6` is a contended resource (§16), and the drift costs nothing
until someone runs the acceptance. Run it **immediately before** the next sealed
attempt, then re-check `SEED.txt` against the fixture's `pubspec.lock`.

The drift is recorded rather than fixed precisely so the next runner sees it before
booking, rather than losing a session to a bookkeeping failure that looks like a
sealing failure.

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

## 14b. The activation model — `G15`, and the first cross-cutting goal

> **`G15 · activation-model` — goal:** Route B's activation is decided **once per
> process**. Make it correct per engine and per boot instead.
> **Done when:** a Dart-phase crash backs the patch out; the manual API reports a
> restart-required state that is true on iOS; and a second `FlutterEngine` in the
> same process runs the **same** program version as the first.
> **Owns:** `R3` + a mint, `R1`. Engine work, not producer work.

**Every other goal in this file is section-scoped. This one is not, and that is the
point.** It was previously three rows in three sections, each filed as its own
unvalidated question:

| symptom | filed under | what it actually is |
|---|---|---|
| a Dart crash is never backed out | §5 | `ReportLaunchSuccess` fires in the `Shell` **constructor**, before the root isolate exists — so "launch succeeded" is recorded before the patch can fail |
| restart-required may be misreported | §8 | the same guard decides it, so the API can report something **wrong**, not merely unverified |
| a second engine silently runs unpatched AOT | §9 | the hook is armed once per process; engine two never arms it |

**The second-engine case is the severe one.** It produces two Flutter engines in one
process executing **different program versions**, with no error, no log, and no
user-visible failure — the app simply behaves inconsistently depending on which
engine served a screen. Add-to-app hosts create engines lazily and sometimes more
than once, so this is a mainstream configuration, not a corner.

**Why it ranks 4th and not 1st.** It constrains reliability, not reach: fixing it
makes the ~7 % surface *trustworthy* without making it larger. Language reach
(`G3.6e`, `G3.7`) changes what the product can do; this changes whether what it does
can be depended on. Both are needed; reach was ranked first because a fundamental
limitation there would reshape everything below it.

Three sections keep their rows and now point here, rather than each carrying a third
of the diagnosis.

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
| ☐ | **A Dart-phase crash backs the patch out** | §14b, `G15` |
| ☐ | **Two engines in one process run the same program version** | §14b, `G15` |
| ☐ | Every unsupported upstream workflow is explicitly documented rather than silently failing | this file |

**Two of seventeen** — and the characterisation an earlier draft gave is wrong now.
It said "the thirteen remaining are mostly breadth." After the 2026-08-11
verification pass they are not: several are **known blockers** rather than untested
breadth, which is a worse position on paper and a better one in practice, because a
blocker can be designed against and an unknown can only be scheduled against.

Two gates were **added** rather than discovered unmet — `G15`'s crash-backout and
same-version-per-engine — because they were previously hidden inside "rollback /
rejection / failure matrix" as though a test run would settle them.

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
| **R12** | `hermes-vps` — the Linux build host, with two reverse tunnels plus `adb reverse` on the Mac | needed by `G4.2`'s Android half (`accept_android_default.sh:17-19` makes the Linux-only constraint real, not folklore). **Additive capacity** — a separate machine nobody schedules against, and it was missing from this table until 2026-08-11 |

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

Four concurrent lanes, contending on nothing. Updated 2026-08-11 18:4x, after the
`G3.1`/`G3.2`/`G3.3` rungs all closed:

| lane | goal | resources held |
|---|---|---|
| **Reachability** | `G3.6a app-private-decision` — the measurement, the layer map, the probe | `R3` **read-only** (compiles probe arms against the published cell) |
| **Server** | `G6 tracks` server half — five of six non-device rows | `R10` only. No ports, no Postgres, no control-plane instance — so not even `R8`/`R9` |
| **Device — Android** | `G4.2 flavors`(android), on its **own** flavored fixture | `R2`, `R9`, `R12` |
| **Device — iOS** | `G3.5 closures-super`, or `G3.6b`'s hole-closures once `G3.6a` answers | `R1`, `R3`, `R6`, `R7`, `R11` (a mint) |

The iOS lane is listed last on purpose: it is the **most expensive** lane, holding
five resources at once, and after three rungs closing in one afternoon it is also
the one with the least leverage left. `G3.4` is refused by derivation, so there is
no cheap rung to feed it.

`G7`'s server half does **not** make a fifth lane — it is one CLI test plus a
`SIGNING.md` (see §7). Do not staff it as one.

That is the honest ceiling: **four**, of which two need no device at all. Raise the
ceiling by fixing `R6` — nothing else on this list buys as much parallelism per
hour spent, and `G4.2`'s own flavored fixture is a down payment on exactly that.

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
| `R1` iPhone 7 | — | — | released 18:2x | **free.** `G3.3`'s gate committed as `fa40f6ca` |
| `R2` Android device | — | — | — | **free** |
| `R3` route-b tree | **`G3.6e` session** | `G3.6e` + `G3.6b` | 2026-08-12 | **HELD, and this one WRITES.** Editing `pkg/front_end` and `pkg/dart2bytecode` SDK sources, then building. `dart_patches.sh --verify` before every build; do not `gclient sync` |
| `R4` ios-engine tree | — | — | — | **free** |
| `R6` canonical fixture | — | — | released 18:2x | **free** at version `22.0.0+1`; next release bumps to 23 |
| `R7` producer/analyzer | **`G3.6e` session** | `G3.6b` | 2026-08-12 | **HELD** — the analyzer's private-member refusals relax in step with the CFE change, and both share one mint |
| `R8` `cps-ios` | — | — | released 18:2x | **free** |
| `R9` `cps-android` | — | — | — | **free** |
| `R10` server source | — | — | — | **free** — the `G6` lane |
| `R11` sealed CDN | **`G3.6e` session** | `G3.6e` mint | 2026-08-12 | **HELD** for a cell mint — `analyze_coverage.dart` and `dart2bytecode.aot` are both manifest files, so this is one address change, not two |
| `R12` hermes-vps | — | — | — | **free** — additive capacity for `G4.2`'s Android half |

> **A stale row was cleared to write these.** The previous `G3.6a` read-only `R3`
> claim outlived its holder, who stopped without clearing it — caught by the study
> session, which is the table working as designed and is also exactly the weakness
> flagged when it was introduced. The rule stands and now has a precedent: **clear
> your row when you stop, even mid-goal.**

> **The table emptied itself twice on 2026-08-11, and both times that was the
> protocol working.** The `G3.1` holder released every resource by committing
> `edbbd80b`; the `G3.3` holder did the same at `fa40f6ca`. A claim's lifetime is
> the uncommitted-changes window, and committing ends it — which is why the tell in
> the next subsection is worth more than the table itself.
>
> Rows here have so far been **inferred from the tree rather than declared**, which
> is the weakness this table exists to remove. Declare yours rather than leaving
> the next worker to infer.

### Starting a new worker — the block to paste

Any new session, agent or teammate gets this before touching anything. It is
written to be self-contained, because a new worker shares no context with the
ones already running.

```
Before running anything in this repo, read selfhost/PARITY.md §16 and §17.

§16 lists the eleven contended resources (one phone per platform, one Route B
engine checkout, one canonical fixture, two control planes). §17 is the protocol
for sharing them. The short version:

1. This is a SHARED working tree. Stage explicit paths — `git add <path>`. Never
   -A, never `commit -a`, never stash/restore/checkout/branch-switch. Another
   worker's in-flight edits are sitting unstaged next to yours.
2. Do code work in your own `git worktree`. Docs a single worker owns can live in
   the shared tree; anything under packages/ or selfhost/engine/route_b/ cannot.
3. Check §17's claims table, then claim what you take IN THE SAME COMMIT as the
   work — and clear your row when you stop, even mid-goal. A stale claim is worse
   than no claim. R1 (the phone) and R3 (the engine checkout) cannot be shared and
   cannot be detected; if you don't claim them, someone else will assume they're
   free.
4. Pick a goal ID (G1..G14) whose resources are unheld, and say which one you're
   taking before you start. The queue at the bottom of PARITY.md is priority
   order, not a schedule — §16 says what can actually run at once.
5. An uncommitted fixture version bump beside a fresh line in
   selfhost/cdn/experimental_hashes.map means a device gate is running RIGHT NOW.
   Back off R1, R3 and R6 until those changes are committed.
6. Never mark an item PROVEN from a host probe, a passing unit test, or a
   generated container. See "Rule for updating this file" at the bottom of
   PARITY.md. Host work earns BUILT.
```

### What is safe to pick up right now

Given those claims, the free lanes are the **Android device** (`R2`, `R9` — so
`G4.2 flavors`(android)), the **server halves** of `G6`/`G7` (`R10`, no
hardware), and `G3.6 app-private` (no resources at all). Everything on the iOS
critical path is held.

---

## Immediate parity queue

**This is a priority order, not a schedule.** What can run *simultaneously* is
§16's question, and the answer there is roughly four lanes. Read both.

### The transition, and what it does to this queue

**Core mechanism work is largely done. The real constraints are now structural
coverage and safety semantics.** That is a different project from the one this file
opened on, and the queue below reflects it. Established, not assumed:

* iOS delivery and runtime are **not** the bottleneck — §2 is closed.
* **Lexical widening is not the bottleneck.** Three rungs closed in one afternoon
  and the reach barely moved, because the limit was never syntax.
* Compound writes and `super` have **low observed demand** — 0 and 2 occurrences
  across ten real commits.
* The dominant **coverage** limits are privacy scope and method ABI, measured at
  near-equal weight from two independent directions.
* The dominant **safety** gap is the once-per-process activation model, because one
  mechanism produces three separate product failures.

**The architectural question, restated 2026-08-12 because half of it is answered.**

It was: *can Route B preserve the target library's identity/privacy, and carry the
target method's actual parameter contract?* The privacy clause is **answered yes** —
`G3.6e` closed rung D on the host, and the mechanism was already in the front end.
So the question is no longer whether the model permits it. It is:

> **Can the product do it automatically — preserve and target the correct library
> identity, and retain the private release members a future patch may need?**

That is a materially more tractable problem than the earlier framing implied.
"Synthetic-library privacy is impossible" was the top Phase 0 blocker; it has become
two engineering tasks with known shapes — an analyzer/producer path (`G3.6b`) and a
retention policy (see §3's retention note). Neither is a research question.

`G3.7` remains the other clause, and it is untouched: the parameter contract. If it
turns out to be a fundamental limitation, **that finding is worth more than another
dozen syntax rungs**, because it bounds what the product can ever be rather than
what it currently does.

**Stopping rule for syntax widening.** Do **not** resume lexical rung work unless
real compatibility data identifies a lexical blocker at meaningful frequency. Today
the evidence points elsewhere, and every rung is a mint plus a scarce device gate.

### Priority order

1. **`G3.6c` + `G3.6d` device gate** — cheap closure of already host-proven work.
   No new mint, rides an existing release as one more patch.
2. **`G3.6e resolve-in-library`** — the highest-leverage language work. Privacy is
   the strongest measured blocker from **both** directions: structural reach
   (→29.8 %) and Phase 0's real commits (top blocker in 9 of 10). Feasibility is
   established and the mechanism is located.
3. **`G3.7 param-abi`** — comparable upside (→33.2 %), distinct from privacy, and
   worth measuring **separately** so the two are never credited to each other.
4. **`G15 activation-model`** — the highest-leverage safety/reliability project
   after language reach. See below; it is one redesign, not three fixes.
5. **§13 independence gates** — matters for the strength of the self-hosting claim,
   but does **not** currently constrain Route B's language capability. That is why
   it sits below a safety project despite being nearly done.

### Then, in rough order

6. **`G3.6b app-private-holes`** — the two accepted-then-failed holes. Costs `R7` +
   a mint; fold into `G3.6e`'s mint rather than paying twice.
7. **`G4.1 dart-defines`** — the **provenance + threading** work lifted out of
   `G4.2`; `G4.3` reuses it.
8. **`G4.3 obfuscation-ios`** — the untested half; Android is proven.
9. **`G4.2 flavors`** — Android half needs no `R1`; do the host probe before `R2`.
10. **`G6 tracks`** device row — follows `G8` or `shorebird preview`, since
    `channel` does not reach the device.
11. **`G7 signing`** — small in code, but see §7: the **default verifies nothing**,
    which is a decision to make before it is work to do.
12. **`G8 manual-api`** — needs its own fixture, so it does not contend on `R6`.
13. **`G9 add-to-app`** — iOS is blocked twice over; Android first.
14. **`G10.2 noninteractive`** CI workflows.
15. **`G5 lifecycle-matrix`** — what remains after `G15` takes the safety gaps.
16. **`G13 sealed-independence`** — the run itself: **last, and alone.**
17. **`G3.5 closures-super`**, **`G3.4 compound`** — held by the stopping rule
    above. Not scheduled; resume only on frequency evidence.
18. **`G14 desktop`** — deferred; do not start it early.

### Banked this session

| goal | closed by |
|---|---|
| `G3.1 arg-abi` | `9192a594` + `edbbd80b`, release `21.0.0+1` |
| `G3.2 this-spellings` | `8907239a`, two patches on release 21, no new release |
| `G3.3 setters` | `cb50590d` + `fa40f6ca`, release `22.0.0+1` |
| `G3.6a app-private-decision` | `d91e21d0` — answered: reachable, mechanism located |
| `G3.6c` + `G3.6d` | `a28ba1d9`, `059573ca`, `a2927e41` — host-proven pair, +0.01 % |
| `G10.1 stale-ipa` | `c57c6537` |

### Off-queue and nearly free

* ~~Reconcile [`README.md`](README.md) with this file~~ — **done 2026-08-11.**
  Three stale claims corrected and the producer caveat re-aimed at the language
  surface; see *Documentation drift* above.
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

### The classification rule

> **If source already determines the behavior, it is a KNOWN GAP, not an
> unvalidated question.**

`NOT VALIDATED` means *nobody has run it*. `KNOWN GAP` means *we know what it
does, and it is wrong or absent*. The difference is not cosmetic, because the two
labels dispatch different work: an unvalidated row invites *"we should test that"*,
which books a device and a release; a gap invites *"we should decide whether we
ship that"*, which is a design call and needs no hardware at all.

The 2026-08-11 verification pass moved seven rows across that line — boot/crash
rejection, wrong-release install, rollback-to-earlier-patch, corrupt-at-rest,
default signature verification, restart-required semantics, iOS symbolication. Each
had been queued as something to validate, and each was already answered in the
source. **Before adding a row to the device queue, check whether reading the code
closes it.**

### The correction rule

> **A proposed correction needs evidence exactly as much as the original claim
> did.**

Corrections feel like rigour, so they get waved through — but a wrong correction is
worse than a stale row, because it launders a guess into the document as a fact and
arrives wearing the authority of a fix. Two independent things enforce this, and
both have already paid:

* **Verify the evidence at the cited location.** The adversarial passes over the
  2026-08-11 corrections killed four. The sharpest was a claim that no CI workflow
  invokes the CLI — `.github/workflows/e2e.yaml` drives `init`, `doctor`,
  `release android`, `preview` and `patch android` end to end.
* **A negative grep is not coverage, and one verified fact does not license an
  inferred second.** Both of §6's retracted claims failed exactly there: `grep beta`
  returning nothing became "the server half is absent work", and a real
  channel-omission became "permanently stable-only".

When a correction retracts an earlier claim of your own, **say so where the claim
sat** rather than editing it silently. §6 keeps both retractions in place for that
reason: a reader who acted on the old text needs to know it changed.

When an item becomes PROVEN, record beside it whichever of these apply:

* engine hash;
* release version;
* patch number;
* platform / device;
* evidence or probe name;
* the commit containing the implementation and its gate.| `R3` route-b tree | *paused docs session* | `G3.6e` in flight | 2026-08-12 | **NOT FREE.** The Dart tree carries 18 uncommitted files including a half-finished `resolvePrivateNamesInLibrary` that does not compile. The study session minted against it by mistake and has voided that baseline. Do not mint until `dart_patches.sh --verify` is green |
