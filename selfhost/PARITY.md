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
| ◐ | **BUILT 2026-08-13** Full `--dart-define` release → patch acceptance matrix — `G4.1`. The release records its configuration in provenance; the patch **refuses before any compilation** when the effective set differs. 21 matrix tests plus the threading test |
| ☐ | **KNOWN GAP** `--dart-define-from-file` causes Route B patchability to be *declined* rather than supported. `G4.1` keeps it a decline and now says which of two reasons applies: a release that predates configuration provenance is *not comparable*, and one built with this option *never can be* — neither collapses into "no defines" |

### Flavors / schemes

| | item |
|---|---|
| ◐ | **BUILT 2026-08-13** the Route B half of flavors — `G4.2`. The predicted false green was CONFIRMED BY READING, not by a device run, and it is narrower than "flavors unsupported": *the shipped flavored release receives `FLUTTER_APP_FLAVOR`, while Route B's prepass and import kernel did not, so retention and binding could be computed against a different Dart program than the one that shipped.* Fixed by resolving the flavor Flutter's way (`--flavor`, else pubspec `default-flavor`) and threading `-DFLUTTER_APP_FLAVOR` into the prepass, the import kernel and the fingerprint. `probes/g42_flavor_flow.sh` 12/12 |
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
| ◐ | **BUILT 2026-08-13** Route B iOS release + patch under obfuscation — `G4.3`. `probes/g43_obfuscation_semantics.sh` 8/8 classifies each flag BY MEASUREMENT: `--obfuscate` changes the **stripped program** bytes, so it is semantic and fingerprinted; `--split-debug-info` and its **path** change the ELF's DWARF only, so they are recorded for audit and excluded from compatibility. **A container built for an obfuscated release APPLIES** (`APPLY ok`, `OLD-obf` → `NEW-obf`) while the interface and manifest stay source-named — obfuscation is a gen_snapshot-stage transform and `gen_kernel` accepts neither flag, so provenance cannot carry transformed identities. Device gate still owed |
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
| `R1` iPhone 7 | — | — | released 2026-08-12 | **free.** Left with release `23.0.0+1` installed and patch 1 active (`code patch: 1`) but NOT applied — see the device-gate finding. The device is fine; the patch's kernel came from the wrong engine. Previously: Wired (`ioreg -p IOUSB` shows `iPhone@00140000`), iOS 15.8.8, online to `xctrace` as `8cb4bc98…`. Note `devicectl` reports it `unavailable` — iOS 15 is not a CoreDevice, so the install transport is chosen by version, not by that listing |
| `R2` Android device | — | — | — | **free** |
| `R3` route-b tree | — | — | released 2026-08-12 | **free. Tree health on release: GREEN** — `dart_patches.sh --verify` all 4 applied, `route_b_analyze.aot` + `route_b_gen_dynamic_interface.aot` rebuilt and now published in cell `ee001fd7`. Nothing uncommitted in the Dart subtree; `$OUT/zip_archives` holds the exact bytes that cell carries |
| `R4` ios-engine tree | — | — | — | **free** |
| `R6` canonical fixture | — | — | released 2026-08-12 | **free at version `23.0.0+1`.** `lib/main.dart` is left in its PATCH state (`value() => _secret`), not the release state — whoever resumes either reverts that line or treats it as the next patch's source. Previously: Added one private field the release never reads — being unread is the condition under test, since retention then depends entirely on P2's `--private-dill` enumeration. Version bumps to 23 with this release |
| `R7` producer/analyzer | — | — | released 2026-08-12 | **free.** Analyzer is **v7** and `supportedRouteBAnalysisVersion` matches; the pair is published as cell `ee001fd7`, so the two are no longer skewed. Left committed at `1c3ffe13`, full `shorebird_cli` suite green |
| `R8` `cps-ios` | — | — | released 2026-08-12 | **free.** Release 69 (`23.0.0+1`) and patch 1 published against it. Previously: Container up and healthy; one release and one patch will be published against it |
| `R9` `cps-android` | — | — | — | **free** |
| `R10` server source | — | — | — | **free** — the `G6` lane |
| `R11` sealed CDN | — | — | released 2026-08-12 | **free, and serving `ee001fd7`.** `cdn-cache` is running unsealed. **Known hazard recorded:** the `ee001fd7 -> 69f9831c` map entry is what lets Flutter's cache rewrite the engine stamp mid-build, which is the device gate's failure. Previously: `cdn-cache` recreated so Caddy re-read the hash map — new-hash fallback went 404 → 302, cell zip serves byte-identical to the audited copy, old-hash control unchanged. Running **unsealed** (`upstream/enabled.caddy`), deliberately: sealing is host-global and would break every other build. Prior state below.<br>**free — and the mint HAPPENED this time.** `ee001fd78fcd5e78e976d35284bd13e1caffff63`: three cell files in ONE address change — `route_b_analyze.aot` (v6→v7), `route_b_gen_dynamic_interface.aot` (`--policy`/`--manifest`), `dart2bytecode.aot` (`--resolve-private-names-in-library`). Audit clean; host path 10/10 against the published zip. **The CDN still needs a reload** for Caddy to serve the new map entry, and no Flutter checkout has been restamped — both are the next holder's, because both mutate someone's environment |
| `R12` hermes-vps | — | — | — | **free** — additive capacity for `G4.2`'s Android half |

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
3. **`G3.7 param-abi`** — **BUILT on host 2026-08-13, device gate outstanding.**
   Measured separately from privacy exactly as this line required, and the two were
   never credited to each other: privacy closed on device via releases 31–32, and
   this closed on host via `g37_param_abi.sh` with its own release and its own
   controls. What remains is a mint, because the contract lives in
   `dart2bytecode.aot` inside the cell — so it should ride the next mint that
   happens for another reason rather than paying for one alone.
4. **`G15 activation-model`** — the highest-leverage safety/reliability project
   after language reach. **PARTIALLY ADVANCED 2026-08-13**: the severe symptom (a
   second engine in one process running unpatched AOT) had its mechanism corrected
   from source and fixed by a one-statement move, patch `0007` — arming sat below an
   early return gated on an updater init that deliberately fails on its second call.
   Compile-verified, tests written but unrunnable in this tree, device gate needs a
   mint. **It was NOT one redesign: it is two mechanisms.** The crash-backout and
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
| `G15` second engine | a host that creates TWO `FlutterEngine`s in one process — the fixture as it stands creates one, so this gate needs its own harness before it can run | both engines' `.routeb` reports | whether engine two is armed at all |
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

#### `G4.2`/`G4.3`: the mismatch arms and the matching arms are DIFFERENT CLAIMS

Precommitted, because conflating them is how "configuration compatibility works"
would get credited to a patch that merely ran.

| arm | expected | what it proves | where it is decided |
|---|---|---|---|
| release `--flavor foo`, patch `--flavor bar` | **REFUSED** | the fingerprint compares effective configuration | CLI, **before any patch artifact exists** |
| release `--obfuscate`, patch plain | **REFUSED** | obfuscation is semantic | CLI, before artifact production |
| release `--flavor foo`, patch `--flavor foo` | patched value on device | the matching path still produces a patch that EXECUTES | device |
| release `--obfuscate`, patch `--obfuscate` | patched value on device | obfuscation does not break target resolution *through the real pipeline* | device |
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
