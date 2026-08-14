<!-- cspell:words dartaotruntime SBRBPTCH sbrbptch dynmod tearoff disqualifiers IOUSB ioreg xctrace -->
<!-- cspell:words unvalidated noninteractive prepass jank recognise -->
<!-- cspell:words schedulable startable worktree oneline unheld diffstat -->
<!-- cspell:words overclaim DFLUTTER Diagnosticable -->
<!-- cspell:words demangled specializer devirtualizes rationalised synthesises -->
<!-- cspell:words subshell theorised generalises generalisable symbolicator unrunnable -->
<!-- cspell:words foldable foldability materialised objdump ldur stur restages -->
<!-- cspell:words characterisation backout NONAOT Wonderous analysed askable localises precommitted executably precommitment constructibility unreviewed favourable synthesised targetable -->

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

…plus a `dart:core` reference, a call to another public top-level app function, a
private helper the replacement declares itself, and — since release `31.0.0+1`
patch 2 — a **read** of a release-private instance field granted through
G3.6b/P2 (`_secret`, lowered to `self._secret`). It **refuses** cascades,
`super`, compound writes, and any access kind it does not recognise. Refusal is
the designed failure mode: erring costs a rejected patch, never a wrong one.

The rule the accepted set follows is not "a self-contained body" — that was the
historical approximation. It is that **every reference must resolve inside the
release's declared retention**: the dynamic interface from the kernel prepass, plus a
capability-manifest grant for a private member. A private **write** is not
proven and is not claimed.

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
| ⛔ | **DEVICE GATE BLOCKED — prerequisite missing: a parameterised target on the LIVE path.** Found 2026-08-13 before cutting the patch. The fixture's only parameterised method, `tagged(String x)`, is called just once — inside `value()`'s DEAD branch, which exists to keep it retained past tree-shaking while the live branch returns a constant. A patch to it would execute never and show nothing. Note what this defeats: `assert_result_consumed.sh` reports that site **CONSUMED**, correctly, because its result feeds a string interpolation — so **consumption is necessary but not sufficient; reachability is a separate property no byte-level gate can see**. The fixture needs a parameterised target called on the path the app actually takes; that is a fixture change and its own release |
| ◐ | **BUILT 2026-08-13, host-proven with two negative controls** Replacement methods with explicit source parameters — **`G3.7 param-abi`, worth 33.2 %**. `g37_param_abi.sh` 4/4: a one-parameter and a two-parameter target patched and executed through the real producer path; named and optional-positional targets refused at patch time against IDENTICAL release bytes. Contract in patch `0006`, pinned by `c_entrypoint_arity.sh` 8/8. Device gate needs a mint | the replacement's **own** signature, distinct from the call it makes. The entry-point contract is 0-or-1 positional and the receiver already claims the one slot; `9192a594` did not widen it. **This single item is worth more than the entire privacy problem** — see the measurement above |
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
| **`G3.6b app-private-holes`** | close the two accepted-then-failed holes | **PROVEN on device 2026-08-13** (was BUILT, host-proven with two negative controls). Analyzer v7 REPORTS a private access with its manifest key; the CLI accepts it only against the release's own capability manifest. `cli_private_member.sh` **10/10**: granted → the app reads the patched private field; class withheld → refused in the CLI, naming the class; no manifest → refused, naming the absent evidence. **Device round-trip CLOSED 2026-08-13**: release `31.0.0+1` patch 2, `value() => _secret` lowered to `self._secret`, displayed `NEW-PRIV` on an iPhone 7 from byte-identical installed release bytes (`c7661317`). PROVEN for a private **read**; a private write is not claimed | done at `R7`; the mint publishes it |
| **`G3.6c dynamic-receiver`** | emit `dynamic` instead of a private class name | **BUILT, host-proven as a pair with `G3.6d`** — `probes/private_receiver.sh` 4/4, a patch on a private class runs. Device round-trip outstanding | done at `R7`; no mint |
| **`G3.6d private-retention`** | retain private classes, procedures **and fields** in the dynamic interface | **BUILT, host-proven and shown LOAD-BEARING by a negative control.** Cost measured: **+0.01 %** | generator only, as predicted — no validator or CFE change |
| **`G3.6e resolve-in-library`** | thread `resolveInLibrary` through dart2bytecode | **PROVEN 2026-08-13 for a private FIELD READ.** Both of its own done-criteria are met by release `31.0.0+1` patch 2 (`c7661317`): the **producer** path, not a hand-written replacement, and a **device** round-trip — `value() => _secret` → `NEW-PRIV` on an iPhone 7. `route_b_producer.dart:175` passes `--resolve-private-names-in-library` only when the manifest grants the member, and per this goal's own failure table a missing visibility mechanism fails at COMPILE time; the patch compiled and ran, so the mechanism was in the path. Host: `probe D` 4/4, `a53029c9`, patch `0005`. **A private METHOD/GETTER call is host-proven only** | done at `R3`; no mint needed |
| **`G3.7 param-abi`** | a replacement method may declare **its own parameters** | **BUILT 2026-08-13.** Feasibility is no longer inferred: patch `0006` widens the contract from 0-or-1 to any number of REQUIRED positionals, the analyzer refuses exactly what the compiler refuses (`analysisVersion` 8), the producer inserts the receiver in front of a verbatim-copied parameter list, and `g37_param_abi.sh` 4/4 proves arguments arrive **in order and by type** — `int b` = 7 landed in slot `b`, so this is not mere arity. Device gate outstanding: the cell carries `dart2bytecode.aot`, so it needs a mint | mint + `R1` remain |

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
| ✅ | ~~**KNOWN GAP** a retained private instance member of a never-allocated class has no executable body~~ — **REFUTED 2026-08-12.** `probes/dead_body.sh` `live=0 dead=0`: the body ran. An interface entry makes the member a *root*, not merely present |
| ✅ | **PROVEN** `probes/dead_body.sh` discriminates all three modes, and reports which precommitted matrix row it landed on |
| 🐞 | **KNOWN GAP** Retaining a private **class** makes it **allocatable from a patch** — the patch constructed `_Dead()` with **no constructor named in the interface**, because a `class:` item covers the implicit public default constructor. A capability grant nobody requested |
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

**TWO failure modes, not three.** A third was predicted from source and **falsified
experimentally** on 2026-08-12 — kept below as history, because how it was wrong is
what settled the policy question:

| # | failure | how it presents | status |
|---|---|---|---|
| 1 | **visibility** — the replacement cannot name the member | compile error: *"the getter '_secret' isn't defined"* | closed by `G3.6e` |
| 2 | **retention** — the member is not in the release | load error: `bytecode_reader.cc:1172 Unable to find function` | closed by `--private-dill` |
| 3 | ~~**dead body** — retained with no executable body~~ | ~~nothing; the call enters an unreachable stub~~ | **DISPROVEN — does not occur** |

<details>
<summary>The mode-3 prediction, and why it was wrong (kept deliberately)</summary>

It came from the `DirectSelector` / `InterfaceSelector` distinction. A private
top-level or static member named in the interface becomes a raw direct call, so TFA
analyses and retains its body. A private **instance** member whose enclosing class is
never *allocated* becomes an interface selector over that class's cone type — and with
nothing in the cone, the reasoning went, the body never becomes reachable and TFA pass
2 replaces it (`transformer.dart:2348-2360`).

**The step that reasoning skipped:** an interface entry does not merely leave a member
present. `dyn-module:callable` resolves to `PragmaEntryPointType.Default`, the same
thing `vm:entry-point` produces, which makes the member a **root** — and TFA keeps a
real body for a root regardless of allocation. `_makeUnreachableBody` is what happens
to a member nothing rooted, which a retained member by definition is not.

`probes/dead_body.sh` measured `live=0 dead=0`: the never-allocated class's body ran.
The failed prediction and the probe's failing dead-arm assertion are both preserved —
rewriting either would erase the evidence that a source-derived safety hazard did not
reproduce.

</details>

**What this removes and what it leaves.** It removes a safety boundary: there is no
live-vs-dead distinction to detect, because retention *creates* liveness. It leaves a
**capability** question, discovered in the same run — the patch constructed `_Dead()`
with no constructor named in the interface, because a `class:` item covers the
implicit public default constructor. Retaining a private class makes it
**constructible from a patch**.

#### Ordered gate before any cost number

Cost is the *last* question, not the next one. A measurement taken before the
contract is closed prices "whatever a particular generator happened to enumerate"
rather than a policy. In order:

**Mode 3 is not currently loose in the product.** It becomes possible only when
non-AOT private enumeration starts retaining otherwise-dead private *instance*
members. That localises the hazard to the feature that creates it, and reorders the
gate accordingly:

| | step | |
|---|---|---|
| ✅ | **1. Land `--private-dill` / non-AOT enumeration as CORRECTNESS infrastructure** with its guard | `cd453304` |
| ✅ | **2. Rerun `probes/dead_body.sh`** against it | 2026-08-12 |
| ✅ | **3. Require the live control to become mode 0** | `live=0` |
| ✅ | **4. Observe what the dead arm becomes** — matrix committed in advance | `dead=0`, mode 3 **disproven** |
| ✅ | **5. Settle the threat model** — **DECIDED**: within the Dart capabilities of the shipped app, patch authority is release-equivalent. Private reach is a compatibility question, not a security one — with a scope qualification and an expiry condition, both below |
| ✅ | **6. Define candidate permission policies** — in code as `--policy p1\|p2\|p3`, not in prose |
| ✅ | **7. Run Wonderous against those exact policies** — done, both tables recorded below. **One gap: P3's runtime reachability is inferred, not measured** |
| ✅ | **8. Choose the policy explicitly** — **P2**. P3 is non-viable, not unselected |
| ✅ | **9. `G3.6b`** — accept only when the release's emitted set proves member **+** enclosing-class capability **+** not-skipped. **Done.** 28 unit tests plus `cli_private_member.sh` 10/10. All five precommitted analyzer cases are matched, and two more were added that the precommitment did not ask for: a static of a private class still needs the class item, and the flag's own blast radius is bounded (see below) |
| ◐ | **11. OPEN, and the branch is DECIDED: the fault is common to all replacements.** On release `24.0.0+1` (7,141 patchable sites, identity verified), BOTH bodies fail identically — `self._secret` (patch 1) and `'NEW-CTL'` (patch 2, no private reference at all). Same trace both times: `applied 1/1 targets`. Same behaviour both times: `NEW-SET`. So the private-bearing load/bind path is NOT implicated, and the thing to instrument is the generic **post-attach Function transition** — bytecode attached?, entry point before vs after, is that entry point the interpreted dispatch path |
| ~~◐~~ | ~~**11. Earlier: still open, boundary exact**~~ Release `24.0.0+1` cut WITH `--patchable_static_calls`: **7,141 patchable sites, 1,775/MB — PATCHABLE**. Identity verified both ways (`assert_installed_release.sh`: installed `a022fbd1…` == patch target). Patch B published, downloaded, `code patch: 1`, trace says `applied 1/1 targets` — **and the value is still `NEW-SET`**. Patchability was a real defect, not the cause. What remains is the state the trace cannot see: attach returns success and the active entry point either never changes or the call site never consults it |
| ~~✗~~ | ~~**11. Earlier: cause found in the release command**~~ The release `23.0.0+1` was cut WITHOUT `--patchable_static_calls`. `verify_patchable_release.sh` measures **8 patchable sites, 2 per MB** against a 100/MB threshold, and its own message is the observed symptom verbatim: *"a Route B patch will attach successfully and change nothing: AOT emitted direct calls that never consult `Function.entry_point_`."* The on-device diagnostic agrees exactly — `applied 1/1 targets`. Three independent facts, one cause. The device gate must be re-run against a release cut WITH the flag |
| ~~◐~~ | ~~**11. The device gate is OPEN, and the matched control moved the boundary.**~~ `value() => 'NEW-CTL'` — no private reference, same release, same target, same cell, engine identity pinned throughout — **also did not apply** (`code patch: 3`, value unchanged). So the private-bearing bytecode is NOT the differentiator, and neither is engine identity. The container's `release.buildId` equals the installed app's `LC_UUID` (`2d497ada…`) and its selector is `RouteBThing.value`, so delivery, identity and targeting are all correct. What is left is container-parse → target-resolve → payload-load → `AttachBytecode`, on device, and that needs observation rather than another hypothesis |
| ~~◐~~ | ~~**11. The device gate is OPEN.**~~ Two runs: patch 1 (engine mismatch) and patch 2 (identity matching, both gates passed) BOTH installed, reported themselves active, and left the value unchanged. Host passes the identical shape against the same published cell, so the producer/manifest/CFE chain is not what fails. Next: engine-side visibility into why the attach or bind fails on device |
| ✅ | **10. One combined cell mint** — **`ee001fd78fcd5e78e976d35284bd13e1caffff63`**, donor `50d58cc3`, engine binary cloned byte-for-byte so only the CELL differs. `audit_route_b_compiler.sh` clean, and `cli_private_member.sh` **10/10 again against the PUBLISHED zip** — the staged run proved the bytes, this proves the publication. **Only the device round-trip remains** |

**Steps 1-4 are closed, and they changed what steps 5-10 are.** The gate was built to
answer a safety question; the answer removed the safety question and left a capability
question, so the tail of the list is new rather than merely renumbered.

**`dead_body.sh` did its job by being wrong in the useful direction.** It was built as
the safety gate on the feature that was thought to introduce a hazard; it demonstrated
the hazard does not exist. Its dead-arm assertion still fails, and stays failing: it
encodes the precommitted prediction, and preserving a falsified prediction beside the
evidence is worth more than a green suite.

**Do not "fix" the probe to go green.** Mirroring a *product* change is legitimate —
that is why it now passes `--private-dill`. Touching the fixture, the assertions or
the dead arm to obtain a green control is not: the live arm moving mode 2 → mode 0 is
the only signal that says whether private instance members actually became reachable.

#### The decision tree, committed before the run — and the row it landed on

Written down in advance so the result could not be rationalised afterward. It landed
on the third row:

| | live arm | dead arm | what it means |
|---|---|---|---|
| | mode 0 | mode 3 | the liveness distinction is **product-critical** — `live-instance` needs a mechanical liveness signal or stays refused permanently |
| | mode 0 | mode 2 | the retention policy **already excludes** the unsafe dead case; the boundary falls out of the mechanism rather than needing to be designed |
| **← observed** | **mode 0** | **mode 0** | **no live-vs-dead boundary exists to draw** — a never-allocated class's body executed, so nothing distinguishes executable from dead, and the question stops being safety and becomes capability |
| | mode 2 | any | **`--private-dill` correctness is incomplete** — step 1 is not done, and nothing below it reads |

**The precommitment earned its keep.** The observed row was written as "broad
private-instance retention is **unsafe** unless liveness can be distinguished" — and
the run showed *why* it cannot be distinguished: retention **creates** liveness, so the
unsafe case never arises. Same row, and the reasoning had to move to meet it. Had the
matrix not been fixed in advance, `dead=0` could as easily have been read as
"everything works, ship it."

#### MODE 3 REFUTED — measured 2026-08-12, `live=0 dead=0`

`probes/dead_body.sh`, rerun against the landed `--private-dill` plumbing, lands on
the third precommitted row. **The dead-body hazard does not exist.**

```
_secret entries in interface: 2        (one per class)
release reports:  dead=unallocated     _Dead genuinely never allocated
live arm  -> mode 0, alpha = NEW-LIVE
dead arm  -> mode 0, alpha = NEW-DEAD  <- the never-allocated class's body RAN
```

**Why the source reading was wrong.** Naming a private instance member in the
interface does not merely leave it *present* — `dyn-module:callable` resolves to
`PragmaEntryPointType.Default`, the same thing `vm:entry-point` produces, which makes
the member **reachable**. TFA then keeps a real body regardless of whether anything
allocates the enclosing class. The `_makeUnreachableBody` path is what happens to a
member nothing has made a root; an interface entry makes it a root.

So `live-instance` is **not unsafe for the reason it was refused.** The silent-no-op
hazard that justified refusing it is disproven by construction.

**But a different finding replaces it, and it is a capability grant nobody asked
for.** The patch called `_Dead()._secret()` — it **constructed** a class the release
never constructs — and **no constructor was named in the interface** (verified: zero
constructor entries). A bare `class:` item annotates the class and its *public*
members, and a class's implicit default constructor is public. So retaining a private
class makes it **allocatable from a patch**.

That reframes the policy question exactly as the third row says it should:

* there is **no live-vs-dead boundary to draw** — retention *creates* liveness, so
  no mechanical signal could distinguish "safe to accept" from "unsafe", because the
  unsafe case does not arise;
* what remains is **breadth and permission**, not execution safety. Broad
  private-instance retention means a patch may call any private member, executably,
  on classes the release never instantiates — and may construct those classes.

`live-instance` therefore stays **refused pending a permission decision rather than a
safety one**, which is a different question with a different owner. The §16 coupling
note is now load-bearing in a way it was not when written: retention and permission
being one document means "retain every private" silently reads "a patch may
instantiate and call any private class of the app."

**Two probe defects found and fixed in the process**, both mine, both worth naming
because each produced a *correct verdict with a wrong reason*:

* the classifier compared `got` against the sentinel `NOT-EXECUTED`, which can never
  match, so an executed dead body was labelled **mode 3** while its own assertion
  correctly failed. Fixed to compare against the value the body would produce.
* the probe originally passed no `--private-dill`, correctly mirroring the product
  *at the time*. Once the product changed, mirroring it became the legitimate edit —
  as distinct from touching the fixture, the assertions or the dead arm, which would
  have been gaming the control.

The dead arm's assertion is left **failing on purpose**: it encodes the precommitted
prediction, and the prediction was wrong. The probe now prints which matrix row it
landed on, so the finding is the output rather than something inferred from a
pass/fail count.

#### Superseded: mode 3 was thought to be introduced by the fix — measured 2026-08-12

`probes/dead_body.sh` was built to give mode 3 its own negative control instead of
resting on source inspection. It reports **1 passed, 1 failed — and the failure is
the positive control**, which is the diagnostic:

```
_secret entries in interface: 0          for BOTH classes
live arm  -> mode 2: Unable to find function _secret@17057535
             in Library:'…container_target.dart' Class: _Live@17057535
dead arm  -> mode 2, identically
```

The fixture worked as designed — the release reported `live=live dead=unallocated`,
so `_Live` really was allocated and `_Dead` really was not. And **privacy resolution
is genuinely closed**: the failing name is correctly keyed to the app library *and*
the enclosing class. What failed is retention, for **both** arms, because the
generator reads the `--aot` prepass and TFA had already dropped `_secret` — nothing
in the release calls it. The interface names both **classes**, but a `class:` item
retains only *public* members (§3's own finding), so a private member needs its own
`member:` entry and there was nothing to emit one from.

**So mode 2 masks mode 3 universally, and the masking is structural:**

* to name `_secret` in the interface, the release must reference it;
* referencing `_Dead()._secret()` **allocates** `_Dead`;
* so *"named in the interface but never allocated"* is **not constructible** while
  private enumeration reads the post-TFA prepass.

**Mode 3 is therefore a hazard introduced by `--private-dill`, not a pre-existing
one.** Non-AOT enumeration is what first makes it possible to name a member TFA
dropped, and only then can a retained-but-never-allocated member exist at all. The
probe moves **inside step 2** and is left **red on purpose** — its control is a
pending gate, not a broken test, exactly as `probe D`'s question (1) is.

That also sharpens the policy bar rather than relaxing it: `live-instance` stays
refused, and the probe is now the instrument that will decide whether "live" has a
mechanically detectable boundary the moment step 2 makes the question askable.

#### MANDATORY with step 2 — the `--private-dill` guard

`--private-dill` moves a build-order dependency, and that is the part to get right
before the feature: enumerating from the non-AOT kernel means `release_import.dill`
must be built **before** `flutter build ipa`, which converts any import-kernel /
release divergence from *"patches get refused, the release is fine"* into *"the
release build fails inside the CFE."* A patchability mismatch must never become a
release outage.

So the guard ships with the flag, not after it:

```
build release_import.dill first
  → compare it against the release prepass
    → agree?     use it for private enumeration
    → disagree?  fall back to prepass-only enumeration, and preserve the
                 NARROWER patchability contract
```

The fallback is the point. Degrading to a smaller patchable surface is a product
decision the release can absorb silently; failing the build is not. And the narrower
contract must actually be *recorded* on fallback, so `G3.6b` accepts against what the
release really retained rather than what the policy nominally promises — the same
per-target discipline as the contract below.

#### The question is no longer safety — it is which capabilities to grant

The old framing was *"can we prove live-instance is safe?"*, and it is answered: there
is nothing to prove, because a retained member is executable. The `live-instance`
category as written — refused pending a mechanical liveness signal — is therefore
**retired**, and replaced by:

> **Which private capabilities are we willing to grant a patch, and what does each
> policy cost?**

**Candidate policies, to be measured against each other rather than argued about.**
These are the exact arms Wonderous should price:

| policy | grants | notes |
|---|---|---|
| **P1 top-level/static only** | private top-level functions and fields, private statics | the shape `probe D` proved. Narrowest, and the only one whose cost is already known to be ~+0.01 % |
| **P2 all app-private** | every private member and class of the app's own libraries: instance members, fields, accessors, **and construction of private classes** | broadest. What non-AOT enumeration currently produces |
| **P3 a narrower middle**, *if one exists worth measuring* | e.g. private members of classes the release **already allocates**; or members but **not** classes, withholding constructibility | to be defined only if the mechanism supports it cleanly — an arbitrary middle is worse than either end |

**Each arm produces TWO tables, not one.** The failure mode to avoid is P1/P2/P3
becoming *size profiles* — a policy is a pair, and the second half is the one that
cannot be recovered later:

**Table 1 — cost.** Binary/snapshot delta, interface delta, retained-member delta,
split per shape.

**Table 2 — authority expansion.** A **capability manifest**, answering concretely:

| | the manifest must enumerate |
|---|---|
| 1 | private **top-level/static** members newly callable |
| 2 | private **instance** members newly callable |
| 3 | private **classes** newly **constructible** |
| 4 | any **constructors or factories exposed implicitly** by class retention — the `_Dead()` case: granted with no constructor ever named |
| 5 | any categories **skipped or refused**, and why |

Rows 3-5 do not exist today. `privates_added.txt` covers rows 1-2; constructibility is
inferred from nothing, and the skipped set is counted but not listed. Building the
manifest is therefore part of the arms, not a report on them.

Row 5 matters as much as the others: a category the interface *could not* emit is a
capability the release does **not** grant, and `G3.6b` must refuse against it. Without
it the manifest describes an intent rather than a release.

**The manifest must model the EFFECTIVE capability set, not parse interface lines.**
Retaining a class grants its implicit public constructor — `_Dead()` was constructed
with **no constructor entry anywhere in the interface text**. A manifest built by reading
the YAML would miss exactly the capability that was hardest to discover. So it is emitted
by the generator, which knows what it granted, rather than derived afterwards by a reader
that can only see what was written down.

#### ⛔ PRECOMMITTED DECISION DIMENSIONS — recorded 2026-08-12, before the tooling exists

Written before any arm can produce a number, so the criterion cannot be chosen to fit
the winner. **All four are reported for every arm, and none of them is the criterion on
its own:**

| | dimension | why it cannot be dropped |
|---|---|---|
| 1 | **patchability gained** | the point of the exercise. A cheap arm that unlocks nothing is not a win |
| 2 | **binary cost** | interface / snapshot / App deltas, per shape |
| 3 | **capability breadth** | what future patches can reach — a compatibility and support fact under the settled threat model, not a security one |
| 4 | **skipped/refused coverage** | what the arm *could not* grant. An arm that grants little because it silently failed is not the same as one that grants little by design |

**Do not let "smallest binary" or "largest reach" become the criterion after the fact.**
Either is defensible as a *decision*; neither is defensible as a criterion discovered
once the numbers are visible. This is the precommitment rule applied before the fact
rather than after — its two prior saves (§the precommitment rule) were both retrospective
rescues of a favourable-looking result, and this is the cheaper version.

#### ✅ POLICY DECIDED 2026-08-12 — **P2**

> **P2: retain and permit app-private members, and the private classes required to make
> those members patch-targetable.**
>
> **The concrete capability manifest remains authoritative** — the policy names the
> intent; the manifest records what a given release actually granted.

**Why, in one comparison.** P3's collapse removed the middle, so the real choice was:

| policy | private-instance reach | Wonderous cost |
|---|---|---|
| **P1** | ❌ no | +6.17 % |
| **P2** | ✅ **yes** | +7.83 % |

**≈224 KB / +1.66 pp** for the capability that addresses the **top measured blocker**:
Phase 0 found private app members blocking **9 of 10** real patches, and
`StatefulWidget`-style private classes are a large part of that shape. Under the settled
threat model — patch authority is release-equivalent for Dart application authority — that
is a compatibility trade-off worth taking, not a privilege question.

**What `G3.6b` must therefore do.** Not "private is allowed". Accept a private target or
reference **only when the release's emitted capability set proves all three**:

| | condition |
|---|---|
| 1 | the **member** was emitted |
| 2 | the required **enclosing class capability** exists — the condition P3's collapse proved is load-bearing, and the one a naive "private is allowed" rule would miss |
| 3 | the capability is **not** in that release's skipped set, and not in the unconditional must-refuse set |

The six `_enumToString` cases remain **unconditional refusals** under P2 as under every
policy.

#### 🔻 P3 IS NON-VIABLE — not merely unselected

> **P3 names private instance members but cannot attach patches to methods of their
> private enclosing classes; therefore its added member grants are operationally inert for
> the intended use case.**

Recorded this way deliberately. Its +6.78 % sits between P1 and P2 in the cost table, so a
reader looking only at that number could rediscover P3 as an "optimization" — buying most
of the reach for less. **It buys none of the reach.** The number is real and the capability
behind it is not.

#### 📊 ARM RESULTS — Wonderous, 2026-08-12. All three build; no vacuity.

`probes/policy_arms.sh`, one pinned app state (`747b945a`), prepass and import kernel
built once so the only per-arm difference is `--policy`. Baseline is the same app with
**no** retention: 13,526,688 bytes. All three interface digests differ, so every delta
prices a real difference.

**Table 1 — cost**

| arm | interface | snapshot | vs baseline |
|---|---|---|---|
| **P1** top-level + static | 15,817 | 14,361,952 | **+6.17 %** |
| ~~**P3** members, no classes~~ | 63,342 | 14,444,232 | ~~+6.78 %~~ — **NON-VIABLE: buys none of the reach** |
| **P2** everything | 76,336 | 14,586,296 | **+7.83 %** |

**Table 2 — authority expansion**

| arm | top | static | instance | classes | implicit ctor | refused |
|---|---|---|---|---|---|---|
| **P1** | 27 | 26 | 0 | 0 | 0 | **346** |
| **P3** | 27 | 26 | **340** | **0** | **0** | 6 |
| **P2** | 27 | 26 | 340 | **119** | **119** | 6 |

**The marginal split is the result, not the totals:**

| step | cost | buys |
|---|---|---|
| P1 → P3 | **+82,280 bytes** | 340 private instance members |
| P3 → P2 | **+142,064 bytes** | 119 private classes + their 119 implicit constructors |

**Constructibility costs nearly twice what all 340 member grants cost.** The 119 class
retentions are the expensive half of P2, and they are the half with no obvious patch use
case — `_WondersAppState.new`, `_AppLocalizationsDelegate.new`, `_Text.new`. Meanwhile the
members P3 grants are exactly the Phase 0 shape: `_WondersAppState#_imagesCached`,
`ArtifactAPIService#_parseArtifactData`.

**P3's structural hypothesis holds:** withholding the `class:` item withheld
constructibility *and* implicit constructors while keeping all 340 members named.

**The universally-refused set is 6 entries and every one is `_enumToString`** — the
CFE-synthesised enum machinery whose `Name` belongs to `dart:core`. No policy can grant
them, no patch author writes them, and `G3.6b` must refuse them regardless of policy.
That is a reassuring shape for a must-refuse set: one known cause, no app-authored code.

> **⚠️ NOT YET VERIFIED, and it is P3's load-bearing assumption.** The 340 members are
> *named*, and `dead_body.sh` established that naming makes a member a root. But whether
> a patch can **use** an instance member whose class carries no `class:` item is an
> inference, not a measurement. In the real shape the receiver arrives from the lowering
> (`self`), not from construction — so P3 should work for patching a method *on* that
> class. **That needs an arm before P3 can be chosen.** If it fails, P3 collapses into P1
> and the middle ground does not exist.

#### ⛔ PRECOMMITTED — the P3 usability arm, written before it runs

The probe uses the real product shape: a private class the **app** allocates, a public
method patched, and the private member reached through the receiver the lowering supplies.

```dart
class _Thing {
  String _secret() => 'NEW';
  String value()   => 'OLD';   // the patch target
}
// patched to:  String value(dynamic self) => self._secret();
```

Under `--policy p3`: `_secret` **is** named, `_Thing` has **no `class:` item**, the patch
**does not construct** `_Thing`, and the receiver arrives from the app's own instance call.
Expected result `NEW`.

| outcome | what it means for the choice |
|---|---|
| **passes** | P3 is a real middle ground, and on the measured numbers the **strongest default candidate** |
| **fails, because class capability is required** | P3 **collapses toward P1** — and P2 becomes the only policy that buys the private-instance reach Phase 0 showed is needed |
| **fails for an unrelated mechanism** | **do not choose any policy** until the failure is classified. A collapse and a bug are different findings |

**Why this single probe decides it.** The measurements already say P1 → P3 buys the
capability shape users actually need for **+82 KB**, while P3 → P2 spends a further
**+142 KB** primarily on constructibility with no demonstrated demand. So the choice turns
on one question — whether P3's reach is real — and not on another broad measurement.

**Note the second thing this arm tests, which the manifest cannot show.** The patch target
is a *public method of a private class*. Under P3 that class has no `class:` item, and a
`library:` item covers only public classes — so whether the patch can **attach** at all is
in question independently of whether `self._secret()` binds. A failure here is a *class
capability required* result even though `_secret` itself was granted.

#### 🔻 P3 COLLAPSES — measured 2026-08-12. Its granted members are INERT.

`probes/p3_usability.sh`, a matched pair on one fixture differing **only** in policy:

| policy | `_secret` named | bare `_Thing` class item | result |
|---|---|---|---|
| **P3** | ✅ | 0 | `APPLY refused: target _Thing.value did not attach` → `OLD` |
| **P2** | ✅ | 1 | `APPLY ok` → **`NEW`** |

**It fails at ATTACH, not at bind, and that distinction is the finding.** The replacement
**compiled clean** — a 0-byte compile log — so `self._secret()` resolved perfectly well
against the granted member. The patch never got as far as calling it: the target is a
*public method of a private class*, and with no `class:` item that class is not retained,
so `ResolvePatchTarget` cannot find `_Thing.value`.

**So P3's 340 member grants are not wrong, they are inert.** Reaching any of them requires
attaching to some method of their enclosing class, and that requires the class item P3
withholds. The +82 KB P1 → P3 buys **nothing usable on its own**.

**The precommitted second branch therefore applies:** P3 collapses toward P1, and **P2 is
the only policy that buys the private-instance reach Phase 0 showed is needed.** The real
choice is P1 vs P2 — the middle ground does not exist, and it took a probe rather than a
manifest to find that out, because the manifest could only say the members were *named*.

That also revises the cost framing. It is not "+82 KB for the useful part, +142 KB for the
rest" — it is **+224 KB (P1 → P2, +6.17 % → +7.83 %) for reach that is unusable without
class retention.** Constructibility is not a separable line item; it arrives with the class
capability that attachment requires.

**One assertion bug found and fixed in the probe itself.** The precondition check counted
`class: '_Thing'` with grep, which also matches the `class:` line *inside* a member entry —
so it reported P3 as granting a class item when P3 grants none. A bare class item is a
`class:` line with no `member:` after it. Had that not been asserted at all, the probe would
have produced the same verdict for an unverified reason.

#### The six `_enumToString` entries are an unconditional must-refuse

Pinned now so they cannot later make policy coverage look incomplete. They are
CFE-synthesised enum machinery whose `Name` belongs to `dart:core`, unresolvable by
`LibraryIndex` under **every** policy, and written by no patch author. `G3.6b`'s contract
refuses them **unconditionally** rather than treating them as a coverage gap a future
policy might close — no policy can close them, and counting them against a policy would
understate every arm equally.

**No policy is chosen here.** All four precommitted dimensions are reported; the choice
is step 8 and it is deliberately a separate act from the measurement.

#### ✅ THREAT MODEL — DECIDED 2026-08-12

> **Within the Dart capabilities of the already-released application, patch-publishing
> authority is release-equivalent.**

**The reasoning.** A patch publisher can already replace executable application logic.
If that principal is malicious or compromised, denying it access to `_privateHelper`
protects neither the app's data nor its integrity — it can ship different logic
*around* the private member. Treating Dart library privacy as a security boundary
would therefore add real complexity while providing no real boundary.

**The qualification, which is the load-bearing half.** Patch authority is *not*
literally equivalent to publishing a new App Store binary. It cannot inherently change:

* native code;
* entitlements;
* signing identities;
* OS permissions;
* bundled frameworks.

So the rule is scoped precisely — **release-equivalent for *Dart application*
authority**, not release-equivalent in general. Anyone applying it outside that scope is
misapplying it.

**Consequences, and they resolve the P1/P2/P3 question's frame:**

* private reach is a **compatibility / patchability / maintenance** decision, not a
  security one;
* broad private retention is **not** a privilege escalation under this model, so **P2 is
  a legitimate default candidate** — it should not be rejected in advance in favour
  of P1 out of security caution;
* **capability manifests remain mandatory.** Their purpose changes rather than
  disappears: they document what future patches can actually *reach*, which is a
  compatibility and support fact even when it is not a security fact;
* **constructibility and the skipped/refused sets still matter**, because `G3.6b` must
  consume the concrete release contract — what a release *did* retain, not what the
  policy promised.

> #### ⚠️ REVISIT CONDITION — this decision expires on a product change
>
> **If the product introduces delegated or lower-trust patch publishers — principals
> intentionally less trusted than release publishers — this decision no longer holds.**
>
> At that point:
>
> * retention and permission must **split** (see the coupling note in §3, which is
>   deliberately unsplit *because of* this decision);
> * the dynamic interface becomes a real **allowlist / security boundary**;
> * P2 stops being a default and broad private retention becomes a privilege question
>   again.
>
> Recorded here rather than assumed, because the decision is correct *for the system
> being built today* and silently wrong for a plausible future one. A reader who finds
> "patch authority is release-equivalent" without this condition attached will apply it
> to a product it was never argued for.

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

**The condition for splitting them is now precise, not a vague "if they diverge".**
The threat-model decision above is what keeps them coupled: while patch authority is
release-equivalent for Dart, "what the release retains" and "what a patch may reach"
*should* be one document, because there is no principal for whom the second needs to be
narrower than the first.

**Split them when a lower-trust patch publisher exists** — a principal deliberately less
trusted than the release publisher. That is the revisit condition on the threat-model
decision, and it is the same event: at that point retention specification and patch
allowlist become separate documents, and the interface becomes a security boundary
rather than a capability record.

Recorded here so a future reader finds a decision with an expiry, rather than an
accident that outlived its argument.

#### `G3.6b` — BUILT 2026-08-12. And the flag turned out to be wider than the gate.

The contract above is implemented in `route_b_capabilities.dart`, and the split it
required is between the two things that cannot see each other:

* the **analyzer** ships in a cell resolved by the release's engine hash, so it cannot
  know what one release granted. It now REPORTS a private access carrying the manifest
  key the release would have had to grant (`analysisVersion` 6 → 7), where v6 refused
  outright;
* the **CLI** holds the release's hash-verified capability manifest, so the accept /
  refuse decision lives there.

The key comes from the **interface target**, not from the class being patched.
`this._controller` may resolve to a declaration on a superclass in the same library,
and the manifest keys a member under the class that declares it — so keying on the
patched class would refuse a member that was in fact granted. A private member whose
key cannot be resolved is **refused, not reported**: an access with no key is
indistinguishable from a public one downstream, which is the one direction where the
mistake is silent.

**THE FINDING THIS GOAL DID NOT EXPECT.**
`--resolve-private-names-in-library` is **per-compile, not per-access.** Every design
sentence before this point assumed the gate and the mechanism had the same shape: gate
an access, unlock that access. They do not. Turning the flag on makes *every* private
name in the replacement resolvable — a private type in the signature, a private
top-level function, a private static, a private local — none of which the capability
check ever looked at. Each would compile and then bind to nothing on a device.

So the producer also scans the emitted declaration and refuses any private identifier
that is not one of the granted accesses. Two calibrations, both asserted by test
because both directions are failures:

* a private name in a **comment** is not a reference — refusing `/// Reads
  [_controller].` would make the safe path punish the documented patch;
* a private name inside an **interpolation** IS a reference — `'${_other}'` is a real
  reference wearing a string's clothes, so a string is dropped only when it cannot
  interpolate.

The flag is passed **only** for a target that actually carries a granted private
access, so every shape already proven on device compiles under exactly the arguments
it did before — and a cell that predates the flag keeps working for those targets.

**Evidence.** `probes/cli_private_member.sh`, 10/10, one release and three manifests
so a refusal can never be blamed on a differently-retained release:

| arm | manifest | outcome |
|---|---|---|
| `granted` | member **and** class | the app reads `NEW-PRIV`; the compile is shown to carry `--resolve-private-names-in-library <target library>` |
| `class_withheld` | member, class removed | **refused in the CLI**, naming the enclosing class it did not retain — P3's shape, where the grant is real and inert |
| `no_manifest` | none | **refused in the CLI**, naming the absent evidence |

The flag assertion reads the printed argument list rather than inferring from the
value, because `self._secret` on a `dynamic` receiver compiles either way: the value
alone cannot distinguish "the flag worked" from "something else did".

**Published as cell `ee001fd78fcd5e78e976d35284bd13e1caffff63`** (donor `50d58cc3`;
engine binary cloned byte-for-byte, so only the cell differs). Three files moved in one
address change, which is the point of having waited: `route_b_analyze.aot` v6→v7,
`route_b_gen_dynamic_interface.aot` for `--policy`/`--manifest`, `dart2bytecode.aot` for
`--resolve-private-names-in-library`. Minting them separately would have produced two
addresses neither of which worked — the CLI pins the analyzer version, so a cell with the
new analyzer and the old compiler is refused, and the reverse compiles a private
reference nothing gated.

The host path then ran **again, against the published zip**: 10/10. The staged run proved
the bytes; this proves the publication, and they are not the same claim — a bundle can be
assembled correctly and filed under the wrong hash, which is exactly what
`PROVENANCE.txt`'s engine-revision check exists to catch.

#### The device gate RAN, and it found a delivery-path bug — 2026-08-12

`23.0.0+1` on the iPhone 7, patch 1 published at 591 B. The result is **not** a
pass, and the way it failed is worth more than a pass would have been.

| step | outcome |
|---|---|
| release cut with the new engine | ✅ policy `p2`, private enumeration from the non-AOT kernel, agreement **passed**, `RouteBThing#_secret` granted, manifest provenance-covered |
| producer accepts against the P2 manifest | ✅ emitted `String value(RouteBThing self) => self._secret;` — public class keeps its concrete type, private field reached through the receiver |
| patch published | ✅ 591 B, one target |
| device downloads it | ✅ `__patch_download__`, patch 1 |
| device applies it | ✅ app reports **code patch: 1** |
| the patched body executes | ❌ **route B value still `NEW-SET`** — the release's own body |

**The discriminator, run rather than reasoned.** The identical shape — public
class, private field, typed receiver — was replayed on host against the same
published cell: `APPLY ok`, value `NEW-PRIV`, byte-identical lowering. So the
producer, the manifest gate, the CFE resolution and bytecode binding are all
sound. The divergence is in the delivery path, not in G3.6b.

> **CORRECTION, 2026-08-12, in place per the correction rule.** The paragraph
> below attributed the non-applying patch to the engine-identity mismatch. **That
> attribution was wrong.** Patch 2 was built with `engine.version` holding
> `ee001fd7` for the whole command — both identity gates passed, the mismatch was
> gone — and the device still reported `code patch: 2` with the value unchanged at
> `NEW-SET`. So the mismatch was real, and refusing it is right on its own terms,
> but it was **not** the cause of the patch not applying.
>
> What the mismatch was: an incompatibility that had to be closed before anything
> else could be trusted, and it is now a hard refusal (`9440d56a`). What remains:
> the device does not apply a private-member patch even with matching identity,
> while the identical shape passes on host against the same published cell. That
> is still open, and it needs engine-side visibility into the attach/bind — not
> another inference. `strings` over a kernel binary was tried and is not a
> trustworthy instrument for it; two of its counts contradicted each other, so
> nothing was concluded from it.
>
> **SECOND CORRECTION, same day, from the matched control the user asked for.**
> The paragraph above says the remaining difference is the private-bearing
> bytecode. It is not. Patch A (`value() => 'NEW-CTL'`, no private reference) on
> the same release, target and cell, with engine identity pinned for the whole
> command, **also installed and did not apply** — `code patch: 3`, value still
> `NEW-SET`. The premise of the control was "if A applies and B does not, the
> private path is the difference"; A did not apply, so the fault is common to both
> and sits upstream of anything private.
>
> Also controlled away, by measurement rather than argument: the container records
> `release.buildId` `2d497ada…`, which IS the installed app's `LC_UUID`, and its
> selector is `RouteBThing.value`. Delivery, release identity and targeting are
> therefore correct, and `code patch: N` only ever proved lifecycle promotion.
>
> The open question is now exactly four states and nothing wider: target not
> found / bytecode rejected / attach claims success but the target stays AOT /
> attach is real and execution fails later. None is distinguishable from outside
> the engine, which is why the next step is the per-target diagnostic and not
> another fix.
>
> **THIRD CORRECTION, and the last one: no engine instrumentation was needed.**
> The `.routeb` diagnostic already exists on device and already answered it. Pulled
> off the phone with `ios-deploy --download`, `patches/3/dlc.vmcode.routeb` reads:
>
>     hook entered
>     parsed, targets=1, built-for=2d497adaa2713a2f9aa5da618125f077
>     running=2d497adaa2713a2f9aa5da618125f077
>     applied 1/1 targets, entering main
>
> Hook entered, container parsed, build IDs equal, attach reported success. So the
> state was "attach succeeds and the target is never reached" — and the reason is
> that **the release was cut without `--patchable_static_calls`**.
> `verify_patchable_release.sh` reports **8 patchable sites, 2 per MB** against a
> 100/MB threshold, and its own failure text is the symptom we spent the day
> chasing, written down before we hit it: *"a Route B patch will attach
> successfully and change nothing: AOT emitted direct calls that never consult
> `Function.entry_point_`."*
>
> The measurement is on the PATCH build's archive, because later builds overwrote
> the release's — a labelled proxy, not the release bytes. It is corroborated by
> two independent facts: the release command carried no
> `--extra-gen-snapshot-options=--patchable_static_calls`, and `_verifyPatchableRelease`
> only runs when patchable calls were REQUESTED, so a release cut without the flag
> is silent about it.
>
> **The lesson is procedural, not technical.** `assert_installed_release.sh` exists
> and is documented as mandatory before interpreting ANY device result; a
> patchability check on the release is the same class of gate and was skipped. Four
> device runs and three wrong causal attributions were spent on a precondition that
> one existing script answers in two seconds.
>
> **FOURTH CORRECTION — patchability was a defect, not the cause.** Release 24 was
> cut with `--patchable_static_calls` and measures **7,141 sites / 1,775 per MB**
> against the broken release's 8 / 2. Identity was verified in both directions
> before the device was touched. Patch B then published, downloaded, reported
> `code patch: 1`, and its trace reads `applied 1/1 targets` — with the value still
> `NEW-SET`.
>
> The fix was necessary and insufficient. Four attributions have now been
> overturned by measurement: engine identity, the private path, and release
> patchability were each real problems that were each not this one.
>
> **What is left is exactly the gap the existing trace cannot close.** It records
> `applied 1/1 targets` and stops. It does not record whether the Function has
> bytecode afterwards, the entry point before vs after, or whether that entry point
> is the interpreted dispatch path. `AttachBytecode` returning success is not
> evidence that the active entry point changed, and every remaining hypothesis
> lives in that one unobserved transition.
>
> **THE CONTROL, RERUN UNDER VALID PRECONDITIONS, DECIDES THE BRANCH.** Patch A on
> release 23 was confounded by the missing `--patchable_static_calls`, so it could
> not distinguish "common fault" from "private-payload fault". Rerun on release 24
> — same target, same cell, 7,141 patchable sites, identity verified — it fails
> exactly as the private one does: `applied 1/1 targets`, value `NEW-SET`,
> `code patch: 2`.
>
> Two bodies, one with no private symbol anywhere, identical outcome. **The fault
> is common to all replacements on this release.** That closes off the
> private-bearing module/load/bind path as the suspect and selects the other
> branch: instrument the generic post-attach Function transition — does the
> Function have bytecode, what was the entry point before and after, and does the
> after value correspond to the interpreted dispatch path.
>
> Also recorded: the engine-identity gate fired again mid-sequence, on its own,
> when the stamp drifted to `69f9831c` between two patch commands. Third
> observation of that drift, and the first where the refusal saved a run that
> would otherwise have produced another uninterpretable result.

> **FIFTH CORRECTION, 2026-08-13 — the cause, and it was in the RELEASE's own
> bytes the whole time.** Everything above this line is a correct account of
> dispatch and a wrong account of what the fixture was able to show. **The call
> site does not read what the call returns.**
>
> Preserved release 30, disassembled at the exact pool offset the trace was given:
>
>     dda80: add  x0, x27, #0xd, lsl #12   ; PP + 0xd000
>     dda84: ldr  x0, [x0, #0x4a8]         ; pool[0xd4a8] = the patched Function
>     dda88: ldur x30, [x0, #0xf]          ; unchecked_entry_point_, read fresh
>     dda8c: blr  x30                      ; the call RUNS — dispatch is real
>     dda90: add  x0, x27, #0xd, lsl #12
>     dda94: ldr  x0, [x0, #0x488]         ; x0 OVERWRITTEN with a pool constant
>     dda98: ret                           ; and THAT is what the app displays
>
> `pool[0xd488]` is the constant the release's own `value()` body stores into
> `slot` — visible at `0xddca8`: load `pool[0xd488]`, `stur x0, [x1, #0xf]`
> (`slot`, per the field cluster at `0xdda54-74`), return. So the displayed
> `NEW-SET` is the release's own constant, materialised in the CALLER. `NEW-CTL`
> does not occur anywhere in the release binary; the value was never stale patch
> state.
>
> **Why.** The release body was `String value() => slot = 'NEW-SET';`. Its result
> is a single compile-time constant, so the type-flow analysis substituted that
> constant at the call site. The call is still emitted and still runs; only its
> RESULT is dead. `vm:never-inline` does not prevent this — it stops the body
> being spliced into the caller, not the result being replaced.
>
> **This is the second occurrence, not the first.**
> `selfhost/engine/killgate/target.dart` recorded it on 2026-08-09 in these
> words: *"the call was still emitted and still ran — its RESULT was simply no
> longer used, which is visible in the disassembly as a `blr` whose r0 nobody
> reads."* The fixture's own comments repeat the warning three times. It recurred
> on 2026-08-11 (`fa40f6ca`) when the release form became `=> slot = 'NEW-SET'`.
>
> **Scope of the measurement, so nobody has to take this on faith.**
>
> | evidence | result |
> |---|---|
> | preserved releases 25, 26, 27, 28, 29, 30 | the same fold, one located site each, at the same address |
> | pool offset, re-derived per release from its own bytes | `0xd4a8` every time — the hazard flagged in `fb70b5bb` is closed by measurement, not by trust |
> | the second site loading `pool[0xd4a8]` (`0xddcf0`, checked entry) | CONSUMED — a forwarder, not on the fixture's path |
> | host counterfactual, three arms | `slot = 'NEW-SET'` folds; `'NEW-SET'` folds; `DateTime.now()… ? … : 'X'` does not |
>
> **And it explains the last unexplained asymmetry.** "Identical shape passes on
> host" was true and was never a delivery-path clue: `probes/lowered_forms.sh`
> builds its release ONCE with `? 'OLD-c' : 'X'` and only restages the patch
> source per arm, so the host caller has always consumed the result. Host and
> device differed in the RELEASE body, which is the only body that decides this.
>
> **What this does NOT settle.** Whether the post-attach call reaches
> `InterpretCall` is still unmeasured. The fold made the UI blind: downstream of
> it, "the interpreter never ran" and "the interpreter ran and its answer was
> discarded" produce identical screens. So five attributions have now been
> overturned by measurement, and the sixth is not yet an attribution — it is a
> reason the previous six device runs cannot speak to dispatch at all.
>
> **Landed with it, because a comment already failed three times:**
> `probes/assert_result_consumed.sh` — reads the shipped bytes, locates the site
> by symbol / pool offset / fixture signature, and reports CONSUMED, DISCARDED or
> UNDECIDED, with "not located" as its own exit code. It carries a `--selftest`
> that builds the three host arms and asserts the detector separates them, and
> its first draft's over-matching locator (77 sites per release) is written up in
> the script as the failure it would have caused. The fixture's release body is
> now the `DateTime.now()`-routed form returning `'OLD-rel'`, whose dead branch
> also restores `helper`/`tagged` retention that the 2026-08-11 edit had dropped;
> both verified through the host toolchain (CONSUMED, and both methods present in
> the snapshot).
>
> **Per the classification rule, this was a KNOWN GAP, not an open question.** The
> answer sat in `evidence/releases/25/App` from the moment it was preserved. Four
> device runs, one engine instrumentation design and five causal attributions were
> spent on a fact that `llvm-objdump` prints in four seconds.

#### The next session's task, bounded — 2026-08-12 handoff

> **SUPERSEDED 2026-08-13 by the FIFTH CORRECTION above.** The post-attach trace
> this section specifies (schema v5, the four-state execution marker) is no longer
> the next step, and building it first would have measured dispatch through a UI
> that could not report the answer. Its FIXED CONSTRAINTS below remain correct and
> apply unchanged **if** the rerun described here still shows the release value.
> Do not start the engine work before that rerun: the rerun needs no engine
> change, no cell mint and no host rebuild.
>
> **The rerun, and its outcomes precommitted per the precommitment rule.** Cut
> release 31 from the fixed fixture on the engine already published
> (`881e4129`), gate it with `verify_patchable_release.sh` AND
> `assert_result_consumed.sh` AND `assert_installed_release.sh`, then publish the
> single public control patch.
>
> | observation | meaning |
> |---|---|
> | app shows the patch's value | dispatch reaches the interpreter and executes the replacement. The whole chain is proven end to end; schema v5 was never needed, and `applied 1/1` finally means what it appeared to mean. |
> | app shows `OLD-rel`, trace still `identity matches` | the fold was real and insufficient. NOW build the v5 execution marker under the constraints below — and it will be the first run whose UI can distinguish its two outcomes. |
> | app shows `OLD-rel`, gate said DISCARDED | the release was cut from a stale fixture. Not a result; re-cut. |
> | `assert_result_consumed.sh` reports UNDECIDED or NOT LOCATED | measurement incomplete. Fix the locator before the device is touched, exactly as `caller_scan_status` refuses to be read as a zero. |
>
> ##### Release 31 identity admissibility — precommitted, before the release exists
>
> > Release 31 pool-identity evidence is admissible only if the call-site pool
> > offset derived from preserved release-31 `App` bytes equals the engine
> > instrument's hardcoded `0xd4a8`. If it differs, or authoritative release bytes
> > were not preserved before patching, all pool identity fields and classifier
> > identity verdicts from release 31 are **NOT MEASURED**. The release-31 decision
> > remains offset-independent: `NEW-CTL` proves dispatch; `OLD-rel` with
> > `uep_post_is_interpret_call=1` authorizes v5.
>
> The fixture body changed, so codegen moved, so `0xd4a8` — measured from release
> 26 and hardcoded at `shorebird.cc:370` — is likely stale for release 31. A stale
> offset reads a different pool entry, and if that entry is a `Function` the
> classifier returns exit 1, IDENTITY MISMATCH: a false attribution manufactured
> by the instrument on the run meant to resolve one. Correcting the offset means a
> new engine hash and a new cell, which is precisely what release 31 exists to
> avoid — so the offset is not fixed, it is DECLARED INADMISSIBLE when it moves.
>
> **`probes/preserve_release_evidence.sh` must run at install time, BEFORE the
> first patch build.** Step 1 is destructible: the patch build re-archives over
> `build/ios/archive`, so after patch 1 the archive holds the patch build and what
> remains is a labelled proxy, not the release bytes (release 30's `RECORDED` says
> so, having paid for it). Without preservation the offset cannot be derived from
> authoritative bytes at all, and the pool fields are inadmissible by default.
>
> Object identity is NOT reopened by any of this: release 30 settled it on its own
> frozen bytes. Release 31 tests observable dispatch with a consumed result, and
> nothing else.

#### RELEASE 31 RAN, AND THE FIRST ROW FIRED — 2026-08-13

iPhone 7, iOS 15.8.8, engine `881e4129`, trace schema v4. Gates first: diagnostic
engine 3/3, the CLI's own `_verifyPatchableRelease` at 7,142 sites (the flag was
deliberately not passed by hand, because passing it *disables* that check),
`assert_result_consumed.sh` **CONSUMED** at derived offset `0xd4a0`, and
`assert_installed_release.sh` exit 0 at all five launches.

| | on screen | code patch |
|---|---|---|
| baseline | `OLD-rel` | none |
| patch 1 — `value() => 'NEW-CTL'` | **`NEW-CTL`** | 1 |
| patch 2 — `value() => _secret` | **`NEW-PRIV`** | 2 |

**The question this goal opened on is answered: the post-attach call executes and
reaches `InterpretCall`.** `bc_pre=0→1`, `interp_pre=0→1`, both `Function` entry
points moved to the same-run `InterpretCall` stub, and the replacement's return
value reached the UI. Established through the UI, not through a new instrument —
**the v5 execution marker was never built**, because its authorizing branch did not
fire. All three launches installed byte-identical bytes (`App` sha256 `573bb796…`,
`LC_UUID 49bfcd9b…`), so the binary that displayed `OLD-rel` is the binary that
displayed both patched values; the only variable was the patch.

**G3.6b is closed on hardware.** Patch 2 reads a private field the release never
reads, so P2 retention, the manifest grant, the producer's acceptance and the
CFE's private-name resolution all had to hold for it to execute.

**Nothing was ever broken except the observation channel.** Releases 23–30 spent
six device runs and five overturned attributions on a mechanism that already
worked. Both patches here succeeded on the first attempt, on the first release cut
after the fold was removed.

**The admissibility rule fired on first use, against a real false attribution.**
The classifier returns exit **1 — IDENTITY MISMATCH, "CAUSE FOUND"** for BOTH
patches, reading the engine's stale `0xd4a8`: index 6803 holds a *different*
`Function` in release 31, and it *is* a `Function`, so the classifier's own "two
positively identified Functions" safeguard was satisfied by a wrong input and could
not catch itself. Only the external rule knew the input was invalid. That is the
difference between a safeguard and a precondition, and it is why the rule is
external by design.

Evidence: `evidence/releases/31/{App,LC_UUID,RECORDED,patch1.*,patch2.*,verdict.txt}`,
screenshots `engine/route_b/evidence/r31_{1,2,3}_*.png`. Release 30 stays the
IDENTITY specimen; release 31 is the EXECUTION specimen.

`applied 1/1` is now precisely scoped: **`Dart_RouteBActivatePatch` returned
success**, and nothing more. The next experiment must establish what changed
inside the target `Function` after that return.

Where it lives, so nobody re-greps for it:
`flutter/shell/common/shorebird/shorebird.cc` — report path `:205`, first record
`:227`, the per-target `Dart_RouteBActivatePatch` call `:278`, the `applied`
counter `:282`, the final record `:304`. The counter increments on the call's
`int32_t` return, which is why the current trace cannot distinguish a real attach
from a returned-success one.

1. Extend the engine/VM boundary just enough to record post-attach `Function`
   state: bytecode attached before/after, `entry_point_` before/after,
   `unchecked_entry_point_` if it matters for this call form, the original AOT
   `Code` identity, whether the post-attach entry point IS the interpreted
   dispatch entry Route B expects, and the attach result itself.
2. Rebuild host + iOS engine. 3. Mint the new cell (`dartaotruntime` and
   `vm_platform.dill` both move, so the address changes). 4. Cut release 25 **with
   `--patchable_static_calls`**. 5. `preserve_release_evidence.sh` at install
   time. 6. Verify `LC_UUID` **and** patchability before interpreting anything.
7. Run ONLY the public `'NEW-CTL'` control — no private-name noise.
8. Classify into exactly one bucket:

| # | observation | meaning |
|---|---|---|
| 1 | no bytecode after attach | `AttachBytecode` did not persist the attachment |
| 2 | bytecode present, entry point unchanged | attachment exists, active dispatch stays AOT |
| 3 | entry point changed, but not to interpreter dispatch | wrong post-attach transition |
| 4 | bytecode + interpreted entry installed, app still OLD | the call site bypasses that `Function` despite patchability verifying — inspect the caller |
| 5 | interpreter entered | execution / body selection is the next layer |

**The freeze holds until that trace exists:** no changes to `G3.6b`, `P2`, the
lowering, retention, producer logic, or private handling. Four causal
attributions have already been overturned by measurement in this goal; the fifth
must come from observation.

##### FIXED CONSTRAINTS for the post-attach trace — decided, do not re-litigate

Settled 2026-08-12 after the recon corrected the design. These are not
suggestions and not open questions; the next session starts from them.

1. **No snapshot-hash-changing VM edits.** Never `runtime/vm/object.{cc,h}` and
   never `include/dart_api.h`. Verified below.
2. **Instrument in `runtime/lib/object.cc`** with a traced sibling API,
   preserving the existing 4-argument `Dart_RouteBActivatePatch` wrapper.
3. **Sample before/after around `RouteBSaveOriginalCode` / `AttachBytecode`**,
   including the comparison against `StubCode::InterpretCall().EntryPoint()`.
4. **VM fills a POD record; `shorebird.cc` writes it.**
5. **Persist to `<artifact>.routeb.trace`, NOT the existing `.routeb`.** This
   overrides the earlier "persist into the existing diagnostic" instruction, and
   the reason is the safety of the evidence already collected: `.routeb` carries
   byte-for-byte committed evidence
   (`selfhost/engine/route_b/evidence/4b_m1_activation.routeb.txt`) and ABSENCE
   SEMANTICS that other probes read ("no file means never armed"). Appending to it
   would put the new diagnostic in tension with both.
6. **Export `RouteBReport` plus the new trace as patch `0006` BEFORE treating the
   engine build as reproducible.** Today the mechanism behind every piece of
   device evidence in this goal exists only in one working tree.
7. **Then the full clean chain, in a fresh session:** rebuild host + iOS → mint
   the cell → audit it → cut release 25 with `--patchable_static_calls` →
   `preserve_release_evidence.sh` at install time → verify identity AND
   patchability → run ONLY the public `'NEW-CTL'` control → classify.

**Why constraint 1 is the load-bearing one.** The obvious reading of "extend the
VM API with richer return data" is to edit `vm/object.h` and `dart_api.h`. That
changes `SNAPSHOT_HASH`, the already-published `App.framework` stops loading, and
the result presents as a NEW device failure on the very run meant to explain one.
The instrumentation would have manufactured a fifth false cause. Four have already
been retired by measurement in this goal; the trap was that the fifth would have
looked like data.

##### The recon findings behind those constraints

Reported by the activation-path recon. **Constraint 1 is now VERIFIED by hand**
(`make_version.py:20-36` lists `object.cc` and `object.h` in `VM_SNAPSHOT_FILES`,
and `lib/object.cc` is NOT in that list, so the bracket target is safe).
Constraint 2 is still only reported — check it before relying on it.

**1. Do not edit `runtime/vm/object.{cc,h}` or `include/dart_api.h`.**
`vm/object.cc` and `vm/object.h` ARE listed in `VM_SNAPSHOT_FILES`
(`third_party/dart/tools/make_version.py:20-36`, confirmed by reading it), so
touching them changes
`SNAPSHOT_HASH` — and the **already-published `App.framework` snapshot then stops
loading** with "Wrong full snapshot version". That would silently convert a
diagnostic change into a forced full release cycle, and it would look like a new
device failure. `dart_api.h` is a separate cost: it is included everywhere, so
editing it turns a two-file rebuild into a whole-runtime rebuild.

So `AttachBytecode` itself is not instrumented. It is **bracketed** from
`runtime/lib/object.cc`, which is not a snapshot file: add
`Dart_RouteBActivatePatchTraced(..., Dart_RouteBTrace*)` beside the existing
export and keep a 4-argument `Dart_RouteBActivatePatch` wrapper that delegates
with `nullptr`, so `dart_api.h` and its declared contract are untouched. The VM
fills a POD struct; the EMBEDDER does the file I/O — the same division
`lib/object.cc:951` already documents, and it avoids `fopen` while holding
`program_lock` as a writer.

Anchors in `runtime/lib/object.cc`: `ResolvePatchTarget` `:705` (3 callers at
`:802`, `:908`, `:993` — give the trace param a default so they keep compiling),
the export `:952`, `LoadBytecode()` `:988`, the `AlreadyInterpreted` early return
`:1003`, and `RouteBSaveOriginalCode` / the attach at `:1017-1018` — which is
where before/after must be sampled. `StubCode::InterpretCall().EntryPoint()` is
the value to compare the post-attach entry point against, and `StubCode` is
already in that translation unit.

**2. `RouteBReport` IS NOT IN ANY REPO PATCH.** Patch `0003` reportedly still
carries only the `FML_LOG` hook, so the `.routeb` mechanism that produced every
piece of device evidence in this goal exists **only** in the working tree at
`/Volumes/build/route-b`. It is one `rm -rf` from gone, and a fresh checkout would
not have it. Export the current hook AND the new trace as
`selfhost/engine/route_b/0006-route-b-activation-trace.patch` — treat this as
part of the change, not cleanup afterwards.

Also worth fixing while there: the per-target record is emitted only on the
failure paths, so a SUCCEEDING target contributes nothing but the `applied N/N`
tally. Write the new trace line for every target, success included — that gap is
why `applied 1/1` was the whole story. Write to a SEPARATE
`<artifact>.routeb.trace` and leave the existing `.routeb` lines byte-for-byte
alone: `selfhost/engine/route_b/evidence/4b_m1_activation.routeb.txt` is committed
against them, and "no file means never armed" is a convention other probes rely
on. Run the cheap discriminators FIRST,
> in the order the runbook already specifies.

**The cause: the build silently rewrote the engine stamp.** `shorebird patch`
warned that the release was built by `ee001fd7` while the machine was "set up
with" `69f9831c`, and afterwards:

    bin/internal/engine.version   ee001fd7 -> 69f9831c
    bin/cache/engine.stamp        ee001fd7 -> 69f9831c
    bin/cache/ios-sdk.stamp       ee001fd7 -> 69f9831c
    bin/cache/engine-dart-sdk.stamp   ee001fd7  (unchanged)

`FLUTTER_STORAGE_BASE_URL` points at the sealed CDN, where
`experimental_hashes.map` maps `ee001fd7 -> 69f9831c` so unmodified engine
artifacts resolve. Flutter's cache then records **the hash it actually
downloaded**. The map's whole purpose is that fallback, and the fallback is what
destroys the engine identity — so the release recorded `ee001fd7` (stamps still
correct at release time) while the patch's KERNEL came from a different
frontend. The bytecode was compiled by the release's cell, correctly, against a
kernel that did not match it; it bound to nothing, and the engine kept the
compiled body. Delivery reports success; behaviour is unchanged.

**This is the exact scenario `ios_patcher.dart` declined to gate on**, in a
comment that said so: *"if those disagree the bytecode may fail to bind, on
device, long after this command reported success. We have not yet demonstrated
that... Wiring the producer is what will settle whether this becomes an error."*
It is now demonstrated. **The warning should become a refusal**, and the stamp
rewrite should be detected rather than tolerated — a patch whose kernel comes
from a different engine than its release is not a patch, and it fails in the
one way this project is organised against: silently, on hardware.

Not fixed here, deliberately: it is a delivery-path change with its own
acceptance, and everything else is frozen until the phone gate closes.

#### Bookkeeping: v7 is not numerically comparable to Phase 0

Analyzer v7 changes what `unsupported` contains — private receiver accesses moved
out of it and became reported accesses. Phase 0's rows were recorded under v6 and
classified by v6's reason strings. **No before/after acceptance percentage may be
claimed across that boundary.** Phase 0 remains valid as historical and pilot
evidence of which shapes real patches use; it is not a baseline for measuring
G3.6b's effect. A v7 Baseline A, if one is wanted, has to be a fresh run over the
same corpus, reported as its own number.

**What is left, and it is not code.** The device round-trip. Also two environment
mutations deliberately NOT done here, because each belongs to whoever owns that
environment: the sealed CDN needs a reload for Caddy to pick up the new map entry, and no
Flutter checkout has been restamped to `ee001fd7`.

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

#### The device gate — outcomes precommitted BEFORE the run, 2026-08-13

Written before release 32 is cut, per the precommitment rule, so a
favourable-looking result cannot be banked without the reasoning moving.

**Preconditions established, not assumed.** No mint: the published cell for engine
`881e4129` already carries the `G3.6d` generator — `route_b_gen_dynamic_interface.aot`
contains both the `class: '` emission template and the distinctive
*"item, because both stop at public members"* literal from
`gen_dynamic_interface.dart`. `G3.6c` is CLI-side and in this tree. So this rides a
new RELEASE (the private class must exist in it), not a new engine.

**Target.** `_ProbeBodyState.privateClassValue()` in the airgap fixture — a method
on a **private class extending Flutter's `State`**, which is the shape that makes
privacy the measured blocker rather than an academic one. Non-foldable by the same
`DateTime.now()` rule as every other target, and its result is stored into state and
displayed, so the call's result is consumed.

**Prediction: this passes.** The pair is host-proven 4/4 with a negative control that
fails when the `class:` items are stripped, the cell carries the generator, and the
producer emits `dynamic self` for a private receiver class. Recorded so the result
scores against it.

| observation | meaning |
|---|---|
| the private-class value changes on device | `G3.6c`+`G3.6d` **PROVEN**: a method on a private class is patchable through the ordinary path. The Flutter `State` shape is addressable |
| baseline persists, `code patch: N` present, trace shows attach ok and `uep_post_is_interpret_call=1` | attach succeeded and the private class's member did not bind or execute. Inspect the `dynamic_interface.yaml` the RELEASE actually shipped for its `class:` item before touching anything else — host proof does not transfer to a differently-generated interface |
| the container refuses at attach and rolls back | the good failure mode the host control demonstrated: under-retained release, keeps running its own code. Read the release's interface, not the engine |
| the CLI refuses before publishing | the `G3.6c` producer/analyzer path rejected a private-class target. That is a producer result and NOT a device result; record the refusal text verbatim |
| `assert_result_consumed.sh --symbol` is DISCARDED or UNDECIDED for the new target | measurement invalid. Re-cut; no behavioural attribution from that release |

**The gate is run by symbol this time.** The release archive carries
`dSYMs/App.framework.dSYM` with Dart symbols, so the new target's call site is
located by name rather than by the fixture-shaped structural locator, which only
ever matched `routeBValue`.

##### RAN 2026-08-13 — PASSED, and the prediction held

Release `32.0.0+1`, iPhone 7 / iOS 15.8.8, engine `881e4129`, patch 1 at 781 B.

| | private class row | code patch |
|---|---|---|
| baseline | `OLD-pc` | none |
| patch 1 — `privateClassValue() => 'NEW-PC'` | **`NEW-PC`** | 1 |

**Both walls verified by their own artifacts, not by the host probe.** `G3.6c`:
the producer emitted `String privateClassValue(dynamic self) => 'NEW-PC';` —
`dynamic self`, without naming the private class. `G3.6d`: the interface THIS
RELEASE shipped carries `class: '_ProbeBodyState'`. Both preserved in
`evidence/releases/32/`. The host negative control had already shown the identical
lowering fails when the `class:` items are stripped, so the pair is a conjunction
rather than one feature counted twice.

**A specificity control nobody planned.** `route B value` stayed `OLD-rel` across
the same launches: one patch, one declared target, one changed value. The result is
"the named thing changed", not "something changed".

**The instrument reported NOT_REQUESTED and that was correct.** `pool_status=0` for
this target, because the embedder's hardcoded `0xd4a8` is keyed to
`RouteBThing.value`. Not-requested never became a zero — the contrast with release
31, where that same constant was applied to a moved call site and produced a false
IDENTITY MISMATCH, is the whole argument for keeping the two states apart.

**Three defects in the gate itself, found by using it and fixed in the same pass:**
a dSYM has the Dart symbols but no code, so `--symbol` against one reports NOT
LOCATED (now `--symbols PATH` resolves the name there and disassembles the real
binary); "worst verdict wins" across a caller's several call sites reported a fold
for an ordinary void `setState` (now multi-site is AMBIGUOUS, exit 2, with `--at
0xADDR` to name one); and that in turn showed the selftest had been passing partly
by accident, because `vm:entry-point` emitted a second `routeBValue` body.

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
| ✅ | **CLOSED 2026-08-14 — THE RUN HAPPENED AND THE RELEASE PUBLISHED.** A Route B iOS release of a real third-party app **builds**: Wonderous (`wonders` 2.2.7+236 at `747b945`) cut release **88** on `cps-ios`, `platform_statuses.ios = "active"`, consuming cell `40eaa0ef` per the shipped `route_b.json`. All three precommitted anti-false-green checks met on this run's own artifacts — `privateEnumerationSource: "import"` with `importPrepassAgreement: "passed"` and no fallback; **774** private references in the interface **including the exact member this row named, `ThrottledSaveLoadMixin` / `_file`**; and `engineRevision 40eaa0ef`. Mechanism confirmed as the one prescribed: `route_b_capabilities.json` records `private-dill (non-AOT)`, policy `p2`, 130 app libraries, 340 private instance callables. Surface: **17,736 patchable call sites, 1800/MiB** — ~2.5× the acceptance fixture at comparable density. ~~**Only the BUILD clause is answered: no patch was built and no device was involved, so nothing here says a patch to a real app works.**~~ — **THE PATCH ARM RAN 2026-08-14 and answers it, with a limit.** `SearchData.write()`, an **instance** method, patched and **published** against release 88 (patch id 57, ready, stable, 100 %, aarch64); the lowered body `String write(SearchData self) => 'WRITE-PATCHED'` shows the receiver threaded, 516 B bytecode / 828 B container. But `StringUtils.getYrSuffix`, a **static** method with 6 live call sites, was **REFUSED** — *"the bytecode compiler refused its replacement body (exit 254)"*, whole patch refused, nothing uploaded. **So the 17,736 figure overstates the patchable surface: a static method is among those call sites and is not patchable.** Stated with its limit — **n = 1 on each side**, the two bodies differing only in static-vs-instance, so this is a finding to widen rather than a rule. Still nothing about RUNTIME: built `--no-codesign`, never installed, so the patch has never been applied or executed. Evidence: `evidence/g4-wonderous/patch_verdict.txt`. The prior attempt failed at Xcode Target Integrity (app ships `IPHONEOS_DEPLOYMENT_TARGET` 13.0, four SPM plugins require 15.0) — precommitted as *not* a §4 result and recorded as such before being fixed; Route B had already completed on it with identical `interfaceBytes`, so the annotation result reproduces across two runs. Evidence: `evidence/g4-wonderous/{precommit,verdict}.txt`. Original row follows. ~~**KNOWN GAP — but this row is STALE about the remedy, corrected 2026-08-14.** A Route B iOS release of a **real third-party app** does not build: Wonderous fails its retention-interface annotation even at app-only breadth (`get:_file` for `ThrottledSaveLoadMixin`, where the annotator's component has `_file` bare). ~~Enumerating privates from the non-AOT kernel avoids it~~ — **that remedy LANDED at `cd453304`**, which builds an early import kernel as the private-enumeration source with a guard and a recorded contract. This row describes the tree before it. **The gap is NOT thereby closed and must not be marked so**: no real third-party app has been through a Route B release since, so what is owed is the RUN, not the design. Two things found while establishing that, both fixed: the import kernel was a **fourth** flavor call site that `25f8a3b8` missed (it threaded three), and it must spell the flavor the way the SHIPPED kernel does — `agreesWith()` compares it against the prepass, so a mismatched spelling falls back to prepass-only enumeration **silently**, which is the very narrowing that does not build on a real app. The decisive experiment is precommitted with the fallback trap named: read `retention.json` to confirm `enumerationSource == import` BEFORE banking a green build, **because the fallback also builds**~~ |
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
| ◐ | **BUILT 2026-08-13** Full `--dart-define` release → patch acceptance matrix — `G4.1`. The release records its configuration in provenance; the patch **refuses before any compilation** when the effective set differs. 21 matrix tests plus the threading test |
| ◐ | **BUILT 2026-08-14 — SUPPORTED, and the objection that kept it declined is answered rather than overridden.** `--dart-define-from-file` is now expanded into the effective define set, closing **two** nulls that were not equally visible: `fromBuildArgs` returned null (uncomparable, which the row below described), and `RouteBReleaseKernelBuilder.forwardedArgs` also returned null — **no prepass and no import kernel, so such a release could not be patched at all.** The recorded objection was that expanding the option means reimplementing Flutter's `.json`/`.env` parsing, i.e. hand-reconstruction. That objection is about TRUST, not about parsing, and it is answerable: **Flutter writes its own resolved answer to disk** — `ios/Flutter/Generated.xcconfig` carries `DART_DEFINES` as base64 `K=V` (`build_info.dart:396` via `ios/xcode_build_settings.dart:265`). So the port in `dart_define_from_file.dart` is CHECKED, twice: `probes/g41b_define_from_file.sh` **18/18** compares it against Flutter's own resolution per arm on `flavored_app`, and `ios_releaser._defineExpansionDisagreement` runs the same comparison on the user's real build, **declining exactly as before when the two disagree** (no Route B artifacts, `buildConfig: null`). A wrong expansion therefore costs patchability and can never produce a wrong patch. `flutter build ios --config-only` makes the probe cheap — the `configOnly` early return (`ios/mac.dart:375`) sits AFTER `updateGeneratedXcodeProperties` (`:347`). **TWO CONTROLS, both of which fired or would have:** arm 0 is an instrument control that caught a real misconfiguration on the first run (no `FLUTTER_STORAGE_BASE_URL` → the pinned Flutter asked `download.shorebird.dev` for `engine_stamp.json` at `40eaa0ef` and took a 404, which without arm 0 reads as six arms agreeing that nothing equals nothing); arm 5 SABOTAGES the file after Flutter has read it and requires the comparator to report the disagreement. **The four new unit tests were confirmed RED against a reverted implementation**, and the negative control (`a MISSING file still yields null`) stayed GREEN in both states — which is also the retraction: **the test that previously sat in that position was vacuous.** It asserted `fromBuildArgs(['--dart-define-from-file=x.env'])` is null while never creating `x.env`, so it read as "the option is declined" and actually tested "a missing file is declined", and it would have kept passing against a full revert. 2486 passed / 2 skipped / 0 failed; analyze and format clean. **Host only — earns BUILT, and no release has been cut with the option.** `evidence/g41-define-from-file/`. The before-state follows: |
| ☐ | ~~**KNOWN GAP** `--dart-define-from-file` causes Route B patchability to be *declined* rather than supported. `G4.1` keeps it a decline and now says which of two reasons applies: a release that predates configuration provenance is *not comparable*, and one built with this option *never can be* — neither collapses into "no defines"~~ — **SUPERSEDED by the row above.** Kept struck through rather than deleted: a reader who acted on "this option can never be fingerprinted" needs to know it changed, and the sentence *"one built with this option never can be"* is now false |
| 🐞 | **KNOWN GAP, measured 2026-08-14 while closing the row above — Flutter injects defines that Route B's kernels never receive.** The same `DART_DEFINES` line the expansion is checked against carries **`FLUTTER_VERSION`, `FLUTTER_CHANNEL`, `FLUTTER_GIT_URL`, `FLUTTER_FRAMEWORK_REVISION`, `FLUTTER_ENGINE_REVISION`, `FLUTTER_DART_VERSION`** (`flutter_command.dart` `_addFlutterVersionToDartDefines`, and `_addFeatureFlagsToDartDefines` for `kEnabledFeatureFlags`), while `RouteBReleaseKernelBuilder.forwardedArgs` forwards only `--dart-define=` and `--enable-experiment=`. **So the prepass and import kernels compile without them and the shipped kernel has them** — the same *different-program* class as the flavor-casing divergence `6ae04dc7`/`f06fa056` closed, with the key threading fixed and a whole family of keys still missing. Measured, not argued: the flavored fixture's `ios/Flutter/Generated.xcconfig:12` decodes to `FLUTTER_APP_FLAVOR=foo`, `FLUTTER_VERSION=3.44.8`, `FLUTTER_CHANNEL=[user-branch]`, `FLUTTER_GIT_URL=unknown source`, `FLUTTER_FRAMEWORK_REVISION=c15ef63794`, `FLUTTER_ENGINE_REVISION=11e5695710`, `FLUTTER_DART_VERSION=3.12.2`. **Scope, stated honestly:** it bites where a program branches on one of those values (`const String.fromEnvironment('FLUTTER_VERSION')`), which is rarer than branching on a flavor, and **it is not demonstrated to break any app** — what is demonstrated is that the two kernels disagree. **Its own lane**, and the decision it needs is not just "forward them": whether they also belong in the FINGERPRINT. A release and a patch on one pinned cell would always agree on them, so the cost is low and the reasoning must still be written down. `evidence/g41-define-from-file/DECLARES.md` |

### Flavors / schemes

| | item |
|---|---|
| ⛔ | **DEVICE GATE BLOCKED — the prerequisite is now PARTIAL, and the cause has moved.** It read *"prerequisite missing: a flavored iOS fixture"*, and the reason given — the airgap fixture has one Xcode scheme (`Runner`) and no flavor xcconfigs — remains true of `airgap_app` and is no longer the binding constraint: **`selfhost/fixtures/flavored_app` exists as of `41758dd3`**, and its overlay is structurally valid — `xcodebuild -list` resolves nine configurations (`Debug`/`Release`/`Profile` × plain, `-Foo`, `-Bar`) and schemes `Bar`/`Foo`/`Runner` (2026-08-13, scratch copy, shared fixture untouched). **That is BUILT for structural validity only** — a project-file query, not a build. What blocks the gate now is that **`prepare_flavored_fixture.sh` does not exist and not one host arm has run**, so nothing yet shows `FLUTTER_APP_FLAVOR` reaching the compiler. **No release may stand in as flavor evidence**, and no release may be cut against this fixture before step 7's arms are green. Same class as `G15`'s missing two-engine host: a prerequisite, not a failed gate. The host-side result below is unaffected and remains valid |
| ◐ | **BUILT 2026-08-13** the Route B half of flavors — `G4.2`. The predicted false green was CONFIRMED BY READING, not by a device run, and it is narrower than "flavors unsupported": *the shipped flavored release receives `FLUTTER_APP_FLAVOR`, while Route B's prepass and import kernel did not, so retention and binding could be computed against a different Dart program than the one that shipped.* Fixed by resolving the flavor Flutter's way (`--flavor`, else pubspec `default-flavor`) and threading `-DFLUTTER_APP_FLAVOR` into the prepass, the import kernel and the fingerprint. `probes/g42_flavor_flow.sh` **13/13** — and the `12/12` recorded here until 2026-08-13 was a PRE-FIX run. Measured on `dc732dbb` the probe reported **11/12**: `25f8a3b8` closed the kernel-forwarder gap and touched no probe, so row 4 went on asserting a bug that no longer existed. The row was INVERTED rather than deleted and split into two (kernel forwarder, and patch side), which is the 12→13 check count. Both runs kept in `evidence/g42_flavored_fixture/g42_flavor_flow.txt` |
| ☐ | **INHERITED** Android flavors |
| ☐ | **INHERITED** iOS flavors / schemes |
| ☐ | **NOT VALIDATED** Release + patch, same Android flavor |
| ☐ | **NOT VALIDATED** Release + patch, same iOS flavor |
| ☐ | **NOT VALIDATED** Wrong-flavor patch rejection |
| ✅ | ~~**KNOWN GAP** Route B never sees the flavor at all — `grep flavor` across `route_b*.dart` returns **zero** hits~~ — **CLOSED, and this row was stale before it was corrected.** That grep now returns **32 hits across two files** (`route_b_build_config.dart` 19, `route_b_release_kernels.dart` 13). Kept struck through rather than deleted: a reader who acted on "Route B never sees the flavor" needs to know it changed |
| ◐ | **BUILT 2026-08-13** the PATCH half of flavors, which was still open after the release half. `--flavor` never arrives through `forwardedArgs` (only `--dart-define=` and `--enable-experiment=` are forwarded) and the CLI passes flavor to `buildIpa` separately, so `_verifyBuildConfigAgrees` synthesised **no** `FLUTTER_APP_FLAVOR` for the patch while a flavored release records a real one — and the arm it refused was the **MATCHING** one. Fixed by a `_resolvedFlavor` getter mirroring the releaser's. Four tests, three of them discriminating: a NEGATIVE CONTROL reverting only that argument reproduces `FLUTTER_APP_FLAVOR: "foo" in the release, absent in this patch` and fails 3 of 4. Suite 75/75. **Host only — no flavored iOS fixture exists, so no device arm is constructible** |

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

### Android build-configuration enforcement — a PRODUCT GAP

| | item |
|---|---|
| ◐ | **CLOSED ON ANDROID 2026-08-14 — enforcement landed, and the gap below is preserved as its before-state.** Android now compares a patch's effective build configuration against the release supplement **after all injected patch args are known**, and refuses a mismatch **before any patch build begins** (`patch_command._assertBuildConfigAgrees`). Releases record the config in the supplement even when unobfuscated (`Releaser.recordEffectiveBuildConfig`). CLI regression written FIRST and demonstrably red, with a one-`app_id` shape so routing can never satisfy it; the assertion is that `buildPatchArtifact` was never called, not merely a non-zero exit. Post-fix hardware control on `R2`: release `--flavor bar` 2.1.0+1 → matching patch → **`FLAVORPROBE-V3` → `V4`**, check ran and did not refuse, APK taken from the REGISTERED artifact. Run on the `.bar` package so the before-fix specimen at `.foo` was untouched — both are installed, side by side. `evidence/android/g42-flavor/POSTFIX_DEVICE_ARM.txt`. ~~**Skippable by one route, recorded not closed:** a patch invoked with an unfingerprintable option (`--dart-define-from-file`) is not compared and proceeds with a warning — the same rule iOS follows.~~ **CLOSED 2026-08-14.** The framing was wrong, which is why the fix is narrow. There are **two** null states and they are not symmetric: a *release* built with the flag genuinely cannot be compared, has no remedy, and must stay patchable — refusing would strand it forever. A *patch* invoked with the flag against a release whose config **is known** is a different thing: the release's fingerprint is in hand and only the patch declines to state its own. That was a per-invocation opt-out of the entire check, and it opted out in precisely the case where a mismatch is most likely — a patch pulling defines from a file the release never had is a patch with different defines. "Cannot be determined" is not evidence of agreement. The patch-side null now **refuses**, citing the release's fingerprint and saying what to do instead; the release-side null still warns and proceeds. Regression written first and confirmed RED **in its final form** against warn-and-proceed (the assertion shape changed after the fix landed, so it was re-run against a reverted enforcement rather than trusted), with the release-side control GREEN in **both** runs — proving the fix did not collapse the two states into one. 87 tests in `patch_command_test.dart` pass; format clean; no new warnings. The before-state follows: |
| 🐞 | **PRODUCT GAP, measured on device 2026-08-14 — not a test debt.** *Android patching does not currently enforce Route B effective build-configuration compatibility. A patch built for flavor `bar` can be published against a `foo` release and execute on device, changing the runtime flavor identity.* Measured in two arms so the cause is isolated: with **two `app_id`s** a wrong-flavor patch exits 70 `Release not found` — refused by **`app_id` routing** (`shorebird_yaml.dart:69-72`), which says nothing about configuration; with **one `app_id`** it **exits 0, publishes, and the device applies it**, leaving `dev.selfhost.flavorprobe.foo` displaying `flavor: bar`. Source agrees: `RouteBBuildConfig` hits in `android_patcher.dart` = **0**; configuration comparison is an iOS/Route B mechanism only. **This is materially different from \"B5 failed\"** — the arm's stated meaning (*the fingerprint compares effective configuration*) is simply not implemented on Android. **PRESERVED NEGATIVE SPECIMEN — do not clean up:** patch **2** on app `cd447816-bccb-19e4-d653-38ba8fe2fc79` IS the demonstration, promoted to stable, with the device running it. Evidence `evidence/android/g42-flavor/`. **Follow-up is its own lane** and should start from the architecture question rather than copying iOS code: which Android release artifact/provenance carries the effective config; where in `android_patcher.dart` a patch-vs-release check can run *before* a patch is produced or uploaded; whether `RouteBBuildConfig`'s canonicalization is reusable or should be promoted into a platform-neutral build-config contract; covering `effectiveDefines`, flavor-derived `FLUTTER_APP_FLAVOR` and the other already-measured semantic fields consistently; and a precommitted wrong-flavor regression using **one `app_id`** so routing can never satisfy the refusal arm again |

### Obfuscation / symbols

| | item |
|---|---|
| ◐ | **BUILT** Obfuscation-related symbol retention machinery |
| ✅ | **PROVEN** Android patched crash symbolication with an obfuscated patch |
| 🐞 | **KNOWN ENGINE GAP — not "device validation outstanding".** Our `gen_snapshot` cannot consume an obfuscation map, so an obfuscated release is unpatchable on this engine. The CLI is already correct: the patcher asks for the RELEASE's own map, which is exactly right; the engine simply cannot take it. Per the classification rule this is a gap to decide about shipping, not a question to schedule a device for. Detail as measured: Found by running it, 2026-08-13. When the release was obfuscated the patcher passes `--obfuscate --load-obfuscation-map=<the release's map> --strip` to the patch build **on its own**, mirroring the release rather than taking the flag from the user — so a "patch without obfuscation" arm is not even constructible through the CLI. And our engine's `gen_snapshot_arm64` advertises only `--save-obfuscation-map`: the map was written and passed correctly (629 KB), the flag does not exist, and the AOT step exits **255** long before Route B is reached (`Target aot_assembly_release failed: AOT snapshotter exited with code 255`). So an obfuscated release cannot be patched on this engine at all, and release 35 is therefore **unpatchable by construction** rather than a specimen. `--load-obfuscation-map` is a Dart-fork capability we do not carry; adding it is engine work with its own mint. The host-side result below is unaffected. ~~**CROSS-REFERENCE 2026-08-13: the engine capability now exists on `R3` — see the `BUILT` row two below. This row is NOT upgraded and is still true of every SHIPPED engine, including cell `4df8f9b6`, because no mint has happened.**~~ **SUPERSEDED 2026-08-14 — THE MINT HAPPENED, and this row is now VERSION-SCOPED rather than universal.** Cell **`40eaa0ef6cb6485833bf2e10ac97224ca82cbf25`** ships a `gen_snapshot` that carries `--load-obfuscation-map`, and the served bytes were verified BOTH ways: `40eaa0ef` carries the flag, and the control `4df8f9b6` is byte-unchanged and still WITHOUT it. So the gap is **CLOSED for `40eaa0ef` and later**, and **remains exactly as written for `4df8f9b6` and every earlier cell** — which is not a formality, because those are the cells every prior verdict in this file was measured against, and a release cut against one of them with `--obfuscate` still fails at the AOT step with exit 255. **The same hazard exists upstream and is filed as shorebirdtech/shorebird#3864**: the CLI appends `--load-obfuscation-map` unconditionally, so any release whose pinned engine predates the flag fails identically. ~~Nothing in our CLI gates the flag on engine capability today~~ — **CLOSED IN THE CLI 2026-08-14, and the first attempt at it was wrong in a way worth recording.** `lib/src/gen_snapshot_probe.dart` now PROBES THE ACTUAL BINARY the release's own toolchain will run, and refuses before the build with the real cause named, instead of letting `gen_snapshot` exit 255 inside a Flutter build. **BUILT for the probe's `absent` classification only** — it was executed on this host against real stock 3.41.4 `gen_snapshot`s (iOS `gen_snapshot_arm64`, 15,662,144 B, and all three Android arches, 47,518,784 B), each classified `absent` with `save_obfuscation_map` present in the same bytes as a positive control, so the negative is corroborated rather than a bare failed grep. The `present` arm is SYNTHETIC (a copy with the flag appended) — real flag-carrying binaries live on `R3`, so *"the probe recognises a real `40eaa0ef` gen_snapshot"* is **UNVERIFIED**, one command for whoever next holds `R3`. The refusal itself has only ever run under mocktail and therefore earns **nothing**. **The rejected first design is the useful part: a Flutter-VERSION gate cannot work in this fork.** Cells `4df8f9b6` (`experimental_hashes.map:215`) and `40eaa0ef` (`:222`) both map to engine revision `69f9831c…` → `flutter_revision c15ef637…` = Flutter 3.44.8, so any version floor is above-threshold for both while the two cells genuinely differ on the flag. **The capability is a property of the minted CELL, not of the Flutter version**, and a version gate would have been inert against precisely the hazard this row documents |
| ◐ | **BUILT 2026-08-13** Route B iOS release + patch under obfuscation — `G4.3`. `probes/g43_obfuscation_semantics.sh` 8/8 classifies each flag BY MEASUREMENT: `--obfuscate` changes the **stripped program** bytes, so it is semantic and fingerprinted; `--split-debug-info` and its **path** change the ELF's DWARF only, so they are recorded for audit and excluded from compatibility. **A container built for an obfuscated release APPLIES** (`APPLY ok`, `OLD-obf` → `NEW-obf`) while the interface and manifest stay source-named — obfuscation is a gen_snapshot-stage transform and `gen_kernel` accepts neither flag, so provenance cannot carry transformed identities. Device gate still owed |
| ✅ | **PROVEN 2026-08-14** — obfuscated iOS release patched on device, cell `40eaa0ef6cb6485833bf2e10ac97224ca82cbf25`. **On byte-identical preserved release-39 bytes, applying Patch 1 at runtime changed the app's displayed value from `OLD-rel` to `NEW-OBF` with `code_patch=1`; the release binary itself remained unchanged** (`LC_UUID 1160d105…` before and after — a changed release binary would be the failure, not the result). Release 39.0.0+1 `--obfuscate`, patch 1, on `R1` iPhone 7 (wired): launch 1 `code_patch=none route_b=OLD-rel`, launch 2 `code_patch=1 route_b=NEW-OBF`, launch 3 stable, and **the screen reads `route B value: NEW-OBF`** (`evidence/releases/39/r39_NEW-OBF.png`) — the screenshot is the claim, the beacon is corroboration. `launch_release_bytes.sh` REFUSED the working archive (`62f0127f…`, a patch build) and launched the preserved release (`1160d105…`), which is the false positive it was built for. `assert_result_consumed.sh` on the release binary: CONSUMED, run before interpreting. The patch consumed the PRESERVED map by digest (`e682e6f7648fbfca`, 19,842 pairs), not whatever was left in `build/shorebird/`. Full identity in `evidence/releases/39/verdict.txt`. Prior host row: **BUILT 2026-08-13** `gen_snapshot` can LOAD an obfuscation map — the engine capability the row above says is missing. `selfhost/engine/0008-dart-load-obfuscation-map.patch`; `dart_patches.sh --verify` → `OK: all 5 patches applied on the pinned base`; host `gen_snapshot` rebuilt clean and advertises both `--save-obfuscation-map` and `--load-obfuscation-map`. `probes/g43_obfuscation_map_load.sh` **8/8**. **This is a HOST result on `R3` only — no mint, so cell `4df8f9b6` is untouched and the ENGINE GAP row above remains true of every shipped engine.** What the probe measures, and why the flag alone would not have earned this: a release is compiled and saved, then a *larger* program is compiled while loading that map — `drift=0` (every release rename survives) **and** `collisions=0` (no two identifiers share an obfuscated name). The contract was RECOVERED verbatim from the previous pin's fork binary, not invented; two string-table controls further show that binary carried the option as a **VM flag** with no new embedder API, which is the shape `0008` converges on. Three plan claims were refuted by measurement and are recorded in the H4 plan: (i) the specified `Dart_LoadObfuscationMap`-from-`bin/` shape cannot work — lldb shows the map is seeded inside `Dart_CreateIsolateGroupFromKernel`, before the embedder regains control; (ii) the specified cursor rule (`[a-z]`, lexicographic) lands **2,398** names early against a 20,000-name map, and the renames are actually a bijective base-52 numeral written little-endian; (iii) the pre-written probe **could not fail** — it compiled the same kernel twice, so the cursor was never consulted and all three cursor modes reported 0 collisions. Rewritten, the sabotaged modes now report **44** and **81** collisions while drift stays 0. Device arm and mint still owed |
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
| ◐ | **BUILT 2026-08-13** Stable track — asserted alongside two named tracks, `api_test.dart` "named tracks are independent, and promotion adds rather than moves". Server row only |
| ◐ | **BUILT 2026-08-13** Beta / staging / custom track — `beta`, `staging` and an unpromoted `canary` driven through `POST /api/v1/patches/check`. **This prices COVERAGE, not capability:** channels were already get-or-create by name (`api.dart:1589-1591`) and a non-stable channel (`internal`) was already exercised at `api_test.dart:2922-2940`, so what was missing was the named assertion, not the behavior. The `grep beta` that returned nothing is **not** evidence — that inference is the one §6 already retracted |
| ◐ | **BUILT 2026-08-13** Publish patch to a specific track — three tracks holding three different patches simultaneously |
| ✅ | **PROVEN 2026-08-14 — on device.** New fixture `trackprobe_app` (app `9fb5eebb-…`, release 4.0.0+1), `auto_update: false`, on `R2`. **Patch 1 → `stable` (`TRACKPROBE-STABLE`), patch 2 → `beta` (`TRACKPROBE-BETA`) — beta's published SECOND, so it is NEWER.** That ordering is the experiment: a device asking `stable` must get patch 1, and would get patch 2 if the server or updater simply served the newest. Publishing beta first would have made the arm unfalsifiable — the same trap G4.2 hit when two `app_id`s produced a right-looking refusal for the wrong reason. Server precondition checked first (`channel=stable`→1, `channel=beta`→2), so a vacuous arm would have been caught before the device. Device: launch `TRACKPROBE-V1` none/none with **both patches already on the server** (that is `auto_update:false` doing its job, and it is load-bearing — otherwise beta's patch could arrive unasked) → `check(stable)` outdated → `update(stable)` next 1 → restart **`TRACKPROBE-STABLE` current 1 ← the claim** → `check(beta)` outdated → `update(beta)` **current 1 / next 2 simultaneously** → restart **`TRACKPROBE-BETA` current 2**. The marker is compiled Dart, so it names WHICH patch executed, not merely that one did. APK from the REGISTERED aab (46,700,989 B, size-matched before install), not the local tree. A separate fixture from `manual_api_app` so G8's committed evidence stays untouched; the other four specimens verified intact. **NUANCE, recorded not resolved:** asking `stable` while running beta's patch 2 answers `upToDate` — the check compares patch NUMBERS, which are global per release rather than per track, so a device that took a higher-numbered patch from another track cannot be returned by asking. The row's claim holds for **acquisition**; membership is forward-only. Whether that is correct (no silent downgrades) or a gap (no way back) is a decision, not a test result. `evidence/android/g6-tracks-device/`. **The CONFIGURATION path is still untested because it is still unimplemented** — the prior text follows: |
| ☐ | ~~**NOT VALIDATED**~~ Device receives only the selected track — **and still NOT VALIDATED rather than BUILT, deliberately.** The host result above says nothing about a device: `compileShorebirdYaml` never copies `channel` (`shorebird_yaml.dart:68-70`), so the updater falls back to `DEFAULT_CHANNEL = "stable"` (`config.rs:24`, `:148`) and the server resolves `str('channel') ?? 'stable'` (`api.dart:1989`, **not** `:1953` — the anchor drifted). An unmodified device always asks for `stable`. Reachable via `checkForUpdate(track:)` or `shorebird preview --track`, not blocked |
| ◐ | **BUILT** Promote a rollout to another track — and the verb is **ADD**, not move. Now pinned by a test *and* a negative control: dropping `channel_id = @c` from `repository.dart:1205` makes the suite fail with a track serving `null` (`evidence/g6-tracks-server/supersession.md`). The CLI's own help said "move the patch to" until this commit |
| ◐ | **BUILT** Rollback / withdraw within a tracked rollout — channel-scoped, server-side |
| ⚠ | **KNOWN GAP (client surface) — RECLASSIFIED 2026-08-13 from NOT VALIDATED.** Progressive rollout: the **server half is BUILT** (`rollout.dart:19` bucketing, 10 tests, settable at `api.dart:1724`, admin route `:2533`), and `rollout` appears in **zero files** under `shorebird_cli/lib/src`, `shorebird_code_push_client/lib/src` or `shorebird_code_push_protocol/lib` — greps re-run 2026-08-13, not inherited. `PromotePatchRequest` carries `patchId` and `channelId` only. Source determines this, so it is a decision to make (add the protocol field, or document it as admin-only), **not a row to test** |

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
| 🐞 | **KNOWN GAP** The default configuration performs **no signature verification anywhere on the production path** — headline unchanged, **mechanism CORRECTED 2026-08-13**. This row read *"The default `patch_verification: install_only` performs…"*; the first clause is **false and is retracted**: `install_only` is not the default. `yaml.rs:7-8` marks **`Strict`** `#[default]`. What actually disables verification is the *second* gate — `lifecycle.rs:796-803` runs `check_signature` only `if let Some(public_key)`, and otherwise logs "No public key configured; skipping signature verification", which is the state unless `--public-key-path` was passed at release time. The only install-time verifier (`cache/updater_state.rs:363`) is **`#[cfg(test)]`-gated at `:348`** and documents that no production caller reaches it, while the real install path `record_install_complete` (`lifecycle.rs:897-922`) verifies nothing. So "install" in `InstallOnly` is wrong in both directions. Kept as a retraction rather than edited away: a reader who checked the old mechanism would have found `Strict` and disbelieved a conclusion that is correct. Working: [`SIGNING.md`](SIGNING.md), [`evidence/g7-signing/verification_path.md`](evidence/g7-signing/verification_path.md) |
| ☐ | **NOT VALIDATED** Signed Android release + patch |
| ☐ | **NOT VALIDATED** Signed iOS Route B release + patch |
| ☐ | **INHERITED** Invalid signature rejected — **`Strict` mode only, and only at the NEXT BOOT**, after the patch has been downloaded, installed, promoted and reported as a successful download |
| 🐞 | **KNOWN GAP** Key rotation — there is nothing to validate; no rotation mechanism exists. **Unchanged 2026-08-13:** writing the procedure down does not create a mechanism, and the row below moving to BUILT is about the *document*, not the capability |
| ◐ | **BUILT 2026-08-13** A documented rotation procedure — [`SIGNING.md`](SIGNING.md) carries the manual procedure (new keypair → **new release** with `--public-key-path` → sign subsequent patches with the match; older live releases keep the old key). **No mechanism was invented**, and the consequence is stated where a reader will hit it: a compromised private key **cannot be revoked** — every shipped release trusts its baked-in key until users move to a release built with a new one. Rotation is a re-release, not a revocation |
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
| ✅ | **PROVEN 2026-08-14 on `R2`** Check for update manually — `checkForUpdate()` returned **`UpdateStatus.outdated`** on CPH2551 against a real published patch, before `update()` was pressed. Fixture `manual_api_app` (release 3.0.0+1, patch 1). `evidence/android/g8-manual-api/` |
| ✅ | **PROVEN 2026-08-14 on `R2`** Download update manually — `update()` staged the patch: `next patch: 1` while `current patch: none`, then `current patch: 1` after restart. **The number alone is not the evidence** (outcome 9: `readCurrentPatch` is already exercised by every airgap release) — the fixture records the value BEFORE the call (`before update(): none`) and the CODE marker moved `MANUALAPI-V1` → `V2`, so patched code demonstrably ran. `evidence/android/g8-manual-api/` |
| ✅ | **PROVEN 2026-08-14 on `R2`** Disable the automatic update flow — with `auto_update: false` the app was installed and launched **twice** while patch 1 was already published, and applied nothing (`current: none`, `next: none`). Only the explicit `update()` staged it. One launch would not have shown this. `evidence/android/g8-manual-api/` |
| ✅ | **PROVEN 2026-08-14 on `R2`** Android manual update path — the whole sequence above ran end to end on CPH2551 against `cps-android`, with the APK taken from the **registered** release artifact rather than the local build tree (`shorebird patch android` rewrites it — see G10.2's finding). `evidence/android/g8-manual-api/` |
| ☐ | **NOT VALIDATED** iOS Route B manual update path |
| 🐞 | **KNOWN GAP** Restart-required / update-state behavior — `G15`'s, and out of scope for §8. **CAUSE CORRECTED 2026-08-13:** this row said "decided by the same **once-per-process activation guard**" as §5 and §9, and that phrase is one this file already retracted — nothing is armed once per process; arming is attempted on every `ConfigureShorebird`, and it was the *early return* above it, gated on an updater init that fails on its second call, that skipped it (fixed by patch `0007`, its three arming tests executing per patch `0008`). The row's conclusion is unchanged and still right; only the mechanism it names was stale. Repeating a retracted cause is how a reader re-derives a bug that was already found |

**Manual API parity: the four DRIVABLE rows are PROVEN on Android (2026-08-14); the iOS row and the restart-required KNOWN GAP are untouched.** The run used `UpdateTrack.stable`; driving a NAMED track is what `G6`'s device row additionally needs and was NOT exercised here.

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
sit in front of it, and the second is the one worth planning around: an add-to-app
host that creates a second engine — a common pattern — silently ran the *unpatched*
code in it. Silent divergence between two engines in one app is a worse failure than
a refusal.

**MECHANISM CORRECTED — this section said "Route B arms its activation hook once per
process", and that was wrong.** Nothing is armed once per process: arming is
attempted on every `ConfigureShorebird`, and it was the *early return* above it —
gated on an updater init that deliberately fails on its second call — that skipped
it. Retracted in §14b, fixed by patch `0007`, and its three arming tests now
EXECUTE (patch `0008`, 3/3). The EFFECT this section describes was real; the cause
was not what it said. Correcting it where the claim sits rather than rewriting it
silently, per this file's own correction rule.

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
| ✅ | **PROVEN 2026-08-14 — on device.** A CI-shaped non-interactive patch RUNS on `R2` (CPH2551): release 1.7.0+1 reads `CODEPATCH-V3 patch: null`, and after the patch applies it reads **`CODEPATCH-V4 patch: 3`**. The discriminator is the CODE marker, not the number — outcome 9 warns a patch number alone may be `readCurrentPatch` rather than patched code executing, which is why the harness's own patch 2 was useless (built from source identical to its release, so a code no-op). Patch 3 was made code-changing deliberately and was published by `shorebird --json patch android --no-confirm --release-version 1.7.0+1` with stdin `/dev/null`, exit 0, `interactive_prompt_required: 0`. Evidence + screenshots: `evidence/g10.2-noninteractive/device-2026-08-14/`. Prior host tier: **BUILT 2026-08-14 — the arm RAN, on `R12`.** `shorebird release android --no-confirm`, stdout AND stdin redirected, no CI vars, against `cps-android` over an SSH reverse tunnel: **exit 0, `Published Release 1.7.0+1!`**. The detector self-test fired in the SAME run (exit 64, both output modes), so "no prompt appeared" is a measurement rather than an absence. CLI under test was this tree's HEAD `5a95c303` (`analysisVersion` 8), transferred by git bundle — nothing published. **NOT PROVEN**: outcome 10 reserves that for the patch running on a DEVICE from a CI-shaped invocation. Evidence + the three defects the run exposed: `evidence/g10.2-noninteractive/arms-2026-08-14/`. Prior text: **NOT VALIDATED** Fully noninteractive CI release — **and still NOT VALIDATED, deliberately.** The guard is BUILT and was measured 2026-08-13 (`evidence/g10.2-noninteractive/flag_audit.md`), but the decisive arm — `release android` against **our** control plane with stdout not a TTY — was **not run**. Nothing short of that arm earns this row. **2026-08-14: re-verified as a PREREQUISITE (`R12`), not a failed gate.** `ci_noninteractive.sh` refuses on a non-Linux host, and its blocker — probed pre-mint — was re-probed against today's cells: `fc184af6` (the Route B **Android** cell) still serves `android-arm64-release/linux-x64.zip` **200** and `darwin-x64.zip` **404**; host is Darwin. The detector self-test DID run and is green in both output modes (exit 64; `interactive_prompt_required` producible), which licenses nothing about the release/patch workflow — see `evidence/g10.2-noninteractive/arms_blocker_reverified.txt` |
| ✅ | **MECHANISM CORRECTED 2026-08-14 (status unchanged — every observation stands, only its explanation was wrong).** Arm 3 reached the release chooser, which `evidence/g10.2-noninteractive/harness_arms.md` had argued was *unreachable* non-interactively. The log was right and the source reading was wrong: **`stdin.hasTerminal` is TRUE under `< /dev/null`**, because Dart classifies stdin by `st_mode` and `/dev/null` is a **character device**, which it reports as `StdioType.terminal` (measured on Darwin *and* linux_x64, identical; `/dev/zero` behaves the same, isolating chardev as the cause; `stdin.echoMode` — which uses `tcgetattr` and IS isatty-accurate — threw in every arm). This is the exact analogue of the hazard this fork already documented on the other stream at `interactive_mode.dart:15-17` (`Stdout.hasTerminal` is winsize-based), in the opposite direction. So `canAcceptUserInput` was **true**, the chooser was reached, and the exit-64 refusal is attributable to **stdout alone**. It is not only bookkeeping: `patch_command.dart:406`'s two branches are *prompt-and-die* vs *build-to-determine-the-release-version-and-proceed*, so the stdin SHAPE alone decides between a hard failure and a working patch. Real CI is mostly rescued by `isRunningOnCI`; what is exposed is a runner with `/dev/null` stdin and **no CI variable** — cron, systemd timers, `docker run` without `-i`. The harness keeps `< /dev/null` (it is what those runners actually give you) but its preflight no longer reports bash's isatty verdict as if it were the CLI's. `evidence/g10.2-noninteractive/STDIN_CHARDEV_2026-08-14.txt`. Prior: **PROVEN 2026-08-14 — on device**, same run as the row above: the patch produced by the non-interactive invocation applied on `R2` and its CODE executed (`CODEPATCH-V3` → `V4`). Its chooser caveat was separately satisfied by arm 3. Prior: **BUILT 2026-08-14, WITH ITS OWN CAVEAT UNMET.** Both patch arms ran non-TTY on `R12`: `patch android --no-confirm` **exit 0**, and `--json patch android` **exit 0** with **`interactive_prompt_required: 0`** (`Published Patch 2!`). **The row's stated mechanism is now EXERCISED — arm 3, added and run 2026-08-14.** `patch android --no-confirm` with **no** `--release-version`, stdin `/dev/null`, stdout redirected, against the two releases `1.6.0+1`/`1.7.0+1` so `release_chooser.dart`'s single-release shortcut cannot fire: **exit 64**, and the log names the prompt — *"Input was required for the following prompt but the CLI is running in a non-interactive context: Which release would you like to patch?"* Not 124 (no hang), not 0 (not silently skipped). Precommitted **outcome 11, the good failure**. The arm asserts the log NAMES the chooser rather than trusting the code, because **64 is also the usage code** — this same harness previously exited 64 for passing `--release-version` to `release android`, which rejects it. **This refuted a comment in the harness AND my own reading of the source**, both of which argued from `patch_command.dart`'s `else if (shorebirdEnv.canAcceptUserInput)` guard that the chooser could not fire non-interactively; corrected in place. Why `canAcceptUserInput` evaluated true under those redirects is **open and deliberately not guessed at**. Prior text: **NOT VALIDATED** Fully noninteractive CI patch — same, and the harness must publish **two** releases or it proves less than it appears: `release_chooser.dart:80-82` skips the release-selection prompt entirely when exactly one release exists |
| ◐ | **BUILT 2026-08-13** Token/auth failure produces a useful error — three arms (`SHOREBIRD_TOKEN` unset / empty / garbage), `shorebird account whoami` against `cps-android`, stdout redirected to a file so it was never a PTY. **All three exit 70 and name their cause**; unset reports "Failed to refresh credentials", empty and garbage both report `auth.dart:375-378`'s "Failed to parse SHOREBIRD_TOKEN. Expected an API key (sb_api_...) or a legacy CI token." Arms in `evidence/g10.2-noninteractive/token_arms.txt` |
| ⚠ | **KNOWN ISSUE — MITIGATED, NOT CLOSED, measured 2026-08-13.** An empty `SHOREBIRD_TOKEN` still surfaces a raw `FormatException` (`Unexpected end of input (at character 1)`) — what changed is that `auth.dart:375-378`'s named message now **precedes** it, so the exception is no longer the only thing the user sees. The row's literal claim remains true, and it is kept rather than downgraded: calling this fixed would overstate the measurement. A related CI-hostile detail found in the same run — the *unset* arm advises "Try logging out with `shorebird logout` and logging in again", which is the wrong hint where there is no interactive login |
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
>
> **STATUS 2026-08-13.** Prerequisite 3 (the code-patch stage) is **BUILT** — see
> the row below. Prerequisite 2 went from 4 audit findings to **1** for the cell in
> use (`881e4129`); what remains is `patch-linux-x64.zip`, which needs the Linux
> builder and is deliberately kept separate from the harness work — the two are
> independent prerequisites and mixing them would blur which one is blocking.
> Prerequisite 1 (the drifted seed) is **untouched**: re-running
> `prepare_airgap_fixture.sh` regenerates the pub seed and the `flutter create`
> output, so it belongs to the sealed session itself rather than to a session that
> is also building other things.

| | item |
|---|---|
| ✅ | **PROVEN** Own control plane |
| ✅ | **PROVEN** Own database / state |
| ✅ | **PROVEN** Own artifact / CDN path |
| ✅ | **PROVEN** Own Android engine artifacts |
| ◐ | **PROVEN for `70974f81`; the Route B cell `881e4129` is now audited too (2026-08-13), 1 finding left.** Its engine artifacts are still donor-cloned, and that is now measured rather than assumed: `sky_engine.zip` for `881e4129` **genuinely differs from stock** in `internal_patch.dart` and `internal/internal.dart` — the two files the killgate patch edits — and the mirror had been serving STOCK bytes for them under our hash. Published, protected, diff kept beside the zip as `sky_engine.content-diff.txt`. `publish_sky_packages.sh`'s header predicted exactly this case |
| ◐ | **PROVEN for the two audited EXPERIMENTAL cells** Own Dart / frontend / backend toolchain — see the vocabulary warning below |
| ✅ | **PROVEN** Compiler-cell provenance |
| ✅ | **PROVEN** Immutable compiler cells |
| ✅ | **PROVEN** Own patch differ path |
| ✅ | **PROVEN** Own Flutter source mirror |
| ◐ | **BUILT, and now RUN against a Route B cell for the first time — 2026-08-13.** `audit_overlay.sh --hash 881e4129 --cell macos-ios` went from **4 findings to 1**. Fixed: the compiler cell was `UNPROTECTED` (owned by policy, unmatched by `@must_be_local`, so a miss served STOCK bytes from the pinned hash — the CLI resolves that cell BY the release's engine hash precisely to guarantee provenance, so a silent substitution is the worst case, not a cosmetic one); `sky_engine.zip`/`flutter_gpu.zip` published and protected per-cell; `artifacts_manifest.yaml` emitted; `patch-darwin-x64.zip` cross-built natively. **Remaining: `patch-linux-x64.zip`, which needs the Linux builder** |
| 🐞 | **BUILT but STALE** Air-gap fixture — the pub seed no longer matches the fixture's `pubspec.lock` |
| ◐ | **BUILT 2026-08-13, NOT YET RUN** A sealed **iOS code-patch** stage — `airgap_acceptance.sh` gains `stage ios-code-patch`, wired separately from the assets-only stage so an assets pass can never satisfy the code-patch claim. It **fails closed** through six ordered gates, each ruling out a way a device result becomes unattributable: release identity preserved before the patch build can overwrite the archive → release patchability on the preserved bytes → **result-consumption** for the fixture's target → a patch published WITHOUT `--assets-only` → installed-binary identity unchanged (`AIRGAP_EXPECT_UUID` makes `launch_fixture` assert LC_UUID and take that over its mtime heuristic, which after a patch build fires on the correct artifact) → the patched value read from the **beacon**, not a screenshot. Running it needs the sealed environment plus the device, so it is BUILT, not PROVEN |
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
| a second engine silently runs unpatched AOT | §9 | ~~the hook is armed once per process; engine two never arms it~~ — **mechanism corrected 2026-08-13, see below. The effect was real; the cause was not what this row said.** |

**The second-engine case is the severe one.** It produces two Flutter engines in one
process executing **different program versions**, with no error, no log, and no
user-visible failure — the app simply behaves inconsistently depending on which
engine served a screen. Add-to-app hosts create engines lazily and sometimes more
than once, so this is a mainstream configuration, not a corner.

#### The second-engine mechanism, corrected from source — 2026-08-13, patch `0007`

**Nothing is "armed once per process".** Arming is attempted on every
`ConfigureShorebird` call. It sat BELOW an early return whose condition is "the
updater initialized", and the updater *deliberately refuses to initialize twice* —
`third_party/updater/library/src/config.rs`, `set_config()`:

```rust
if config.is_some() {
  bail!("Updater already initialized, ignoring second shorebird_init call.");
}
```

whose own comment says that "happens regularly with apps that use Firebase
Messaging". So for engine two `shorebird_init` returns false **by design**,
`init_result` is false, `if (!init_result) return;` fires, and
`InstallRouteBActivationHook` is never reached.

**So the fix is a one-statement move, not a redesign of the activation model** —
arm above the guard. Safe in both directions: on a second call the updater is
already initialized so `route_b_path` was resolved normally; on a genuine init
failure `NextBootPatchPath` yields nothing, `route_b_path` is empty, and the hook
is inert by contract. The auto-update thread start stays below the guard, which is
what that early return is actually for.

**The precedent is one line above the change.** `shorebird_report_launch_start` was
moved out of `ConfigureShorebird` for the same class of reason — *"fixes issues with
FlutterEngineGroup and other cases where ConfigureShorebird() is called but no Shell
is created"*. Launch reporting was fixed for multi-engine; the Route B arming was
left behind the guard.

**Verification state, stated exactly.** `shorebird.cc` compiles, and three new tests
pinning the arming contract (inert on empty path; armed even when the container file
is absent, because it is opened later from the callback; an existing callback CHAINED
rather than replaced) compile too — where there was previously no coverage at all.
**The tests are NOT RUN**: `shorebird_unittests` cannot link in this tree because it
also compiles `patch_cache_unittests.cc`, whose subject calls
`Shorebird_ReadLinkHeader`, a symbol only Shorebird's PRIVATE Dart fork defines. That
is pre-existing, and it is the same trap `build_ios_release.sh` documents for
`shorebird_use_interpreter`. To run them: build the target in the shipping iOS tree,
or add a test target excluding that file. **The two-engine behaviour is not yet
verified on a device; that gate needs a mint.** So this is a corrected diagnosis plus
a compile-verified fix — not a closed gate.

The other two symptoms (crash-backout, restart-required) are a *different*
mechanism — `ReportLaunchSuccess` firing in the `Shell` constructor — and are
untouched by `0007`.

**~~Why it ranks 4th and not 1st.~~ SUPERSEDED 2026-08-14 — `G15` IS NOW FIRST.**
The original argument is kept below because it was right about the shape of the
trade and wrong about one fact.

> ~~It constrains reliability, not reach: fixing it makes the ~7 % surface
> *trustworthy* without making it larger. Language reach (`G3.6e`, `G3.7`) changes
> what the product can do; this changes whether what it does can be depended on.
> Both are needed; reach was ranked first because a fundamental limitation there
> would reshape everything below it.~~

**What changed is not the severity of the consequence — it is the validity of the
mechanism.** The crash-backout seam is now **source-proven incapable of observing
user Dart execution at all**: `main` is posted to the message queue, so
`Engine::Run` returns before one line of it runs. Route B therefore has **no
validated mechanism for distinguishing a successfully booted patch from a
Dart-phase failure.** That is a shipping blocker on its own, independently of how
bad the worst case turns out to be: shipping with an invalid success signal means
the safety contract is not weak, it is *unknown*.

**The brick/reinstall severity claim is SUSPENDED, not withdrawn** — pending
fixture repair and remeasurement. It may well be re-established; it is simply not
evidence today, because the fixture it rested on never reached `main()` even with
no patch installed.

Reach work (`G3.6e`, `G3.7`, static-vs-instance) is held behind this deliberately:
those increase what can be patched, and this determines whether the system can
tell a good patch from one that broke the app.

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
| ☐ | **A Dart-phase crash backs the patch out** — **FAILING, AND NOW PROVEN FROM SOURCE RATHER THAN INFERRED FROM A DEVICE — 2026-08-14.** Patch `0009` moved launch-success out of the `Shell` constructor to `Engine::Run` returning, and that seam **cannot work in principle**: `_delayEntrypointInvocation` (`isolate_patch.dart:298`) posts `main` to a `RawReceivePort` and returns, so `InvokeMainEntrypoint` → `LaunchRootIsolate` → `Engine::Run` **all return before any user Dart has run**. Success is banked one message-loop turn too early, every time, by construction. ~~The device arm's causal reading — a patch throwing in `main()` banked three successes~~ **is RETRACTED as unsupported: the same blank screen occurs on the same release with NO PATCH INSTALLED, and the fixture's alternating marker shows `main()` runs in neither configuration.** The banked-success observation itself stands. Evidence: `evidence/g15/crashbackout_control_verdict.txt` (which supersedes the attribution in `crashbackout_verdict.txt`, corrected in place). **The fixture must be repaired before any seam experiment** — its failure mode is a blank screen, indistinguishable from the crash it is meant to detect | §14b, `G15` |
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
| **R7** | `packages/shorebird_cli/lib/src/route_b_producer.dart` + `selfhost/engine/route_b/coverage/analyze_coverage.dart` | versioned **together — currently v8** (`analyze_coverage.dart:66` `const analysisVersion = 8`, `route_b_coverage.dart:44` `const supportedRouteBAnalysisVersion = 8`; corrected 2026-08-13 from "v4", stale by four bumps). Two goals editing these conflict in source, not just in schedule |
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

### 2026-08-13: the third instance, and the one this table could not have prevented

Two sessions took **`H2`** — the flavored fixture — within four minutes of each
other, and neither could have discovered the other by following the protocol
above. The full clock is in `HANDOFF.md`'s 15:55 entry; what matters here is why
the existing rules did not bite:

**A resource that does not exist yet cannot be claimed.** Every protection in this
section is keyed to the claims table, and the table is keyed to `R-ids`. `H2`
creates a **new** fixture — its own order says "owns: none exclusive… a NEW
fixture, so no `R6`" — so there was no row to hold, nothing to read as taken, and
`git status` showed a single untracked directory that each session correctly read
as its own work. Both prior instances were about **staging** discipline; this one
is about **identity**, and it is the one case where "read the tree first" returns
a clean answer to both workers simultaneously.

**The fix is cheap: claim the PATH, before the first file exists.** A row naming
`selfhost/fixtures/flavored_app` with no `R-id` at all would have been enough. A
claim is a statement of intent, not a property of an existing artifact.

### 2026-08-14: the fifth swallow, and the first where the ABSORBED work was the reporter's

`6378ae2f`'s message is *"assert_mint_ready would greenlight a build that never
ran"*. Its diffstat is four files: that probe, **plus** `patch_command.dart`,
`patch_command_test.dart` and `evidence/android/g42-flavor/a2_regression_red.txt`
— A2's build-config enforcement, its regression, and its red-state evidence.
Nothing was lost and the tests are green in `HEAD`, but the message and the
diffstat describe different work, and a reader trusting either one alone is
misled.

**What makes this instance different.** Every earlier instance was a broad stage
(`git add -A`) capturing a neighbour's unstaged edits. This one was not: the
absorbed files had been staged *deliberately, by explicit path*. The gap was
TIME. The lane staged, then ran a ~4-minute full test suite, then committed —
and the other worker committed inside that window, carrying the already-staged
index entries with it.

**So the existing rule is necessary but not sufficient.** §17 rule 10 and the
2026-08-14 addition both say to re-read `git status` immediately *before
staging*. That does not help here: the status was clean of foreign files at
staging time. **The exposure is the whole interval between `git add` and `git
commit`, and it is proportional to whatever you do in between.** Two practical
consequences, neither of which needs new tooling:

1. **Stage last.** Run the suite, the analyzer and the probes *first*; stage only
   once the commit is the very next command.
2. **Verify after committing, not only before.** `git show --stat HEAD` is the
   only thing that proves what your commit contains — and if your files are
   missing from it, look for them in someone else's commit rather than assuming
   the commit failed.

The recovery is bookkeeping, not surgery: the content is correct in `HEAD`, so
the fix is to say so here rather than to rewrite history that another lane is
already building on.

**What it cost, and what it nearly cost.** `41758dd3` staged broadly and captured
the other session's unstaged `derive_overlay.py` and overlay `project.pbxproj`,
then **described them as not done** — so its message contradicts its own diffstat,
and a reader who trusted the message would author a second transform over a
working one. In the other direction, the second session then overwrote that
commit's two `xcconfig` files sixty seconds later, and restored them byte-exact
from `HEAD` on noticing. Nothing was lost, for the third time by ordering rather
than by design.

**So the promoted rule is: a commit message is not evidence of its own contents.**
`git show --stat` is. When two workers are live, read the diffstat of any commit
you are about to build on — the 2026-08-11 entry says a broad stage swallows
files, and this one says the swallowing worker will not know it happened and will
tell you so in good faith.

#### 2026-08-14: an EARLIER tell, and the tool that makes a shared file safe

The sixth instance was caught **before** staging, by a tell this section did not
name: the editor refused an edit to `PARITY.md` with *"the file had been modified
on disk since you last read it"*. That warning fires the moment another lane
writes the file, which is **strictly earlier** than the existing status-based
rule — that one waits for a file to *leave* your modified set, i.e. until after
the other worker has already committed. Both belong on the page; this one gives
you the window before anything is lost.

**The addition to rule 10: treat "modified on disk since you last read it" as a
collision alarm, not as a stale-cache annoyance.** The correct response is to
read the diff and find out whose work is in there — not to re-read and retry the
edit, which is what the message superficially invites.

**And the tool that makes it recoverable: stage the HUNK, not the file.** When one
tracked file holds two lanes' unstaged work, `git add <path>` is not available
without swallowing — but the commit is still possible:

```sh
git diff <path> > /tmp/full.patch      # extract only YOUR hunk from it
git apply --cached /tmp/mine.patch     # stage that hunk alone
git diff --cached --stat               # verify: your lines only
```

Used on this occasion to land a `G15` queue edit while a concurrent `G4.1
--dart-define-from-file` lane's §4 rows, claims row, and untracked
`evidence/g41-define-from-file/` sat un-staged in the same tree — all of which
survived intact. **`git add -p` is NOT available in this environment** (no
interactive flags), so the patch-file route above is the one that works.

### Claims

Update this table in the same commit as the work. Stale rows are worse than no
rows, so **clear your row when you stop**, even mid-goal.

| resource | held by | goal | since | notes |
|---|---|---|---|---|
| `R1` iPhone 7 | — | `G15` crash-backout control | released 2026-08-14 | **free. THE CONTROL RAN AND DID NOT CLOSE — read `evidence/g15/crashbackout_control_verdict.txt`.** `killswitch_probe` release `1.0.3+1` is **INERT**: three launches, blank white every time, and `/Documents/g15_armed` UNCHANGED across a launch, so `main()` is not executing in either arm. Updater state is `state.json` only — **no patch installed**, so the blank screen is not patch-caused and the crash-backout arm's attribution is retracted. Positive control on the same instrument PASSED (`airgap_probe` rendered fully, `control_positive_airgap.png`), so this is the fixture, not the rig, and not the instrument. Launch with `idevicedebug run`, NOT `ios-deploy --justlaunch`. Nothing uninstalled. Prior: **free.** Left with release `39.0.0+1` installed and patch 1 APPLIED (`code_patch=1`, screen reads `NEW-OBF`). NOT uninstalled — doing so resets iOS Local Network consent and the app then blocks on a modal before any code runs. Prior: **HELD.** Wired (`ioreg -p IOUSB` shows `iPhone@00140000`). Prior: **free.** Left with release `23.0.0+1` installed and patch 1 active (`code patch: 1`) but NOT applied — see the device-gate finding. The device is fine; the patch's kernel came from the wrong engine. Previously: Wired (`ioreg -p IOUSB` shows `iPhone@00140000`), iOS 15.8.8, online to `xctrace` as `8cb4bc98…`. Note `devicectl` reports it `unavailable` — iOS 15 is not a CoreDevice, so the install transport is chosen by version, not by that listing |
| `R2` Android device | — | — | released 2026-08-14 | **free.** Three fixtures now installed, each a live specimen: `dev.selfhost.manual_api_app` (G8, release 3.0.0+1 + patch 1 applied via the Dart API), `dev.selfhost.flavorprobe.foo` (G4.2, running the MISMATCHED bar patch — the preserved negative specimen, do not clear), and `com.example.rbtest` (G10.2, release `1.7.0+1` + patch **3** APPLIED (screen reads `CODEPATCH-V4 patch: 3`). `adb reverse tcp:18081` is still set; clear it with `adb reverse --remove tcp:18081` if another lane needs the port. Prior: **HELD.** CPH2551 `3f72a543`, wired USB on this Mac. Reaches `cps-android` via `adb reverse tcp:18081`. Claimed to close `:2375`/`:2376`'s device gap — a CI-shaped non-interactive patch actually running on hardware |
| `selfhost/fixtures/killswitch_app` (no `R-id`) | — | `G15` gate 1 — receipt repair | released 2026-08-14 | **free. GATE 1's HOST HALF IS DONE; ITS DEVICE HALF (gate 2) IS NOT.** The receipt was rebuilt from a toggling bit into an APPEND-ONLY PHASE LOG at `/Documents/g15_receipt`, written by both halves of the app: `native launch` → `native engine` (injected into `AppDelegate.swift` by the prepare script, since `ios/` is generated) → `dart-main-entered` → `boot-probe-returned:X` → `arm:kill`/`arm:render` → `first-frame`. **The last line present names the point the launch reached**, so a gap localises the failure to one step — and the native half is the only thing that can separate *"Dart never started"* from *"the app never really launched"*, the two states the 2026-08-14 control conflated. Invariants, and they are load-bearing: the receipt write is the FIRST statement of `main()` ahead of every patchable call; `bootProbe()` is NOT wrapped in `try/catch` (the seam under test must see the unhandled throw, and guarding it would make the gate vacuous); an instrument fault renders red instead of killing. `flutter analyze` clean for `lib/main.dart` (the 25 remaining issues are the gitignored stock `test/widget_test.dart` and a patch-scratch file under `build/`); the injected Swift `swiftc -typecheck`s. **Version bumped to `1.0.4+1`** — releases 1.0.0+1 … 1.0.3+1 are published on `cps-ios`; bump again before cutting another. `lib/main.dart` is in its RELEASE form (`bootProbe() => 'boot-ok'`, `routeBValue() => 'OLD-kill'`) so the next release cuts from it directly. **NOT YET BUILT OR RELEASED — no device run has exercised the new receipt, so it is unproven on hardware.** **Two traps already paid for and fixed in the script:** `HOME` is unset on iOS (the marker path must come from `Directory.systemTemp.parent`), and `base_url` must be the Mac's LAN address because `localhost` on the device is the PHONE. **The device's updater state was WIPED** with `ios-deploy --rmtree` to clear a crash loop, so the app boots the release with no patch selected. Prior claim note: | **Claimed BEFORE the directory exists**, which is the whole lesson of the H2 double-take and of this session's own fan-out collision: a path with no `R-id` cannot be claimed unless someone writes the row. A fixture that kills its own process at a chosen moment during launch — deterministically standing in for swipe-away / launch watchdog / jetsam. G15's design records why `twoengine_app` CANNOT serve this arm: `_boot()` ends in `runApp()` and both entrypoints call it, so it is not headless and the prior design's arm 4 was a false green on that ground. |
| `~/.shorebird` rig state (no `R-id`) | — | `G15` device arms | released 2026-08-14 | **free, AND THE STAMP IS RESTORED.** `engine.version` is back to `40eaa0ef6cb6485833bf2e10ac97224ca82cbf25` — the PROVEN lineage — so any release cut now consumes it rather than G15's cell. The cache still holds `80e493e4`'s artifacts; the next build for `40eaa0ef` refetches them by stamp, as this session demonstrated in both directions. To go back to G15's engine: stamp `80e493e4c5c9e4c418c433bf660392067a131dd5` and warm. Prior claim note: | **[MUTATES shared rig state]** Restamping `bin/internal/engine.version` in the pinned Flutter (`c15ef637…`) from `40eaa0ef` to the new cell **`80e493e4`**, clearing the artifact cache and re-warming it, so a release consumes G15's engine. **This is why the row exists: any release cut by another session while this is held will silently consume the G15 engine instead of the PROVEN `40eaa0ef` lineage** — no git conflict, no error, just a different engine underneath. `HANDOFF.md` records that re-syncing `~/.shorebird` invalidates another session's environment without touching git. **To restore:** stamp `engine.version` back to `40eaa0ef6cb6485833bf2e10ac97224ca82cbf25` and re-warm; both cells are published and served, so the revert is a stamp, not a rebuild. Checked before claiming: no uncommitted fixture version bump beside a fresh map line, i.e. §17's tell says no device gate was running elsewhere. |
| `R3` route-b tree | — | `G15` crash-backout + restart-required | released 2026-08-14 | **free. TREE HEALTH ON RELEASE: GREEN** — `dart_patches.sh --verify` → `OK: all 5 patches applied on the pinned base`, run at release. The tree carries TWO NEW uncommitted edits, and both are CAPTURED: `shell.cc` (patch `0009`) and `third_party/updater`'s `lifecycle.rs` (patch `0010`). **Note for the next holder:** `third_party/updater` is its OWN git checkout, so the engine repo's `git diff` does NOT see the Rust change — capturing it needed a second `git diff` inside that directory, and missing that would lose half the work silently. `out/ios_release` was rebuilt and consumed into cell `80e493e4`. Prior claim note: **TREE HEALTH AT CLAIM: GREEN** — `dart_patches.sh --verify --dest .../third_party/dart` → `OK: all 5 patches applied on the pinned base` (0001, 0004, 0005, 0006, 0008), run immediately before claiming. Implementing `plans/G15-crash-backout-and-restart-required.md`: moving the launch-success report out of the `Shell` CONSTRUCTOR (`shell.cc:537`, gated only on `vm_` existing, so it banks success before the root isolate exists) to after `Engine::Run` returns — the earliest point that proves patched Dart actually started. Also claiming **`R11`** (the mint this needs) and **`R1`** (wired, `iPhone@00140000`) for the device arms. **[MUTATES the engine tree]** — the change will be captured as `selfhost/engine/route_b/0009-*.patch`, because `R3` is not in git and an uncaptured edit evaporates when the tree is recreated. Prior release note: **free. Tree health on release: GREEN** — `dart_patches.sh --verify` → `OK: all 5 patches applied on the pinned base`, working tree clean. `out/ios_release` rebuilt from patch `0008` (ninja exit 0, `assert_mint_ready.sh` → `VERDICT=success`) and consumed into cell `40eaa0ef`. Prior claim note: **HELD. Tree health at claim: GREEN** — `dart_patches.sh --verify` → `OK: all 5 patches applied on the pinned base`, working tree clean, Dart base `6b58bb3a` over `d684a576`. Building `out/ios_release`; the host tier is already committed at `4bcdcb9b`. Prior release note follows: **free. Tree health on release: GREEN** — `dart_patches.sh --verify` → `OK: all 5 patches applied on the pinned base`. The Dart subtree carries a NEW edit, and it is captured: `selfhost/engine/0008-dart-load-obfuscation-map.patch` (`--load-obfuscation-map`), appended to `PATCHES`. `out/host_release_arm64/gen_snapshot` was rebuilt from it (ninja exit 0) and advertises the flag; `out/ios_release` was **not** rebuilt, so no mint and cell `4df8f9b6` is untouched. **Note for the next holder:** `0008` is the first Dart patch to touch a file another patch already touches (`0005` also edits `precompiler.cc`), so `PATCHES` order is now load-bearing rather than conventional — and an insertion adjacent to `0005`'s hunk context makes `0005` report `[CONFLICT]`, which is what happened once here and was fixed by relocating the added flags clear of it. Previously: released 2026-08-12, `dart_patches.sh --verify` all 4 applied, `route_b_analyze.aot` + `route_b_gen_dynamic_interface.aot` rebuilt and now published in cell `ee001fd7`. Nothing uncommitted in the Dart subtree; `$OUT/zip_archives` holds the exact bytes that cell carries |
| `R4` ios-engine tree | — | — | — | **free** |
| `R6` canonical fixture | — | — | released 2026-08-14 | **free at `39.0.0+1`.** `lib/main.dart` is in its RELEASE form (`value()` returns `OLD-rel`) — restored 2026-08-14 after G4.3's patch arm, so release 40 can be cut from it directly. The patch form used for release 39's arm was `'NEW-OBF'`; `dart analyze` clean after the restore. Prior: **HELD.** `airgap_app` currently `38.0.0+1`. Prior note stale on version: **free at version `23.0.0+1`.** `lib/main.dart` is left in its PATCH state (`value() => _secret`), not the release state — whoever resumes either reverts that line or treats it as the next patch's source. Previously: Added one private field the release never reads — being unread is the condition under test, since retention then depends entirely on P2's `--private-dill` enumeration. Version bumps to 23 with this release |
| `R7` producer/analyzer | — | — | released 2026-08-12 | **free.** Analyzer is **v8** — `route_b_coverage.dart:44` reads `const supportedRouteBAnalysisVersion = 8`, verified 2026-08-13. **This row said `v7` until 2026-08-13**, and the mint table below (queue item 3, "`analysisVersion` 8: parameterised targets are no longer `unsupported`, and the CLI's pin already moved") already said 8 — so §17 and the queue disagreed about the version of the artifact a device gate binds against, in the one table a new worker is told to read first. The v7 pair was published as cell `ee001fd7`; the v8 pin ships with cell `4df8f9b6`. Left committed at `1c3ffe13`, full `shorebird_cli` suite green |
| `R8` `cps-ios` | — | §4 Wonderous gap — the decisive run | released 2026-08-14 | **free. RUN COMPLETE: §4's real-third-party-app gap is CLOSED on the build clause.** App `589036b4-39ee-389b-c9fe-94fd42474a03` registered, release **88** (`2.2.7+236`) published, iOS active, cell `40eaa0ef`. Container left up and healthy; no patch published, no device touched, and the app is left registered so a patch arm can ride this release without a re-cut. **One provenance gap found and NOT fixed here:** the control plane's release record carries `flutter_revision` but **no engine or cell field**, so the server cannot answer "which Route B cell produced this release" — only the shipped `route_b.json` can. The authoritative server-side record is weaker than the on-device artifact, which is worth closing before anyone audits a release from the console alone. Prior claim note: **Container up (healthy).** Registering ONE app and cutting ONE Route B iOS release of the real third-party app at `/Users/mendell/compat-corpus/wonderous` — the run §4's KNOWN GAP row says is owed. No patch, no device. Also claiming that corpus path (no `R-id`, so it could not otherwise be claimed — the H2 lesson). Reading `~/.shorebird` only; **not** resyncing it, because the remedy under test (`cd453304`, import-kernel private enumeration) is already in the rig CLI at `ba4e1c02` and resyncing would mutate another session's environment for no gain. The rig CLI therefore LACKS this branch's later commits — `f06fa056`'s flavor-spelling fix among them — which is acceptable and worth stating: Wonderous is unflavored, so that call site resolves identically. Prior: **free.** Release 39 (`39.0.0+1`) and patch 1 published against it. Prior: **HELD.** Container up (healthy). Prior: **free.** Release 69 (`23.0.0+1`) and patch 1 published against it. Previously: Container up and healthy; one release and one patch will be published against it |
| `R9` `cps-android` | — | — | released 2026-08-14 | **free.** Now carries releases `1.6.0+1`/`1.7.0+1` and patches up to **3** for app `5653c73c`. Prior: **HELD.** Prior: **free, and now carrying two android releases** (`1.6.0+1`, `1.7.0+1`) plus patch 2 for app `5653c73c`, published by lane D's arms. Prior: **HELD**, reached from `R12` over an SSH reverse tunnel (`-R 18081:localhost:18081`), so nothing is exposed off this Mac. Prior: **free — but NOW RUNNING, and it was stopped before today.** `docker start cps-android` (explicitly authorised; **not** a compose operation — the container carries no compose labels). Up on `:18081`, own bind mount `shorebird-rig/control-plane/cps-android` and own `code_push.db`, so **no state is shared with `cps-ios`**, which was not restarted and stayed healthy throughout. **Left RUNNING** for whoever takes lane D's harness arms; stop it with `docker stop cps-android` if you want the host back to how it was this morning. Only three read-only `account whoami` calls were made against it — no app registered, no release, no patch |
| `R10` server source | — | `G6` lane B | released 2026-08-13 16:15 | **free. TREE HEALTH: GREEN on all three.** CI's three commands in CI's order: `dart format --output=none --set-exit-if-changed .` → **exit 0**; `dart analyze --fatal-infos --fatal-warnings` → "No issues found!"; `dart test -x integration` → **291 passed** (290 before this lane). **The format gate was RED and is now repaired** — `test/api_test.dart` had been unformatted as far back as `1cc1ff3e` (2026-07-31), which is formatter-style drift rather than any recent regression, so CI's format step would have failed on this branch at any point since. It was reported first and repaired as its own commit rather than swept into the lane that noticed it, because the 217-line diff crosses code that lane did not write. This lane's own addition was **not** format-clean as first written — the formatter wanted to rewrap its `test(...)` header and reindent the whole body — so the formatter's own version of that block was spliced back in and re-verified: `dart format` now proposes **zero** changes inside lines 2920-3030, and the diff against the previous file is **purely additive** (0 lines removed, 110 added). The pre-existing RED elsewhere in the file is therefore untouched rather than laundered |
| `R11` sealed CDN | — | — | released 2026-08-14 | **free, serving `40eaa0ef`, and the sky-packages hole is CLOSED.** `M0` steps 8-9 done for BOTH `40eaa0ef` and `4df8f9b6`: each went **5 missing-required / 2 unprotected → 1 / 0**, the one remaining being `patch-linux-x64.zip`, which needs `R12` — per M0 step 9, one finding is the best achievable state on this host and `AUDIT CLEAN` is unreachable here. `sky_engine.zip` now serves **200 from disk** (was 302 to stock) and the CONSUMED copy at `bin/cache/pkg/sky_engine/.../internal_patch.dart` carries **4** `attachBytecodeToFunction` where it carried **0**. `Caddyfile`'s `@must_be_local_pkgs` names both hashes. Warm preserved across the purge+refetch: ios-release Flutter `e828f8ef…` present, `gen_snapshot` still 10 flag hits, `engine.version == engine.stamp == 40eaa0ef`, `assert_diagnostic_engine.sh` **5/5**. Evidence: `evidence/cells/40eaa0ef…/`. Prior: **HELD.** Repairing the provenance hole M0 step 8 names: `sky_engine.zip`/`flutter_gpu.zip` are ABSENT from the overlay under BOTH `40eaa0ef` and `4df8f9b6`, so both 302 to stock — and the consumed copy at `~/.shorebird/.../bin/cache/pkg/sky_engine` carries **0** `attachBytecodeToFunction` where our tree has **4**. Stock Dart-SDK patch sources are being served AND consumed under our own hashes. Pre-repair audit for each: missing-required 5, unprotected 2. **[MUTATES overlay, Caddyfile, cdn-cache, and the flutter pkg cache]** Prior: **free, and serving `40eaa0ef`**, which is now a PROVEN lineage. Prior: **HELD for consumption only — no further mint.** Prior: **free, and serving `40eaa0ef`. STOPPED BEFORE step 10: cutting the obfuscated release requires restamping `~/.shorebird`'s `engine.version` from `4df8f9b6` to `40eaa0ef` and warming its cache, and `~/.shorebird` is shared mutable rig state the handoff assigns to another session — not taken without an explicit handoff.** Rig state read-only at release: branch `selfhost-under-test` at `ba4e1c02`, clean, `analysisVersion` 8 (matches ours, so no CLI resync is owed — only the stamp and a warm). Prior note: **HELD. MINT DONE, CDN RELOADED, and both verified.** New cell **`40eaa0ef6cb6485833bf2e10ac97224ca82cbf25`**, donor `4df8f9b6`, minted 2026-08-14. `audit_route_b_compiler.sh --hash 40eaa0ef` → **AUDIT CLEAN** (18 checks, incl. "published ios-release/artifacts.zip matches ios_artifacts_sha256"). `cdn-cache` force-recreated so Caddy re-read the map; served bytes verified BOTH ways — `40eaa0ef` HTTP 200 byte-identical to the audited overlay copy (`d3311d15d43ca7a9`) and carrying the flag, and the control `4df8f9b6` HTTP 200 byte-identical (`8b0ea72b80d8fbd6`) and still WITHOUT it. **`4df8f9b6` and `11e5695…` are byte-unchanged**, so every G15/G3.7 verdict keeps its lineage. Prior state: **HELD, not yet mutated.** Claimed BEFORE the iOS build so the mint cannot race another lane; `R1`/`R6`/`R8` deliberately NOT claimed yet — they are step 10-12's and stay free until then. Cell `4df8f9b6` is still the served lineage at claim time. Prior release note follows: **free, and serving `ee001fd7`.** `cdn-cache` is running unsealed. **Known hazard recorded:** the `ee001fd7 -> 69f9831c` map entry is what lets Flutter's cache rewrite the engine stamp mid-build, which is the device gate's failure. Previously: `cdn-cache` recreated so Caddy re-read the hash map — new-hash fallback went 404 → 302, cell zip serves byte-identical to the audited copy, old-hash control unchanged. Running **unsealed** (`upstream/enabled.caddy`), deliberately: sealing is host-global and would break every other build. Prior state below.<br>**free — and the mint HAPPENED this time.** `ee001fd78fcd5e78e976d35284bd13e1caffff63`: three cell files in ONE address change — `route_b_analyze.aot` (v6→v7), `route_b_gen_dynamic_interface.aot` (`--policy`/`--manifest`), `dart2bytecode.aot` (`--resolve-private-names-in-library`). Audit clean; host path 10/10 against the published zip. **The CDN still needs a reload** for Caddy to serve the new map entry, and no Flutter checkout has been restamped — both are the next holder's, because both mutate someone's environment |
| `R12` hermes-vps | — | — | released 2026-08-14 | **free.** Built patch 3; `rbtest/lib/main.dart` is left at `CODEPATCH-V4` (patch source), so a NEXT release from that tree would ship V4 as its baseline — restore V3 first if you want another OLD→NEW arm. Prior: **HELD** to build the code-changing patch; the device work is on the Mac. Prior: **free.** Lane D's arms ran here and passed. Left behind, deliberately: `/data/shorebird-engine/cli-under-test` (detached at `5a95c303`), `/data/shorebird-engine/g102-run/` (logs + a `token` file, mode 600), `rbtest` bumped to `1.7.0+1` with an `allowInsecureProtocol` opt-in appended to `android/build.gradle.kts` (backup at `/tmp/build.gradle.kts.bak`). The box's ORIGINAL `shorebird` checkout was not touched and still has its 4 uncommitted files. **Hermes is gone from this box — ~~`ENGINE_BUILD.md`'s co-tenancy rules are stale~~ DEBT PAID 2026-08-14: that section is re-audited, dated and corrected in place (`evidence/host/REAUDIT_2026-08-14.txt`).** The correction is not a deletion — the rules' *object* moved from a live service to 514 GB of the account's SSD backup, and the headline finding is that losing the co-tenant made the host **tighter**, not roomier: `/data` fell from ~410 GB free to **31 GB**, which blocked `gclient sync` (~40–60 GB, still never completed) on disk rather than on time. **RESOLVED the same day on the owner's instruction: the 514 GB was verified redundant and reclaimed — `/data` is now 376 GB free (22%), `/mnt/spare` 195 GB.** The premise inverted on inspection: `media_manifest.json` roots at `/Volumes/build/media`, so the SSD was the SOURCE and the VPS held the derived copy — the backup was already "on the SSD". Three checks preceded the delete and the third is the one that licensed it: the SSD holds 2055/2055 at exact size with 0 extras; 61 files / 19.4 GB md5-verified with 0 mismatches; and **0 files existed on the box that were absent from the SSD**. Free space was never the question — *is any byte here the only copy of itself* was. The SSD was re-verified AFTER the deletion too, since a check that runs only beforehand cannot catch a mistake made by the operation it authorised. Manifests kept on both devices, and copied to `/Volumes/build/media/.manifest/` so the sole surviving copy carries its own md5s (`evidence/host/SSD_BACKUP_RECLAIM_2026-08-14.txt`). The old liveness gate `systemctl is-active hermes-gateway` is marked vacuous rather than dropped — with the service absent it can only report success for the wrong reason. Prior: **HELD.** `ssh -i sshkey20.120.104.70.pem -p 13549 jewgo@20.120.104.70` (port 13549, user `jewgo` — **not** 22/azureuser; port 22 is filtered so the box looks dead if you assume defaults). **CO-TENANCY IS OVER: Hermes has been MOVED OFF this box** — `hermes-gateway.service` reads `Loaded: not-found`, `failed` since 2026-08-11, with 56 orphaned tasks still in its cgroup. `ENGINE_BUILD.md`'s "never touch `/data/hermes`" and the `-j2`/`-j3` co-tenancy cap are therefore **stale**; the box is ours. **Disk is the live constraint instead: `/data` is 93% full (35 GB of 503 GB free)**, `/data/ssd-backup` alone is 346 GB — owner says it may be moved or removed, NOT touched by this lane because the arms need only a few GB. Reverse tunnel verified: `cps-android` 403 and the CDN `android-arm64-release/linux-x64.zip` **200** from the box — the artifact that 404s on darwin, which is the whole reason these arms need Linux |
| `selfhost/fixtures/flavored_app` (no `R-id`) | — | — | released 2026-08-14 | **free. TREE HEALTH: GREEN** — `scripts/prepare_flavored_fixture.sh` now exists and is idempotent; `ios/` is overlaid and `xcodebuild -list` resolves all six flavored configurations and schemes `Foo`/`Bar`/`Runner`. **H2 step 7 PASSES on the host, all three arms** (`evidence/g42_flavored_fixture/h2_step7_host_arms.txt`): `--flavor foo` → `V1/Foo`, `--flavor bar` → `V1/Bar`, and no-flag → `V1/Foo` via pubspec `default-flavor`, each with its own bundle id. **Two findings, one of them load-bearing:** the plan's `grep -c 'V1/foo'` is wrong in CASE and returns 0 on a working fixture; and the cause is that iOS parses `FLUTTER_APP_FLAVOR` from the Xcode CONFIGURATION (`xcode_project.dart:385-388` returns the scheme's own casing), so the SHIPPED kernel gets `Foo` while `route_b_release_kernels.dart:134` threads the CLI token `foo` into the prepass — the same *different-program* shape `:2056` records this work as closing, with the key fixed and the VALUE still divergent on iOS. Not fixed here. Prior: **HELD.** Writing `scripts/prepare_flavored_fixture.sh` (absent) and then running step 7's host arms. Measured at claim: steps 5 and 6 are ALREADY DONE — `_resolvedFlavor` is at `ios_patcher.dart:766` and `g42_flavor_flow.sh` exits 0 saying both halves are closed — so the plan's remaining work is narrower than its text. `ios/` is the GENERATED tree (gitignored, 3 stock xcconfigs) and is NOT overlaid. Prior: **free. TREE HEALTH: GREEN** — committed at `41758dd3`; `xcodebuild -list` resolves all six flavored configurations and schemes `Bar`/`Foo`/`Runner`; the two `xcconfig`s are restored byte-exact to `41758dd3`'s content after a concurrent clobber. The generated `ios/`/`android/` are the pinned Flutter's (`c15ef637…`, verified byte-identical to a scratch regeneration, baseline `18152845…`) and are **not** overlaid — `prepare_flavored_fixture.sh` does not exist yet, so applying the overlay is still manual. **This row exists because the path had no `R-id` and therefore could not be claimed, which is exactly how two sessions took `H2` at once** — see the 2026-08-13 subsection above. Claim a path, not just an `R-id` |
| docs: `README.md` `compatibility.yaml` `UPSTREAM_INDEPENDENCE.md` `PARITY.md`§§17 (no `R-id`) | — | doc-alignment audit | released 2026-08-13 18:40 | **free.** Four stale blocks retired, each verified at its cited location per the correction rule; the audit that found them is a read-only sweep, so no code, fixture, device, cell or CDN state was touched. Row exists because these paths have no `R-id`: `PARITY.md` in particular is edited by nearly every lane, and the trap is that `git add selfhost/PARITY.md` sweeps a concurrent worker's in-flight rows into your commit. Checked before staging — the working-tree diff held only this lane's line. **Still owed, found by the same sweep and deliberately NOT taken here:** the two RED `shorebird_cli` CI gates (separate commit, crosses code this lane did not write), ~~patch `0008` cited as evidence at `:2279`/`:2346`/`:3137` while existing nowhere and double-claimed by `H3` and `H4`~~ — **RETRACTED 2026-08-13 by the lane that wrote it, before anyone acted on it.** It is false in both halves. `selfhost/engine/route_b/0008-g15-slim-arming-test-target.patch` **exists and is tracked**, committed by `13092e26` — the same commit that earned the 3/3 claim — so the evidence rests on a captured patch, not an uncommitted tree edit. And there is no double-claim: `selfhost/engine/` (`0002`-`0007`) and `selfhost/engine/route_b/` (`0001`-`0008`) are **separate series**, so `H4`'s proposed `selfhost/engine/0008-dart-load-obfuscation-map.patch` sits in the other namespace legitimately. **How it happened is the reusable part:** a single `find . -name '*0008*'` returned nothing and was believed. One negative command is not absence — the file is tracked, greppable and named in `13092e26`'s diffstat, and any of `git ls-files`, `ls` or reading the commit would have contradicted it. This is precisely §16's *"a negative grep is not coverage"*, committed by someone who had quoted that rule an hour earlier. The residual real finding is the INVERSE and is taken below: `H3:86` still says the patch "does not exist yet", `ENGINE_IMPROVEMENTS.md:18` claiming `experimental_hashes.map` has no active entries (it has **26**), and §17's paste-block saying "eleven" resources / `G1..G14` where §16 defines **twelve** and there are **fifteen** goals. **ALL FIVE ITEMS THIS ROW LEFT OWED ARE NOW CLOSED — verified at their cited locations 2026-08-14, and this note is added rather than the row deleted, because a reader who planned work off "still owed" needs to know it went.** The three residuals above were closed by `2e736555` (the same lane that found them, in the commit that retracted its own false finding): `H3:86` now reads "It EXISTS and is tracked as of `13092e26`", `ENGINE_IMPROVEMENTS.md:18` now records the active-entry count and the non-passthrough mirror — **27 as of 2026-08-14, not the 26 the finding named**, because this session's mint added one, and that line now tells the reader to re-run the command rather than trust the number, which is the right shape for a figure that moves with every mint. The paste-block now says "TWELVE contended resources" and `G1..G15`. The two RED `shorebird_cli` CI gates were repaired as their own commit, exactly as this row asked — see the `CI-gate repair` row at the bottom of this table (format and analyze both exit 0, suite 2413 pass / 1 skipped, unchanged from the pre-fix baseline) |
| `packages/shorebird_cli` — `lib/src/commands/patch/patch_command.dart`, `lib/src/shorebird_flutter.dart`, `lib/src/flutter_version_constraints.dart`, `lib/src/commands/release/ios_releaser.dart` + their tests; `selfhost/scripts/ci_noninteractive.sh`; `selfhost/fixtures/flavored_app/ios_overlay/BASELINE.txt`; `selfhost/evidence/g10.2-noninteractive/`, `selfhost/evidence/g42_flavored_fixture/` (no `R-id`; **`R7` is NOT taken** — no edit to `route_b_producer.dart` or `analyze_coverage.dart`, so `analysisVersion` stays 8) | — | `G4.3`/#3864 guard, `G10.2` lane D, `G4.2` flavor threading | released 2026-08-14 | **free. TREE HEALTH ON RELEASE: GREEN** — `dart analyze --fatal-warnings lib test` exit 0 (0 errors, 0 warnings), `dart format --set-exit-if-changed` 0 changed, `dart test` **2450 passed / 1 skipped / 0 failed**. All four lanes landed and COMPOSE; the suite is the evidence that they do. **Two defects existed only in the COMPOSITION and neither side's own verification could have caught them** — a clean cherry-pick is not a correct one. (i) The early import kernel passed `_resolvedFlavor` while the other three call sites passed `await _appleFlavor`; the merge was textually clean because the two changes touch different lines, and the result would have made `agreesWith()` disagree on any flavored release whose scheme casing differs from the typed token, falling back to prepass-only enumeration silently — reintroducing through the back door the exact defect the call site was added to close. (ii) The lane's tests were written against `createPatch(Patcher)` while main had moved to `List<Patcher>`: three analyzer errors. **The generalisable part: correctness lived in the AGREEMENT between two call sites, which no single diff contains** — so per-lane verification is necessarily blind to it, and only the composed tree can be asked. Prior claim note: **TREE HEALTH: GREEN at claim** — `1b84d829`, working tree clean at claim time. Four lanes' work sits in `.claude/worktrees/wf_88d81758-e2a-{1,3,4}` and is being repaired before it lands; nothing from them is in the shared tree yet. **This row exists because not writing it is what cost this batch real duplicated work.** An `h2-flavored` lane was fanned out onto `selfhost/scripts/prepare_flavored_fixture.sh` **without claiming the path**, and a concurrent session took the same order and landed it first (`647249ca` claiming, then `f7a9ef9f`) — two `prepare_flavored_fixture.sh` implementations, 244 lines theirs and 345 mine. **This is the FIFTH instance of the collision §17 already documents, and the first caused by an orchestrated fan-out rather than by two humans.** The generalisable part is new and worth more than the incident: **a git worktree is not a claim.** Worktree isolation is what kept the two efforts from corrupting each other's files, and it did **nothing** to prevent the duplication, because the duplication is a collision of INTENT and a worktree only partitions BYTES. The 2026-08-13 rule said "claim the PATH, before the first file exists"; the addition is that spawning parallel agents multiplies the number of unclaimed intents per unit time, so **the claim must be written before the fan-out, not by each lane inside it** — a lane cannot claim on its own behalf, since every lane in a batch starts simultaneously and each would read the table as clean. Their `f7a9ef9f` is treated as canonical here and only the coverage mine adds (`BASELINE.txt`, the wider arm matrix) is being salvaged |
| docs: `selfhost/plans/README.md` + four order files, `PARITY.md` §4/§17, `HANDOFF-2026-08-13.md` (no `R-id`) | — | doc reconciliation | released 2026-08-14 | **free.** Read-only sweep plus in-place corrections — no code, fixture, device, cell or CDN state touched, and no status was UPGRADED by this lane: every row it moved was moved to match a verdict another lane had already earned and recorded. **What it found:** `plans/README.md` had drifted **twelve commits** (last touched `2e736555`, before the whole `H4` mint / `G4.3` sequence), so the first file a fresh agent is told to read still listed `H4` as `NOT RUNNABLE`, `G3.7` and `G4.3` as "device owed", and recommended `H3` — already DONE — as a zero-hardware lane to start on. Four order files carried the same staleness in their `status` fields. §4's engine-gap row still said *"no mint has happened"*, which the `40eaa0ef` mint overtook; it is now version-scoped (closed for `40eaa0ef` and later, unchanged for `4df8f9b6` and earlier) rather than universal. §17's own "still owed" list named five items, **all five already closed** — three by `2e736555`, two by the CI-gate repair row below. `HANDOFF-2026-08-13.md` still said `H2` and `G6` were held by another session; both are free. **Every correction is in place and visible** — struck through or dated, never silently overwritten — per the correction rule, because a reader who acted on the old text needs to know it changed. **The generalisable part:** a work-order index is the one document whose staleness compounds, because it is what a worker reads *before* they know enough to doubt it — and the drift here was pure lag, not error, since each closing lane correctly updated `PARITY.md` and none of them updated the index that points at it. `git add` was per-path and the working tree held only this lane's edits — **with one exception that is itself the finding.** This lane's edit to `plans/H4-gen-snapshot-obfuscation-map.md` (the `status` field, `DONE — do not take it`) was **captured by a concurrent worker's commit `9d7bbacb`**, whose message describes a handoff plus two stale docs and never mentions the H4 plan at all, though its diffstat lists it. **Nothing was lost — the content is committed and correct — but that is the FOURTH instance of the swallow, and the first to occur AFTER the rule warning about it was written** (this section's rule 10, *"a commit message is not evidence of its own contents — `git show --stat` is"*). Two things it adds to the record. First, the swallowed file was a **status field**, landing in a commit that explicitly reasons *"PARITY.md was already updated in the commits that earned each claim, which is where status belongs"* — so a status change rode in under a message arguing it was elsewhere. Second, it was caught only because this lane re-ran `git status` before staging and noticed a file leave its own modified list; the tree had been clean at this lane's start, so the appearance of foreign edits was the tell. **The generalisable addition to rule 10: re-read `git status` immediately before staging, not only at the start** — a file that silently *leaves* your modified set has been committed by someone else, and that is indistinguishable from your edit never having been made |
| `packages/shorebird_cli` — `lib/src/commands/release/ios_releaser.dart`, `test/src/commands/patch/ios_patcher_test.dart` (no `R-id`; `R7` covers the producer, not these) | — | CI-gate repair | released 2026-08-13 18:55 | **free. TREE HEALTH: GREEN.** Both CI gates for `shorebird_cli` were **RED and fork-introduced**, and no document in the repo recorded it. `dart format --set-exit-if-changed .` failed on `ios_patcher_test.dart` from `177d0fbb` (2026-08-10); `dart analyze --fatal-warnings lib test` failed on `ios_releaser.dart:200` (`unnecessary_non_null_assertion` on `${ipa!.path}`) from `c57c6537` (2026-08-11). Both now exit 0; suite **2413 pass / 1 skipped**, identical to the pre-fix baseline, so the `!` removal is behaviour-neutral — `ipa` is promoted through the `final bool stale` whose initializer tests `ipa != null`, which is why the analyzer was right that the `!` did nothing. **The generalisable part is not the fix, it is why nobody saw it:** `HANDOFF.md`'s *Verifying your work* block ran `dart analyze lib test` and compared an INFO COUNT, while CI runs `--fatal-warnings` — a count cannot see a warning — and listed no format check for this package at all. A gate absent from the runbook is a gate nobody checks. That block now runs CI's own commands, cited to their workflow lines. Staged per-path; `packages/` was empty in `git status` before the edit and the window was kept short |
| `packages/shorebird_cli` — `lib/src/route_b_build_config.dart`, `lib/src/route_b_release_kernels.dart`, `lib/src/commands/release/ios_releaser.dart`, `lib/src/commands/patch/patch_command.dart` + their tests; `selfhost/engine/route_b/probes/g41b_define_from_file.sh`; `selfhost/evidence/g41-define-from-file/`; `PARITY.md` §4 Dart-defines rows (no `R-id`; **`R7` is NOT taken** — nothing here edits `route_b_producer.dart` or `analyze_coverage.dart`, so `analysisVersion` stays 8) | — | `G4.1` — `--dart-define-from-file` SUPPORTED rather than declined | released 2026-08-14 | **free. TREE HEALTH ON RELEASE: GREEN.** All three commits landed: `ad483fb1` (code + tests), `aeeb4375` (probe), `613365a4` (§4 rows + evidence). `git status --porcelain` empty at release. Probe **18/18**; suite **2486 passed / 2 skipped / 0 failed**; `dart analyze --fatal-warnings lib test` clean; `dart format --set-exit-if-changed` clean; cspell clean on the four new files, with six words added to the global config per `CLAUDE.md`'s >2-file rule. Worktree `/Users/mendell/shorebird-define-from-file` removed; both commits were CHERRY-PICKED in, so the shared tree never switched branches. **`~/.shorebird` was NOT re-synced** — nothing here was exercised through the rig, and the next lane to cut a release with this CLI owes that step. **No release was cut, so this earns BUILT and not PROVEN**; what is owed is a release built with `--dart-define-from-file` and a matching patch against it. **This row was absorbed into `c7834417` by a concurrent lane's stage at 17:37** — the swallow §17 documents, which that lane then moved to prevent (`939cd74d`). Nothing was lost. |

> **The rule has two precedents now, one in each direction.** A `G3.6a` read-only
> `R3` claim once outlived its holder and had to be cleared by someone else — the
> weakness flagged when this table was introduced. Then `G3.6e` held `R3`, `R7` and
> `R11` and **released all three on stopping**, mid-goal, with the reason recorded
> in each row rather than the row simply vanishing. That second form is the one to
> copy: **clear your row when you stop, even mid-goal, and say what state you left
> the resource in.**
>
> One unclaimed artifact is deliberately preserved rather than deleted:
> `scratchpad/wonderous-retention/` holds the interrupted cost run with its
> `provenance.txt` (app commit `747b945a`, lockfile and toolchain hashes, both
> interface hashes). It is not a claim on anything — it is a known-state starting
> point for when the §3 gate closes.

> ### A WRITE claim must report TREE HEALTH, not just ownership
>
> **This cost another session a mint, and the claims table as designed could not
> have prevented it.** While `G3.6e` held `R3` and was mid-edit, the Dart tree spent
> a window not compiling — `source_loader.dart` referenced
> `resolvePrivateNamesInLibrary` before `processed_options.dart` exposed it. The
> study session built against exactly that window, minted a cell, and had to void
> the baseline.
>
> The claim row said **HELD**. It did not say **BROKEN**, and those are different
> facts: "someone owns this" tells you not to edit, while "this does not currently
> compile" tells you not to *build*. A reader who correctly respected the claim by
> not editing could still lose work by reading.
>
> So a write claim now carries a **tree-health field**, and the holder updates it
> when the state changes:
>
> * **GREEN** — `dart_patches.sh --verify` passes, the changed sources analyze
>   without errors, and the affected artifact builds. Safe to build against.
> * **RED / mid-edit** — do not build, do not mint. Say so *while* it is true, not
>   afterwards.
>
> The peer's own row was right about the important half and wrong about the current
> state: 18 uncommitted files is the **documented baseline** of this tree, not a
> hazard — killgate, Route B step 1, the four `dart_patches.sh` patches, `0005`, and
> a stray `.DS_Store`. None of them are committed *by design*, which is why
> `dart_patches.sh` exists at all. The load-bearing part of that row — "does not
> compile" — was true when written and is not true now, which is precisely why the
> field has to be maintained rather than asserted once.

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

§16 lists the TWELVE contended resources (one phone per platform, one Route B
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
4. Pick a goal ID (G1..G15 — G15 is the activation model, and it is real) whose
   resources are unheld, and say which one you're
   taking before you start. The queue at the bottom of PARITY.md is priority
   order, not a schedule — §16 says what can actually run at once.
5. An uncommitted fixture version bump beside a fresh line in
   selfhost/cdn/experimental_hashes.map means a device gate is running RIGHT NOW.
   Back off R1, R3 and R6 until those changes are committed.
6. Never mark an item PROVEN from a host probe, a passing unit test, or a
   generated container. See "Rule for updating this file" at the bottom of
   PARITY.md. Host work earns BUILT.
7. DO NOT RUN `shorebird login`, and do not believe the CLI when it tells you to.
   This rig is SELF-HOSTED: the control plane is its own identity provider, there
   is no console.shorebird.dev here, and there is nothing to log in to. On stale
   credentials the CLI says "Try logging out ... and logging in again", and on a
   bad token it says "Create an API key at https://console.shorebird.dev" — both
   are inherited upstream text and both are WRONG on this rig. What is true: the
   CLI reads SHOREBIRD_TOKEN (an sb_api_... key), and OUR server issues those via
   POST /admin/users. The recipe, including how to use the bootstrap key without
   ever printing it, is selfhost/IDP_SETUP.md section 0. Read that before you
   spend a turn on authentication.
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

> **REORDERED 2026-08-14. `G15` crash-backout is now FIRST, and reach work is
> HELD behind it.** The numbering below is left as it was so earlier references
> still resolve; read this block as the live order.
>
> **THE NUMBERING ORDERS WHAT GATES THE DESIGN, NOT WHAT MUST RUN SERIALLY.**
> Read it as a dependency order, not a schedule — §16's distinction, applied to a
> chain that reads deceptively like a queue. **Gate 3 does not wait for gates 1–2:**
> it is host-only, needs no device and no mint, and contends only on `R3`, while
> gates 1–2 need the fixture and `R1`. Running it in parallel is strictly better
> than leaving the delivery premise unmeasured while the fixture is repaired —
> and if it FAILS, it invalidates the `_runMain` candidate outright, which is
> worth learning before a device cycle is spent on gates 1–2's behalf.
>
> **The one hard boundary is before gate 4.** Seam design may not begin until 1,
> 2 and 3 are all established: 1–2 give an instrument that can produce an
> admissible result, 3 gives a delivery path the design is allowed to assume.
>
> | # | item | state |
> |---|---|---|
> | **1** | **`G15` fixture repair** — `killswitch_probe`'s alternating marker must move on an UNPATCHED release. **THE INVARIANT, not just the outcome: the fixture must keep a PER-LAUNCH EXECUTION RECEIPT THAT IS INDEPENDENT OF RENDERING.** The marker is no longer incidental instrumentation — it is the only thing that separates *user Dart never ran* / *ran and failed* / *ran and rendered*, and it separates them because it is a RECEIPT rather than a RENDERING. It survives `SIGKILL`, which a screen does not. **A repair that restores the screen while weakening the receipt makes every later `G15` arm less trustworthy than the arms this session voided** — the blank screen was readable as three different states at once, which is exactly how the retracted attribution was manufactured. **SHARPENED 2026-08-14 by measurement, and the fault is now located: the receipt must be independent of THE PATCH TARGET as well as of rendering.** `6d00e95c` put `bootMark = bootProbe();` ahead of the marker write, so the receipt sits BEHIND the very function arm B exists to make throw — on the arm where the receipt matters most it can never move. Consequently *"`main()` DID NOT RUN… not at all"* is **OVERSTATED**: an unmoved marker on `1.0.3+1` is equally consistent with `main()` entering and dying on its first statement. Repair = receipt on the FIRST line of `main()`, ahead of every patchable call, recording phases separately instead of toggling one bit | **BLOCKING. Until it passes, no crash-backout device result is admissible** |
> | **2** | **`G15` clean-release control** — unpatched release → marker moves → expected UI (`boot-ok` / `OLD-kill`) | restores attribution capability; the run on 2026-08-14 could not. **THE SEARCH SPACE IS NOW NARROW, measured device-free from the stored artifacts:** every `killswitch_probe` release (rel 89–92) carries the SAME engine, cell `80e493e4` — compared by `__TEXT,__text` section bytes, because an embedded `Flutter` is re-signed and thinned so file hashes never match. `airgap_probe` (rel 87), the positive control, carries `40eaa0ef` — **so that control never covered the engine.** But `arm2_verdict.txt`'s PASS ran on `1.0.2+1`, i.e. on `80e493e4` too, where `main()` demonstrably ran and alternated the marker — **so the engine is EXONERATED by a control that was already in the evidence directory.** `1.0.2+1` works and `1.0.3+1` does not on the same engine, same device, same fixture; the only delta is `6d00e95c` (`boot-ok` occurs 0× in rel 89/90/91's AOT and 1× in rel 92's). Evidence: `evidence/g15/killswitch_engine_identity.txt` |
> | **3** | ~~**`G15` delivery proof** — show a uniquely greppable marker placed in `hooks.dart` reaches the **built release's** kernel/AOT~~ **ANSWERED 2026-08-14, AND IT FAILS — no engine build, no mint, no device.** An edit to `R3`'s `lib/ui/hooks.dart` **cannot** reach a built release's AOT. `dart:ui` enters an app snapshot through `flutter_patched_sdk_product/platform_strong.dill` (`artifacts.dart:757`/`:1323` select it for `BuildMode.release`), and `publish_ios_overlay.sh:193` publishes that zip from **`R4`'s `out/host_release_arm64_nodm`** — deliberately, because `R3`'s host dill fails the iOS AOT step. `mint_route_b_cell.sh:127` APFS-clones the donor cell, so **all three published cells carry the byte-identical dill** (`55e02ed8…`, `attachBytecodeToFunction` ×0) while `R3`'s own is `9f5a5f75…` (×8). **The sharp part:** `R3`'s dill is one of the seven files that COMPUTE the cell hash (`mint_route_b_cell.sh:31,68`), so the address certifies one dill while the download delivers another, and `audit_route_b_compiler.sh:76,86` checks it only inside the compiler bundle — which is why every cell audits CLEAN with the halves disagreeing. Same shape as the `sky_engine` stock-sources hole, one level down. Evidence: `evidence/g15/hooks_delivery_verdict.txt` | **BLOCKING for step 4, and the repair is a PUBLICATION repair, not a seam redesign.** `_runMain` is NOT refuted structurally — `_runMain@34065589` is present in rel 92's `App.framework` — it is refuted as DELIVERABLE from the tree that owns the seam |
> | **3a** | **`G15` delivery repair** — publish the platform dill from the same tree as the iOS engine (or fail loudly when they disagree), and add the missing audit check: the published `flutter_patched_sdk_product.zip` must contain the dill the cell hash was computed over | one byte comparison closes a hole two sessions have now walked into. Only after this can step 3's marker test mean anything |
> | **4** | **`G15` seam** — build and prove the `_runMain` wrapper candidate, answering the same four questions of whatever fallback the non-returning-`main` case needs | the C++ `OnHandleMessage` seam FAILED three of the four; see the plan. **Now additionally gated on 3a:** the seam's Dart half (`dart:ui`) and native half (C++ reporter) would otherwise ship from two trees nothing holds in agreement |
> | **5** | **`G15` three-arm hardware gate** — good→success, throw→positive failure + backout, kill-before-signal→retry (re-earning `0010` at the later seam) | same repaired fixture and instrument; **every arm asserts marker movement before UI is read** |
> | 5+ | `G3.6e`, `G3.7`, static-vs-instance widening | **HELD.** They increase what can be patched; `G15` determines whether a failed patch can be told from a good one |
>
> **Rationale, restated because the old one no longer holds:** the current
> success-accounting seam is source-proven incapable of observing user Dart
> execution, so there is no validated way to distinguish a booted patch from a
> Dart-phase failure. The previously claimed brick/reinstall severity is
> **suspended pending fixture repair and remeasurement** and is no longer part of
> the argument.

1. ~~**`G3.6c` + `G3.6d` device gate**~~ — **DONE 2026-08-13.** Release `32.0.0+1`
   patch 1: a method on the private class `_ProbeBodyState` patched on device,
   `OLD-pc` → `NEW-PC`. No mint was needed; the published cell already carried the
   `G3.6d` generator. It did need a new RELEASE, because the private class has to
   exist in the release bytes — "rides an existing release" was wrong about that,
   and it is the only part of the estimate that missed.
2. ~~**`G3.6e resolve-in-library`**~~ — **CLOSED 2026-08-13 BY PRIORITY 1's RUN, for
   a private field read.** No separate device gate was needed: `G3.6b` and `G3.6e`
   are the same code path approached from opposite ends, so release 31 patch 2
   proved both at once. The queue had them as two items with two device gates; one
   run closed both, and the only thing still host-only is a private
   METHOD-or-GETTER call, which is what the release-32 patch 2 arm below tests.

   ##### The private-CALL arm — outcomes precommitted, 2026-08-13
   Release 31 proved a private FIELD read. A private getter is a `Procedure`, keyed
   `get:_name` rather than bare, and `G3.6d`'s table lists that shape as emitted and
   annotated but it has never run on a device. Release 32 already carries private
   getters on a private class (`_codePatch`, `_assetsPatch` on `_ProbeBodyState`), so
   this rides release 32 as patch 2 — **no new release, no mint**.

   Patch body: `String privateClassValue() => _codePatch;`

   | observation | meaning |
   |---|---|
   | private-class row shows the patch number (`2`) | a private GETTER call from a patch works on device. `G3.6e` extends from field reads to procedures, and `G3.6d`'s `get:` keying is proven rather than merely emitted |
   | the CLI refuses, naming `get:_codePatch` | the manifest did not grant the getter. A producer/retention result, NOT a device result — read the release's `route_b_capabilities.json` |
   | container refuses at attach and rolls back | the getter was granted but not retained: the `get:` key does not reach `PruneDictionaries` the way the bare field key does. That is a real finding about `G3.6d`'s keying, and the one outcome worth the run even though it fails |
   | row still shows `OLD-pc` with `code patch: 2` | attach succeeded and the getter did not execute; inspect before assuming, because the field-read path is known good on this exact release |

   **RAN 2026-08-13 — row 1. The private-class row showed `2`, code patch 2**, from
   `privateClassValue(dynamic self) => self._codePatch`, 851 B, bytecode size 19.
   Grants recorded in `evidence/releases/32/patch2.capabilities.json`:
   `get:_codePatch` and `get:_assetsPatch` under policy `p2`, `refused: 0`.

   **The displayed value is runtime data, not a constant.** `_codePatch` returns
   `widget.runtime.patchNumber?.toString()`, so the interpreted body traversed
   `self → widget → runtime → patchNumber → toString()` inside the release's live
   object graph. It is reachable from neither neighbouring state — the release body
   returns `OLD-pc` and patch 1 returned `NEW-PC` — so `2` cannot be a stale value or
   a baked-in one. That makes it a stronger execution proof than any literal.

   So `G3.6d`'s `get:` keying is now executed rather than merely emitted, and
   `G3.6e` extends from fields to procedures. **A private METHOD call taking
   arguments is still host-only**: a getter is a `Procedure`, so the same resolution
   and keying path is exercised, but "the same path is very likely" is not a
   measurement.

3. **`G3.6e` (superseded numbering, kept so later references still resolve)** — the highest-leverage language work. Privacy is
   the strongest measured blocker from **both** directions: structural reach
   (→29.8 %) and Phase 0's real commits (top blocker in 9 of 10). Feasibility is
   established and the mechanism is located.
3. **`G3.7 param-abi`** — **ONE-PARAMETER ARM PROVEN ON DEVICE 2026-08-13; the
   gate stays OPEN.** Release 37, patch 1: `param=PARAM-ARG` with `code_patch=1`,
   reproduced on an independent third launch, from the preserved release bytes
   (`31869a1e…`) under a launch-time identity refusal — and the engine's own
   diagnostic names the selector, `sel=RouteBThing.paramValue`, `bc_pre=0 →
   bc_post=1`, `unchecked_entry_point_` moved to `InterpretCall`. Banked claim,
   verbatim from `evidence/releases/37/verdict.txt`: **the live caller's SOLE
   POSITIONAL String argument is transferred into the interpreted replacement and is
   observable by the replacement body.** NOT banked: argument **order** — with one
   parameter there is none to get wrong, so ordering still rests on the host
   `two_params` arm — and not `named`/`opt`, whose refusal controls have no live
   fixture shapes. Three of the four arms this gate names are therefore still host-only.
   Prior state, kept because the distinction is the point:
   **BUILT on host 2026-08-13, device gate outstanding.**
   Measured separately from privacy exactly as this line required, and the two were
   never credited to each other: privacy closed on device via releases 31–32, and
   this closed on host via `g37_param_abi.sh` with its own release and its own
   controls. What remains is a mint, because the contract lives in
   `dart2bytecode.aot` inside the cell — so it should ride the next mint that
   happens for another reason rather than paying for one alone.
4. **`G15 activation-model`** — the highest-leverage safety/reliability project
   after language reach.
   **CRASH-BACKOUT UPDATED 2026-08-14 — the defect is now CERTAIN and its
   CONSEQUENCE is now UNMEASURED, which pull in opposite directions and should be
   weighed as two facts, not one.** Certain: `main` is posted to the message queue
   by `_delayEntrypointInvocation`, so `Engine::Run` returns before any user Dart
   runs and `0009`'s seam cannot see a Dart-phase failure *in principle* — read
   from source, no device needed. Unmeasured: the claim that a bad patch **bricks
   the install** is retracted, because the fixture it rested on does not execute
   `main()` at all and shows the same blank screen with no patch installed; the
   `--rmtree` "rescue" it cites did not in fact rescue anything. The next seam is
   located (`tonic::DartMessageHandler::OnHandleMessage` — first turn banks
   success, `UnhandledError` positively reports failure) and is the only candidate
   meeting all three requirements at once; see
   `plans/G15-crash-backout-and-restart-required.md`. **Fixture repair is a
   precondition**, and every arm must assert the liveness marker moved before the
   screen is read. Prior state below.
   **PARTIALLY ADVANCED 2026-08-13**: the severe symptom (a
   second engine in one process running unpatched AOT) had its mechanism corrected
   from source and fixed by a one-statement move, patch `0007` — arming sat below an
   early return gated on an updater init that deliberately fails on its second call.
   **`0007` IS NOW HOST-TESTED, NOT MERELY COMPILE-VERIFIED — 2026-08-13.** Its three
   arming tests had never executed: `shorebird_unittests` also compiles
   `patch_cache_unittests.cc` and deps `//flutter/runtime/shorebird:patch_cache`,
   whose `patch_cache.cc` calls `Shorebird_ReadLinkHeader` — a symbol only
   Shorebird's private Dart fork defines — so the tree held an object file and **no
   linked binary**. A slim sibling target carrying `shorebird_unittests.cc` alone
   (patch `0008`) links at 257/257 and reports `[ PASSED ] 3 tests`:
   `RouteBArmingIsInertWithoutAPatch`, `RouteBArmingInstallsACallbackForAPatch`,
   `RouteBArmingChainsAnExistingCallback`. Dropping the dep is legitimate rather than
   a workaround, and the link is the proof: `//flutter/runtime` gates patch_cache on
   `shorebird_use_interpreter` (`is_ios`, unset in this host `args.gn`), so the
   symbol is genuinely unneeded — which also rules out the precommitted alternative
   that it arrives through `//flutter/runtime` anyway and the tests must move to the
   shipping iOS tree. **This says NOTHING about two engines** — but that host now EXISTS.
   **EXPERIMENT B, MEASURED 2026-08-13:** `selfhost/fixtures/twoengine_app` puts two
   independently constructed `FlutterEngine`s in one process, and every precommitted
   condition was observed SEPARATELY (`evidence/g15/`): `implicit_engine=0` (no third
   engine — the tripwire never fired), `projects_distinct=1` with differing
   identities, `engines_constructed=2 engine_one_run=1 engine_two_run=1`, two Dart
   markers differing byte-wise, and each entrypoint logged exactly once
   (`isolate=main` / `isolate=engineTwoMain`). Stock Flutter 3.44.8 on a simulator,
   deliberately: the host itself records `arming_observed=0
   reason=stock_engine_simulator_structural_only`, so this is the missing
   PRECONDITION and **must never be reported as a `G15` result**. It is independent
   of the unit tests above in BOTH directions — a simulator failure would not
   invalidate them, and 3/3 passing says nothing about second-engine behaviour.
   Two shapes are refused rather than interpreted, because each would look green: a
   third implicit engine (`UIMainStoryboardFile` deleted, plus a tripwire that shows
   a refusal screen and constructs nothing), and a shared `FlutterDartProject`
   (which hands engine two an already-armed callback, so it would run patched code
   even without `0007`) — with **no fallback** retrying the shared shape.
   `probes/g15_two_engine.sh` guards it at 16/16 and its header says it is a
   regression guard, not arming evidence.
   **Still open for `G15`:** a release cut against cell `4df8f9b6` with this harness,
   on our engine. And one fact recorded before it can mislead — both engines append
   to ONE `.routeb` file, so the discriminator is the sibling `.routeb.trace`
   (release 32's carries exactly one `rbtrace` line; two attaches should give two,
   and identical `fn=` values would be something to investigate, not an automatic
   failure).
   Two stale clauses corrected while here: the tests are no longer "unrunnable in
   this tree", and the device gate no longer "needs a mint" — cell
   `4df8f9b6139b67d2cfe9f6aa8212372cade36278` carries the iOS donor with `0007`.
   **It was NOT one redesign: it is two mechanisms.** The crash-backout and
   restart-required symptoms share `ReportLaunchSuccess` firing in the `Shell`
   constructor and are untouched by `0007`.
5. **§13 independence gates** — matters for the strength of the self-hosting claim,
   but does **not** currently constrain Route B's language capability. That is why
   it sits below a safety project despite being nearly done.

### The next session is ONE MINT carrying THREE INDEPENDENT GATES — precommitted 2026-08-13

Written before the cycle is spent, because the expensive resource is no longer
unresolved design: it is the mint/device cycle. Four surfaces are already built and
each is owed only a device verdict, and three of them depend on the same cell.

**What the mint must contain, and why each piece is in it.** Nothing goes in for
tidiness; each artifact is there because a gate's semantics depend on it.

| artifact | why it must be re-minted | gate that needs it |
|---|---|---|
| `dart2bytecode.aot` | carries patch `0006`, the entry-point contract widened to any number of REQUIRED positionals | `G3.7` |
| `route_b_analyze.aot` | `analysisVersion` 8: parameterised targets are no longer `unsupported`, and the CLI's pin already moved | `G3.7` |
| the iOS engine | patch `0007`, arming moved above the `!init_result` return | `G15` |
| `route_b_gen_dynamic_interface.aot` | already carries `G3.6d`; re-minted only because the cell is one immutable unit | — |

The iOS engine build is the long pole and is the reason this is a session boundary
rather than a step: `build_ios_release.sh`, detached, `screen -dmS routebios bash -c
'caffeinate -is /Volumes/build/route-b/build_ios_release.sh'`.

**Cell identity is established ONCE, then never re-argued.** Record the engine hash,
the per-artifact sha256s from `PROVENANCE.txt`, `assert_diagnostic_engine.sh` (the
trace sentinel and `InterpretCall` must both be present in the SHIPPED binary), and
`audit_route_b_compiler.sh` (reconstructibility, not presence). Publish, then
`audit_overlay.sh` for the new hash — and note that `route-b-compiler-*.zip` is now
protected hash-generically, so a missing cell 404s instead of silently serving the
pinned hash's bytes.

**INDEPENDENCE OF INTERPRETATION IS THE RULE.** The gates share a toolchain
specimen; they do not share a verdict. A failure in one must not contaminate the
others, and the mechanism is that each gate gets its own preconditions, its own
preserved specimen, and its own recorded verdict referencing the one cell identity:

| gate | preconditions of its own | specimen | verdict is about |
|---|---|---|---|
| `G3.7` param-abi | release cut with the new cell; `assert_result_consumed.sh` on the target's call site | `evidence/releases/<n>/` + the lowered replacement showing `(Self self, T a)` | whether the AOT caller's ARGUMENTS arrive, in order and by type, in an interpreted body |
| `G3.7` remaining shapes — **ALL THREE SETTLED ON DEVICE 2026-08-13** | release 38 (`fdc0a84c…`, 7,156 sites / 1,778 per MB, App+dSYM+ipa preserved before any patch). **`two`: PASS** — baseline `two=OLD-a-7` on the release's own bytes, patched `two=PARAM-a-7` with `code_patch=1`. Arguments arrive IN ORDER and keep their TYPES; a transposition would read `PARAM-7-a`. Lowered `String two(RouteBThing self, String a, int b)`. **`named`: REFUSED** *"the method takes named parameters"*. **`opt`: REFUSED** *"the method takes optional positional parameters"* — both exit 70, no patch, no container | `evidence/releases/38/verdict.txt` | **G3.7 IS NOW COMPLETE**: one (r37) + two + named + opt. The analyzer refuses exactly what the compiler refuses, and both accepted shapes behave as declared. The controls held — `param=OLD-ARG` did NOT move while `two` changed, which is a sibling method on the same class and therefore the sharpest available check that this is a per-method replacement rather than a whole-app swap. And both refusals cited the PARAMETER SHAPE, not "not in the interface" — the precommitted wrong-reason failure, prevented by the dead-branch retention in `value()` |
| `G3.7` remaining shapes — superseded row: **SPECIMENS BUILT 2026-08-13, NOT RUN** | `airgap_app` now carries `two(String a, int b)` LIVE (called as `two('a', 7)`, result displayed AND beaconed) plus `named({String x})` and `opt(String a, [String b])` as refusal controls with no live call site, named in `value()`'s dead branch so the `--aot` prepass cannot shake them out. Bodies copied verbatim from `g37_param_abi.sh`'s `R_TWO`/`R_NAMED`/`R_OPT`, so the device specimen and the host arm are the same program | needs `R6`/`R8` + a device: a re-cut carrying these shapes, then one patch per arm | **PRECOMMITTED.** `two` → `PARAM-a-7` proves arguments arrive IN ORDER and keep their types (`int` 7 in slot `b`); a transposition renders `PARAM-7-a`, which is visibly wrong rather than merely different. `named` → CLI refusal naming *"the method takes named parameters"*; `opt` → *"the method takes optional positional parameters"*. For both controls the evidence is the log AND THE ABSENCE OF A CONTAINER — an arm that reaches the device has already failed. A refusal citing "not in the interface" is the WRONG REASON and counts as a failure, not a pass |
| `G3.7` one-param arm — **MET 2026-08-13** | release 37 + patch 1, launched under `launch_release_bytes.sh`'s identity refusal | `evidence/releases/37/verdict.txt`, `patch1_replacement_0.dart` showing `(RouteBThing self, String who)`, `patch1.routeb.trace` | whether ONE positional argument arrives and is observable. Order is NOT in this verdict: one argument cannot demonstrate it |
| `G15` second engine | ~~a host that creates TWO `FlutterEngine`s in one process — the fixture as it stands creates one~~ — **SATISFIED 2026-08-13**: `fixtures/twoengine_app`, structurally proven at `evidence/g15/`. What remains is `R6`/`R8` + a device and a release cut against cell `4df8f9b6` | ~~both engines' `.routeb` reports~~ — **there is only ONE report.** `RouteBReport` appends to `artifact_path + ".routeb"` and both engines resolve the same lifecycle-selected path, so the specimen is the sibling **`.routeb.trace`**, one `rbtrace` line per attach | whether engine two is armed at all |

**PRECOMMITTED DEVICE VERDICT for `G15`'s final gate — written before it is booked,
so the booking cannot shape the reading.** The discriminator is the trace's LINE
COUNT plus per-line target evidence; neither the shared `.routeb` file nor generic
process success counts as either.

| observation | verdict |
|---|---|
| two independently attributable engine launches AND two `rbtrace` records after activation, each showing the expected attach/arming transition (`bc_pre=0 → bc_post=1`, `uep_post_is_interpret_call=1`) | **`G15` PASS** — both engines arm on the shipping engine |
| fewer than two traces | **`G15` FAILURE or INCOMPLETE OBSERVATION, and which one depends on WHICH engine's evidence is missing.** A trace absent for engine two with engine two proven launched is a failure; a trace absent because engine two never booted is an incomplete observation and not a `G15` result. The launch attribution is what separates them, which is why the harness makes it a file-system fact |
| two traces whose `fn=` values are identical | **INVESTIGATE, not an automatic failure.** Each engine has its own isolate and heap-allocated `Function`, so differing `fn=` is the PREDICTION — never measured. Identical values could equally mean the instrument reported one engine twice |
| two traces but an attach transition missing on one | that engine did not arm: a `G15` failure localised to it, which is the outcome the whole per-engine attribution exists to make sayable |
| the process merely launches and shows patched behaviour somewhere | **NOT a `G15` result.** "Some engine ran patched code" is the reading this gate exists to make impossible |

The simulator probe stays labelled exactly as it is: **shape proof, not arming
proof.**

> **`G15`'s FINAL DEVICE GATE: PASS — 2026-08-13.** Both engines in one process arm
> Route B on the shipping engine. Every precommitted row met, on cell `4df8f9b6…`
> untouched. Verdict: `evidence/releases/twoengine-2/verdict.txt`.

```
engine=one  isolate=main          entrypoint=main          mark=MARK-PATCHED
engine=two  isolate=engineTwoMain entrypoint=engineTwoMain mark=MARK-PATCHED
2 rbtrace records, both sel=engineMark, both bc_pre=0 -> bc_post=1,
  uep_post_is_interpret_call=1, fn_uep_post == interpret_call_ep (0x102f20044)
fn= 0x1038cbdf1  vs  0x10794bdf1     <- DISTINCT, as predicted
2 records after the gate launch -> 4 after one MORE launch (+2 per launch)
patch1.routeb    8 -> 16 lines, NO engine discriminator  <- why the trace is the specimen
```

**THE INCREMENT IS THE EVIDENCE, NOT THE COUNT.** `RouteBReport` appends, so two
records are equally consistent with ONE attach per launch across two launches. The
absolute count did not exclude that and the first reading of this gate did not say
so; a challenge did. `+2 per launch` is what shows two attaches in one process.

**A HARNESS DEFECT, ROOT-CAUSED AND FIXED SAME DAY, which did not affect the
verdict:** engine one's UI rendered black during a live launch. Cause: the app was
SCENE-based — `flutter create` emits `UIApplicationSceneManifest` naming a
`SceneDelegate` *and a second storyboard reference*, and when a scene manifest exists
the SCENE owns the window, so the host's `window` assignment is ignored. Deleting
`UIMainStoryboardFile` had removed only one of the two storyboard routes. The prepare
script now deletes the manifest as well; the indigo `ENGINE one` screen renders, both
engines still boot, and `implicit_engine=0` holds more strongly than before, since
that scene config was the last route to an implicit engine.

The verdict never depended on it: markers are written by Dart before `runApp` and
`rbtrace` by the engine at `AttachBytecode`, and `mark=` is the patched body's return
VALUE.

Patch `0007` is therefore proven on hardware: the pre-fix symptom was engine two
silently running unpatched AOT, because arming sat below an early return gated on an
updater init that deliberately fails its second call. Two records with two distinct
heap-allocated `Function`s is that path executing twice. The mechanism now holds at
three independent layers — `0008`'s executing unit tests, the structural harness
(stock Flutter, `arming_observed=0` by construction), and this gate.

The `fn=` "investigate" branch was not entered, and the shared-report prediction was
confirmed: reading "one report" as "one engine armed" would have been wrong twice.

**Still open in `G15`'s wider project:** crash-backout and restart-required (§14b's
other two symptoms) share `ReportLaunchSuccess` in the `Shell` constructor and are
untouched by `0007` or by this gate.

> **BOTH SYMPTOMS ATTACKED 2026-08-14, ONE CLOSED AND ONE MEASURED FAILING.** Cell
> `80e493e4` carries patch `0009` (bank launch success when `Engine::Run` returns,
> not in the `Shell` constructor) and `0010` (retry below a boot-attempt threshold
> instead of tombstoning on a single un-succeeded boot).
>
> **The false-backout arm PASSES on device, twice.** A GOOD patch killed inside the
> success window stayed `Installed` and ran: `route B value: NEW-kill` after each
> kill, corroborated by the device's own `patches/1/state.json` (`Installed`, not
> `Bad{BootCrash}`), `last_booted_patch: 1`, and an EMPTY `queued_events`. The
> `boot_attempt_count` / `last_boot_attempt_patch` fields exist in that device's
> `pointers.json` at all only because `0010` added them, which is independent proof
> of which engine ran. `evidence/g15/arm2_verdict.txt`.
>
> **Crash-backout FAILS, and `0009`'s seam is the reason.** `Engine::Run` returns
> `Success` when the entrypoint is INVOKED, regardless of what the isolate then does,
> so a patch throwing inside `main()` banked three successes while crashing every
> launch. `0009` is strictly better than the constructor and still not far enough.
> `evidence/g15/crashbackout_verdict.txt`.
>
> **One decision to re-open rather than inherit:** first-frame was refuted as the
> seam because it widens the false-backout window — correct at the time, and that
> risk is now MITIGATED by `0010`'s counter, which did not exist when the objection
> was made. Re-examine it rather than treating it as settled.
>
> **THE CONSEQUENCE IS BLOCKING, AND IT IS MEASURED: A BAD PATCH BRICKS THE INSTALL.**
> With crash-backout not firing, the client never removes a patch that breaks Dart —
> and **the server cannot rescue it either.** The crashing patch was withdrawn with
> `rollback=true` and acknowledged (`{"withdrawn":true,"rolled_back":true}`), and the
> app still crashed on every launch afterwards, because withdrawal only reaches a
> device that lives long enough to POLL and this one dies inside `main()`. The install
> stayed in a permanent crash loop until its updater state was wiped over USB
> (`ios-deploy --rmtree "/Library/Application Support/shorebird"`). **A real user has
> no equivalent: the app is dead until they delete and reinstall it, losing local
> data.** So this is not an outstanding nice-to-have — it is the only thing standing
> between a bad patch and a bricked install, and §7/§13's shipping questions should
> treat it as the blocking item.

**THE SHARED BOOKING CARRIES TWO INDEPENDENT PAYLOADS** — `G3.7`'s remaining
parameter-shape arms and this gate — with **separate releases, specimens and
verdicts**. One release may never stand in for both: they are different fixtures.
Four prerequisites, checked 2026-08-13 so the device is not the place they surface:

1. **`twoengine_app` HAS NO APP ON THE CONTROL PLANE.** Its `shorebird.yaml` reads
   `app_id: REPLACE-ME`. Creating one is an `R8` write, then re-run
   `prepare_twoengine_fixture.sh --app-id <id> --base-url http://<lan>:18080`.
2. **Its `ios/` TREE WAS GENERATED BY STOCK FLUTTER 3.44.8, ON PURPOSE**, so
   experiment B's structural claim could not be confounded by our engine. A Route B
   release must not silently mix generators: re-materialize with the pinned Flutter
   before the release — `prepare_twoengine_fixture.sh --flutter
   ~/.shorebird/bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98/bin/flutter`
   — and re-check the warm-cache precondition, because `isRouteBEngine` returns
   false when the `ios-release` Flutter binary does not yet EXIST and the release
   then takes the non-Route-B path while reporting success (release 33).
3. **`airgap_app` must bump `pubspec.yaml:9` from `37.0.0+1`** before its re-cut;
   the control plane rejects a duplicate release version.
4. **`preserve_release_evidence.sh` must run for EACH release before its first patch
   build**, or the patch build overwrites the archive AND its dSYM. It now preserves
   the dSYM too and rejects one whose UUID does not match the App's.

**HARDWARE-INDEPENDENT PREREQUISITES: DONE 2026-08-13.** Prerequisite 1 (the `R8`
app creation) is deliberately left for the booked session, because it is actual
shared-state mutation.

* **2 — `twoengine_app/ios` re-materialized with the PINNED Flutter**
  (`c15ef6379…`, itself 3.44.8, revision `c15ef63794`). Checked first, because the
  overlay conforms to `FlutterImplicitEngineDelegate` and a pin without that
  protocol would not compile: it IS present, in the pinned embedder's
  `FlutterEngine.h`. After re-materializing, the shape holds — 2 engine
  constructions, `UIMainStoryboardFile` absent, `NSAllowsLocalNetworking` present.
  **Experiment B's structural claim still rests on the STOCK-generated evidence at
  `evidence/g15/`, and must not be re-run against this tree**: the pinned Flutter's
  `engine.version` IS the cell, so a simulator run here would no longer be the
  unconfounded structural experiment.
* **3 — the Route B engine path is provably active.** `isRouteBEngine` is exactly
  "the binary exists AND its raw bytes contain the ASCII `InterpretCall`"
  (`route_b.dart:29-34`), so it was evaluated identically rather than assumed:
  `engine.version` `4df8f9b6…`; the `ios-release` cache warm (4 entries); the
  Flutter binary present at 19,071,568 bytes with sha `e828f8efeb623d1d…` — the
  cell's own engine; `InterpretCall` PRESENT ⇒ **`isRouteBEngine == true`**.
* **4 — `airgap_app` bumped `37.0.0+1` → `38.0.0+1`.**

**RELEASE-LEVEL INVARIANTS for the booking, not setup notes:**

1. Each release gets its own preserved `App` + dSYM **before any patch build**.
2. `twoengine_app` must carry a real control-plane `app_id` before its release.
3. **A successful `shorebird release` is NOT evidence of Route B** unless the
   precondition above proved the Route B engine path was active. Release 33 exited
   0 and was worthless.

**WHAT ACTUALLY NEEDS THE PHONE — scheduling, not semantics.** Two of the four
`G3.7` arms have a success condition that occurs BEFORE device execution, so running
them inside the contended window spends the scarce resource on nothing.

| phone REQUIRED | why |
|---|---|
| `G15` final two-engine device gate | two `rbtrace` records on the shipping engine; only a real launch produces them |
| `G3.7` `two(String a, int b)` behavioural arm | require **`PARAM-a-7`** on the preserved release-38 binary. `PARAM-7-a` would be a transposition, which is the point of the literals |

| phone NOT required, once release 38 EXISTS | why |
|---|---|
| `named({String x})` refusal | proves **CLI refusal + NO container**. Expected: *"the method takes named parameters"* |
| `opt(String a, [String b])` refusal | proves **CLI refusal + NO container**. Expected: *"the method takes optional positional parameters"* |

For both controls, **reaching the device invalidates the arm** — a container that
exists at all means the analyzer did not refuse. And a refusal citing *"not in the
interface"* is the WRONG REASON and counts as a failure, which is what the
dead-branch retention in `value()` exists to prevent.

> **Cut and preserve release 38 while the device is available, but DEFER the two
> refusal controls until after the phone is released.**

So the contended window holds exactly three things: the `R8` app creation, the
`G15` gate, and `G3.7`'s `two` arm — plus both release cuts, which must happen there
because the refusal arms need release 38 to patch against.

Cell `4df8f9b6…` untouched throughout.

That last clause is the operative one and it is not housekeeping. This gate's whole
interpretation is built on immutable cell `4df8f9b6139b67d2cfe9f6aa8212372cade36278`
— the specimen, the trace schema, the arming patch `0007`, and the precommitted
verdict above all refer to it. `--load-obfuscation-map` is the next mint boundary
(the only remaining prerequisite that changes engine/toolchain semantics), and
opening it before this booking would mix a new engine lineage into a gate designed
around that one. Anything arriving from a different lineage is a different
experiment, whatever the trace says.
| `G4.2`/`G4.3` config | release cut WITH a flavor and WITH `--obfuscate`; provenance carrying the fingerprint | the release's `buildConfig` + each arm's CLI log or device beacon | two different claims, split below |

**`G3.7` and `G15` are independent in both directions.** `G3.7` is a producer/ABI
question answered by a patch that executes; `G15` is a runtime arming question
answered by a second engine's report. Neither can explain the other's failure, and
neither may be reported as blocked by the other.

**`G15` needs a harness that does not exist yet.** The airgap fixture creates one
engine. Until something creates two in one process, `G15`'s device row is
NOT RUNNABLE rather than merely unrun — the same distinction that reclassified the
sealed code-patch row from NOT VALIDATED to NOT BUILT. Say so rather than booking a
device for it.

#### THE MINT LANDED — cell identity, established once, 2026-08-13

**Engine hash `4df8f9b6139b67d2cfe9f6aa8212372cade36278`.** Every gate below refers
to this and does not re-argue it.

| | |
|---|---|
| cell address | `4df8f9b6139b67d2cfe9f6aa8212372cade36278` (sha256 over the cell manifest, first 40 hex) |
| iOS engine donor | `11e5695710275f829ef1e4a45636d39454ca1769` — the newly built Route B engine, published from `out/ios_release` |
| `ios_artifacts_sha256` | `8b0ea72b80d8fbd6ae81dd0e7a8e7fded0b740c5815e4101755362ab266d7f9f`, participating in the address |
| `dart2bytecode.aot` | `0420da14…` — patch `0006`, `G3.7`'s widened entry-point contract |
| `route_b_analyze.aot` | `3e674b47…` — `analysisVersion` 8 |
| Flutter binary | `e828f8ef…`, 19,071,568 bytes, Dart `6b58bb3a` |
| `audit_route_b_compiler.sh` | **AUDIT CLEAN** — reconstructible; every recorded hash matches, and the published `ios-release/artifacts.zip` matches `ios_artifacts_sha256` |
| `assert_diagnostic_engine.sh` | **3/3** — the `rbtrace v=` sentinel and `InterpretCall` are both present in the SHIPPED binary |

**The identity chain was closed by measurement at each link, not by assumption.**
The G15 change is an embedder-only edit, and the mint's own header records that such
a change once "computed the SAME address for a different engine" — so three separate
things were checked rather than inferred:

1. **The build really contains it.** `shorebird.shorebird.o` was recompiled inside
   the build window, and the resulting `Flutter` **differs** from `881e4129`'s
   (`e828f8ef` vs `396a0b0c`) — while being the *same byte size*, 19,071,568, which
   is exactly what moving one statement produces and exactly the coincidence that
   would have made "same size, must be unchanged" a plausible wrong conclusion.
2. **The published zip is that build.** The `Flutter` inside
   `4df8f9b6/ios-release/artifacts.zip` hashes to `e828f8ef…`, equal to the built
   binary.
3. **The address covers it.** `ios_artifacts_sha256` is in the cell manifest, so a
   future embedder-only change cannot reuse this address.

**TWO PRECONDITIONS, now permanent, because both were broken here and both failed
in the direction that looks like success.**

> **Never establish a new engine revision by writing cache stamps.** A stamp asserts
> what the cache ALREADY contains, so writing the new revision into it tells Flutter
> there is nothing to fetch — and the build consumes the OLD engine while every
> report names the new one. Measured: with the stamps written, the cached `Flutter`
> was still `396a0b0c…` (`881e4129`'s) under a checkout claiming `4df8f9b6`. Remove
> the cache state and force consumption of the published bytes:
> `rm -rf bin/cache/{artifacts,dart-sdk,downloads}`, `rm -f bin/cache/*.stamp`, then
> set `engine.version`. **Verify the CONSUMED bytes, not the published ones.**

> **After minting a new experimental hash, reload the mirror's hash map BEFORE any
> client fetch, then clear any cache that could hold fallback bytes.** The mint
> appends the hash to `experimental_hashes.map` itself, so Caddy has not read it yet;
> a fetch before the reload is served fallback bytes from the pinned hash. **This is
> the part `@must_be_local` cannot protect**: the Caddyfile sets `order cache before
> respond` deliberately, so once a fallback response is cached under that hash's URL,
> a cache HIT beats the 404 ownership would return. Clearing
> `<flutterDir>/bin/cache/downloads` matters too — a poisoned download survives on
> the client side. And export `FLUTTER_STORAGE_BASE_URL` /
> `SHOREBIRD_STORAGE_BASE_URL` at the mirror, or the fetch goes to Google, where an
> experimental hash does not exist.

> **After clearing cache state, WARM IT BEFORE cutting a release you intend to be
> patchable.** `isRouteBEngine` reads
> `bin/cache/artifacts/engine/ios-release/.../Flutter` and returns false when the file
> does not EXIST — and after a cache clear it does not exist yet, because the engine
> artifacts are fetched later, during the build itself. So the very first release
> after a clear silently takes the NON-Route-B path: no `--patchable_static_calls`, no
> retention declaration, no provenance, and a perfectly normal-looking success
> message. Measured on release 33, which came out at **8 patchable sites (2 per MB)**
> against a 100/MB threshold and carried no `route_b_provenance.json` — while the
> engine it consumed was verifiably the right one (`e828f8ef`). Warm with a throwaway
> build or `flutter precache`, confirm the binary exists, then cut the release that
> matters. Release 33 is a DISCARDED specimen for exactly this reason.

> **The CLI under test must be the CLI you changed.** `~/.shorebird` is its own
> checkout of this repo — it has a `fork` remote pointing at the working tree — and it
> does NOT move when you commit. Release 34 was cut by the CLI at `9440d56a` and
> therefore recorded **no `buildConfig` at all**, so it could not serve as the
> `G4.3` compatibility specimen no matter how correct the release was. Worse in the
> other direction: that CLI pinned `supportedRouteBAnalysisVersion = 7` while the
> minted cell ships analyzer **v8**, so every patch against this cell would have been
> refused as too new — a refusal that looks exactly like a `G3.7` failure and is
> nothing of the kind. Sync first:
> `git -C ~/.shorebird fetch fork <branch> && git -C ~/.shorebird checkout --detach FETCH_HEAD`,
> then assert the field and the pin are actually present before cutting.

**Mint-readiness was gated, not eyeballed.** `probes/assert_mint_ready.sh` re-derives
the verdict from the primitives the invariant names — the ninja exit the build
recorded with `$?` and nothing piped, plus the existence of the framework — because
`build_ios_release.sh` exits 0 whether or not ninja succeeded. It also reports a
DISAGREEMENT between a build's own summary line and its primitives as a defect rather
than preferring either. **Mint only from `VERDICT=success`; `unknown` is not success.**

#### `G4.2`/`G4.3`: the mismatch arms and the matching arms are DIFFERENT CLAIMS

Precommitted, because conflating them is how "configuration compatibility works"
would get credited to a patch that merely ran.

| arm | expected | what it proves | where it is decided |
|---|---|---|---|
| release `--flavor foo`, patch `--flavor bar` | **REFUSED** — *but on Android this expectation is MEASURED FALSE, 2026-08-14* | ~~the fingerprint compares effective configuration~~ **Not on Android.** Two arms isolate the cause: with **two `app_id`s** it exits 70 `Release not found` — refused by **`app_id` routing** (`shorebird_yaml.dart:69-72`), which says nothing about configuration; with **one `app_id`** (control, so routing cannot be the cause) it **exits 0 and publishes**, and the mismatched patch then **applied on `R2`**, leaving the `foo` app displaying `flavor: bar`. Consistent with source: `RouteBBuildConfig` hits in `android_patcher.dart` = **0**; configuration comparison is an iOS/Route B mechanism only. The two-`app_id` refusal must not be banked as this arm passing — it is the wrong-reason refusal the plan warned reads exactly like the right one. Evidence `evidence/android/g42-flavor/` | CLI, **before any patch artifact exists** — **on iOS only** |
| ~~release `--obfuscate`, patch plain~~ | **UNCONSTRUCTIBLE — KNOWN GAP, removed from the device queue 2026-08-13** | — | decided by READING, not by running |
| **NEW: release plain, patch `--obfuscate`** | **REFUSED** | obfuscation is semantic — the honest substitute for the arm above | CLI, before any patch artifact exists |
| ~~release `--flavor foo`, patch `--flavor foo`~~ | **PROVEN 2026-08-14 on `R2` (Android)** — `FLAVORPROBE-V1`/`flavor: foo` → `V2`/`flavor: foo` on CPH2551, new `flavorprobe` fixture, release 2.0.0+1 + patch 1. Two readings on purpose: the MARKER proves patched code ran, the FLAVOR proves configuration survived. iOS still owed | the matching path still produces a patch that EXECUTES | device — **Android done** |
| ~~release `--obfuscate`, patch `--obfuscate`~~ | **RETIRED 2026-08-14 — PROVEN** (release 39 / patch 1 / `R1`; `NEW-OBF` on screen) | obfuscation does not break target resolution *through the real pipeline* | device — **done** |
| release flavored by `default-flavor` ONLY, patch same | patched value on device | the path with no command-line token to notice | device |

A refusal arm that reaches the device has already failed: its whole claim is that
nothing was produced. So its evidence is the CLI's log and the ABSENCE of a
container, not a screenshot. Conversely a matching arm that only shows "the CLI
accepted it" proves nothing about execution.

**One release can carry several matching arms** (flavored + obfuscated together),
but a mismatch arm must not share a release with the matching arm it is contrasted
against — same-release contrast is what made the earlier private-member control
meaningful, and different-release contrast is what made release 23's control
worthless.

### Then, in rough order

6. **`G3.6b app-private-holes`** — the two accepted-then-failed holes. Costs `R7` +
   a mint; fold into `G3.6e`'s mint rather than paying twice.
7. **`G4.1 dart-defines`** — **BUILT 2026-08-13.** The seam `G4.3` was supposed to
   reuse now exists: `RouteBBuildConfig` separates **raw invocation provenance**
   (audit) from **effective compiler configuration** (compatibility), fingerprints
   the latter, records it in release provenance, refuses a mismatched patch before
   the compiler is resolved, and threads the release's defines into
   `dart2bytecode`. Its canonical form is **measured, not assumed** —
   `probes/g41_define_semantics.sh` 4/4. Obfuscation should now be another field
   flowing through this mechanism rather than a second bespoke system.
8. **`G4.3 obfuscation-ios`** — **BUILT 2026-08-13, host-proven.** It became a field
   flowing through `G4.1`'s seam rather than a second bespoke system, exactly as
   that goal predicted: `obfuscate` joined the effective configuration,
   `splitDebugInfoPath` went to raw provenance only. The classification was
   MEASURED, and the first measurement was wrong in the dangerous direction —
   hashing the whole ELF made the symbol PATH look semantic, which would have made
   two machines emitting the identical program incompatible over filesystem
   layout. Hashing the stripped program corrected it. Device gate still owed.
9. **`G4.2 flavors`** — **the Route B half is BUILT 2026-08-13**; the host probe that
   this line asked for came first and found the gap by reading, so no `R2` was spent
   discovering it. Flavor is represented as ONE compiler fact —
   `effectiveDefines['FLUTTER_APP_FLAVOR']` — never as a second fingerprint field,
   because Flutter itself reduces `--flavor` to exactly that define. What remains is
   the device gate and the Android half.
10. **`G6 tracks`** device row — follows `G8` or `shorebird preview`, since
    `channel` does not reach the device.
11. **`G7 signing`** — **the decision is MADE, 2026-08-13: option (ii), "loud opt-in"**
    — keep the permissive default, warn when a release is cut with no public key.
    Written up with its rejected alternatives in [`SIGNING.md`](SIGNING.md); (iii)
    fail-closed was rejected because it breaks this fork's own acceptance scripts,
    whose Android and iOS legs are PROVEN *unsigned*. **A written decision upgrades
    no status** — §7's rows stay KNOWN GAP / NOT BUILT. What remains is one
    `logger.warn` beside `release_command.dart:423-431` (which already warns in the
    opposite direction) plus a test, and a golden across the Dart-PEM /
    Rust-base64-DER seam that nothing crosses today.
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
| `G6 tracks` (server half) | this commit — named `beta`/`staging`/`canary` asserted independent, supersession pinned by a negative control, rollout reclassified **KNOWN GAP (client surface)**. Device row deliberately still NOT VALIDATED |
| `G7 signing` (the decision) | this commit — option (ii) chosen with rejected options recorded, `SIGNING.md` written, §7's mechanism sentence retracted and corrected. **No status upgraded** |

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

### `G3.7`'s release-37 claim, precommitted and deliberately narrow

Body: `String paramValue(String who) => 'PARAM-$who';` — the live caller passes
`'ARG'`.

> **`param=PARAM-ARG` on the preserved release-37 binary proves that the live
> caller's sole positional `String` argument is transferred into the interpreted
> replacement and is observable by the replacement body. A body that ignores its
> parameter is insufficient evidence.**

**What it does NOT prove: argument ORDER.** There is one argument, so there is no
order to get wrong. Multi-argument ordering needs its own two-or-more-parameter
specimen, and the host probe's `two_params` arm (`-Da`… `int b` = 7 landing in slot
`b`) is where that currently rests — host-proven only. Do not let "order" enter this
verdict.

**And the body stays minimal on purpose.** Calling methods on `who` to "prove type"
would drag binding and dependency reach into a gate meant to isolate the parameter
ABI, so a failure could no longer be attributed. Interpolating the received value is
the clean discriminator: it cannot succeed unless the argument arrived with a usable
value, and it introduces nothing else.

### The beacon's query string was not in the log — FIXED 2026-08-13

`cps-ios` logged `GET /selfhost-beacon/state -> 403 (0ms)`, path only, because
`api.dart:_logRequests` passed `req.url.path`. So a fixture value carried ONLY in the
beacon's query string could not be read back, and `read_beacon` in
`airgap_acceptance.sh` — which greps `/selfhost-beacon/state?[^" ]*` — could never
match that line.

**This was an OBSERVATION-CHANNEL defect, not a `G3.7` mechanism block**, and the
distinction chose the fix. The live call, the consumed result and the parameter target
were all already established on release 37's own bytes; only the gate's ability to READ
the outcome was missing. A displayed fixture row would also have worked, but it would
have forced a re-cut and retired a specimen that was already qualified — pure drift for
no new evidence. Repairing the channel keeps release 37 as the basis.

`loggedRequestPath` (`api.dart`) now logs the query **for the beacon path only**. Not
for everything: the admin surface takes `?email=`, so logging queries wholesale would
put personal data into a log that gets tailed and pasted into issues. Measured
immediately after, on the unpatched release-37 bundle:

```
GET /selfhost-beacon/state?release=AIRGAP-FIXTURE-V1&asset=BAKED-INTO-RELEASE
&assets_patch=none&code_patch=none&route_b=OLD-rel&private_class=OLD-pc&param=OLD-ARG
  -> 403 (0ms)
```

It repaired three assertions, not one: `assert_beacon` and `assert_beacon_code` in the
sealed harness both hard-fail on an empty read (`[[ -n "$got" ]] || return 1`), so the
broken channel made them unrunnable too. It never faked a pass — worth stating, since
a silent-pass version of this defect would have been far worse than an unrunnable one.

The `param` row is still not displayed, and no longer needs to be for the arm to run.
It should ride the next `airgap_app` re-cut — the one carrying `G3.7`'s missing
`two`/`named`/`opt` shapes — since the 1334 px screen does have room for an eighth
row. **Not `H2`**: that plan excludes changes to `airgap_app` by design.

### Two ways a device arm becomes unattributable — both met on 2026-08-13

**1. Launching the patch build instead of the release.** `shorebird patch ios`
re-archives over `build/ios/archive`; that archive is the patch build, with the
replacement compiled straight into a fresh AOT binary. Launching it shows the patched
value with the patch mechanism playing no part, and it AGREES WITH THE ARM'S
PREDICTION — the strongest false positive available here. It happened: release 37's
first arm read `param=PARAM-ARG` from LC_UUID `2da6f295…`, not the preserved
`31869a1e…`. See `evidence/releases/37/DISCARDED-2026-08-13.txt`.

The rule at `:1417` and `launch_fixture`'s own comment both already said so, and both
were bypassed by hand-rolling `ios-deploy --bundle <archive>/Runner.app`.
`assert_installed_release.sh` was run and passed — before the patch build, when the
archive was still the release. **A correct check at the wrong moment is not a guard.**
So the fix is an instrument, not a third note: `probes/launch_release_bytes.sh` makes
identity a precondition of launching, resolving the `.ipa` (which the patch build
leaves alone) against `evidence/releases/<n>/LC_UUID` and refusing on mismatch.

The tell was on the same beacon line: `code_patch=none` reads the updater's active
patch number, and a patched device cannot report `none`. **When the headline row and
its corroborating row disagree, believe the corroborating row.**

**2. Uninstalling the app between arms.** `ios-deploy --uninstall_only` resets iOS's
Local Network consent for the bundle. The fixture then blocks on "would like to find
and connect to devices on your local network" BEFORE any code runs: no
`patches/check`, no patch download, no beacon — while `ios-deploy` still reports
`success`. It is silent in every log this rig reads and looks exactly like a dead
gate. One tap on OK clears it and consent persists until the next uninstall.

**Never uninstall the fixture to clear updater state.** And note that a displayed
fixture row would NOT have rescued this: no consent means no patch is ever fetched,
so the app renders its release value however it is read.

### Consumption is not reachability

> **Result consumption proves observability of a call RESULT, not execution
> reachability of the TARGET.**

`assert_result_consumed.sh` answers "if this call returns a value, does anything
read it" — a property of the caller's instructions. It cannot answer "does this call
ever run", which is a property of the path the app takes. Both are required for a
behavioural device arm, and they fail differently: a discarded result makes a working
patch invisible (releases 25–30), while an unreachable call site makes a working
patch never execute.

Found the second way on 2026-08-13: the fixture's only parameterised method is called
solely inside `value()`'s dead branch, and the gate reports that site **CONSUMED** —
correctly. **The dead-branch retention trick is valid for keeping symbols available
and cannot serve as a behavioural specimen.** A parameter-ABI gate needs a target on
an independently demonstrated live path — demonstrated by the baseline observation
itself, not by reading the source.

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

### The precommitment rule

> **Before running an experiment whose favourable-looking outcome would be ambiguous,
> write down what each possible result will mean.**

Not for rigour's sake — it has now prevented **two** false greens in this project,
which is why it is a rule and not a preference:

* **the vacuous `+0.00 %`.** A retention-cost arm reported "+0.00 %, 8 bytes" on the
  airgap fixture, which reads as *broad private retention is free*. The two generated
  interfaces were **byte-identical**: the treatment priced nothing. Caught only because
  the enumeration counts printed beside the sizes — and the fix was a gate that prints
  **VACUOUS** and refuses to emit a percentage.
* **`dead=0`.** The dead-body arm executed, which reads as *everything works, ship it*.
  The precommitted matrix had already written that row as "no live-vs-dead boundary
  exists to draw", so the result forced the reasoning to move instead of the
  conclusion. Same row, opposite instinct.

Both were **favourable-looking**, which is the tell. A red result gets interrogated;
a green one gets banked. So:

* state the outcomes and their meanings **before** the run, in the document or the
  probe header where the next reader will find them;
* keep a falsified prediction **beside** the evidence rather than editing it away —
  `dead_body.sh`'s failing dead-arm assertion is preserved for exactly this reason;
* a cost arm must prove its treatment **changed the thing being priced** before it
  reports a delta.

When an item becomes PROVEN, record beside it whichever of these apply:

* engine hash;
* release version;
* patch number;
* platform / device;
* evidence or probe name;
* the commit containing the implementation and its gate.
