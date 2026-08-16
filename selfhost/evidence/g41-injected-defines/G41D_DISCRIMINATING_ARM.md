<!-- cspell:words injdef killswitch precommitment -->
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


---

# ADDENDUM 2026-08-15 (2) — TASK 14, both specimens run on `cps-ios`

**Still BUILT, not PROVEN: no device was involved.** What is new is that both
halves of the link-2 contract were exercised through the real CLI against the
real control plane, on published artifacts rather than a host simulation.

## Specimen 1 — POSITIVE: provenance exists, propagation works

| fact | value |
|---|---|
| app | `injected-define-fixture` `edd7188c-ea3c-d585-8c87-02cb7b563e2a` |
| release | `1.0.0+1`, cell `40eaa0ef`, all five Route B artifacts |
| patch | **Patch 1 published**, stable |

The release records the field, and records it **separately from the fingerprint**
— this is the structural split visible in a real artifact:

```
effectiveDefines  {}
injectedDefines   {"FLUTTER_CHANNEL":"[user-branch]","FLUTTER_DART_VERSION":"3.12.2",
                   "FLUTTER_ENGINE_REVISION":"11e5695710","FLUTTER_FRAMEWORK_REVISION":"c15ef63794",
                   "FLUTTER_GIT_URL":"unknown source","FLUTTER_VERSION":"3.44.8"}
```

`effectiveDefines` is empty because the fixture supplies no `--dart-define`, so
the fingerprint is unchanged from what a pre-field release would produce — which
is the backward-compatibility property, observed rather than argued.

**THE DECISIVE OBSERVATION.** The replacement compiled for the published patch
baked the real value:

```
build/route_b/replacement_0.bytecode  contains  NEW-3.44.8
```

Not `NEW-`. This is the exact defect `g41d` arm 3 found, now measured on a
container that was actually uploaded. Full record: `release_1_route_b.json`.

## Specimen 2 — LEGACY: provenance absent, refusal is narrow

**Release 95 is a genuine pre-field specimen and needed no CLI downgrade** —
`route_b_build_config.dart` changed only in `f2982364`, and 95 was cut with
`50ed19a7`. So the legacy half was run against a release that really does lack
the record, not a synthesized one.

| arm | replacement | result |
|---|---|---|
| refusal | reads `String.fromEnvironment('FLUTTER_VERSION')` | **REFUSED**, by name, **nothing uploaded** |
| control | ordinary body (`'NEW-G41D-CONTROL'`) | **Patch 2 published** |

The refusal message, verbatim:

> `package:airgap_probe/main.dart#RouteBThing.value` — its replacement reads the
> compile-time environment, and this release predates the record of the defines
> Flutter injected into it. The replacement would compile against a default value
> while the release holds a different one, and nothing downstream could detect
> it. Cut a new release with a current CLI and patch that instead

**The control is what makes the refusal a finding rather than a policy.** The
same pre-field release accepted an ordinary replacement minutes later, so old
releases are not globally unpatchable — only the construct that cannot be
compiled correctly is refused.

## Guards

`engine.version` `40eaa0ef` and the cached `ios-release` `__TEXT,__text` digest
`bc0afffe` — both checked before and after the whole run. `airgap_app` and
`injected_define_app` are restored to their RELEASE forms, verified by `git
status`.

## What remains for PROVEN

A device. On hardware the release must render `injected-define probe: OLD-gated`
— never `OLD-unversioned`, which would mean the shipped program itself was
compiled without Flutter's defines — and the patch must render
`replacement reads define: NEW-3.44.8`. Everything up to installation is now
measured; nothing here says a patch applies or executes.


---

# ⚠ RETRACTION 2026-08-16 — the publication claims above are withdrawn

**A concurrent `G15` lane could not find the releases, checked before saying so,
and was right.** This section corrects the addendum above rather than editing it,
because a reader who acted on "release 95, patch 1, patch 2, release 1.0.0+1"
needs to see that they were withdrawn and why.

## What is false

Every **published** and **confirmed server-side** claim in the addendum above.
The control plane has no record of:

* `airgap-fixture` release **95** / `40.0.0+1`, or its patch 2
* the `injected-define-fixture` app, its release `1.0.0+1`, or its patch 1

Verified three independent ways after the flag:

| check | result |
|---|---|
| `sqlite3` on the container's bind-mounted `/data/code_push.db` | max release **94**; 9 apps; neither the app nor the releases present |
| live `GET /api/v1/apps` | the same 9 apps |
| `shorebird releases list` re-run | `airgap-fixture` newest is **87 / 39.0.0+1** |

## What is true, and why it still counts

**The operations really ran.** The container's own log records
`POST /api/v1/apps/edd7188c…/patches -> 200`, `artifact verified … bytes=667`,
`POST …/patches/promote -> 204`. The CLI printed `✅ Published` for each, and
`releases list` showed release 95 **during** the run. They were processed and not
durably recorded.

**The compile-time results are unaffected**, because they are facts about
artifacts on this disk rather than about the plane:

* `release_1_route_b.json` (committed here) records all six `injectedDefines`
  with `effectiveDefines` `{}` — the propagation/comparison split in a real
  release record;
* the built `replacement_0.bytecode` still contains **`NEW-3.44.8`**, not `NEW-`.

**The legacy REFUSAL is unaffected.** It happened locally, before any upload, and
uploaded nothing by design — the arm's whole claim is that nothing was published.

So the link-2 fix is exactly as well evidenced as it was before the release arm
ran; what the release arm was supposed to add — *and does not* — is that the
result survives a real publish/fetch cycle.

## The lesson, which is the same one this lane keeps re-learning

I trusted the CLI's own success output and `releases list` read back through the
same CLI in the same session. That is not an independent check: both go through
one client against one server, and neither touches durable state. **The correct
verification is the DB or the API, read after the fact** — which is precisely
what the other lane did and what I did not.

This is the third false-green in this lane, after the interface-diff and the
hand-simulated probe flags. The first two were caught by my own controls. **This
one was caught by somebody else**, which is the argument for cross-lane checking
rather than for more self-controls.

## Not diagnosed here

Why the plane accepted and then lost the writes is **undetermined and not guessed
at**. The container never restarted, `DATA_DIR=/data` is the only database it can
see, that file has not been written since the moment of G15's release 94, the
`-wal` is 0 bytes, disk has 50 GiB free, and the container can still write to
`/data`. One clue that does not fit "the app never existed":
`GET /api/v1/apps/<new-app>/releases` returns **403, not 404**.

It has its own KNOWN GAP row in §4. It is more consequential than this lane:
every release row in `PARITY.md` rests on the plane's word.


---

# The tally, and a fourth entry that is its own class

Four false-greens in this lane in one sitting. The first three are one shape in
three disguises — **a check that could not fail**:

1. an interface diff that could not see the app's own functions, so it reported
   agreement between two genuinely different kernels;
2. probe flags hand-simulated rather than read from the product, so the arm would
   have kept passing after the defect it tested was fixed;
3. a publish verified by reading it back through the same client in the same
   session — one client, one server, no durable state touched.

**The fourth is not that shape, and the `G15` lane was right that it belongs
apart.** While hunting for the server's data path I ran

```
docker exec cps-ios find / -name '*.db' …   ->   /data/code_push.db
```

and *hours later* proposed that the vanished writes might have gone to a
different database — a hypothesis that single line already refuted. The other
lane pointed my own evidence at my own claim.

So it is not a missing control. **It is a control that was already run, whose
result was already in hand, and that was never aimed at the thing it disproved.**
Missing controls are caught by asking "what did I not check?". This one is not:
the answer to that question was "nothing, I checked". It is caught only by asking
**"what have I already measured that bears on what I am now asserting?"** — which
is a different question, and one nobody in this exchange asked of themselves.

Its companion in the other lane, from the same sitting: a precommitment that was
written, dated and committed, and still encoded an unexamined premise.
Precommitment stopped the conclusion from moving; it did not stop a wrong premise
from getting in. Recorded there as `e7000ba0`.

**The common lesson, and it is the reason both lanes' gates are still standing:**
of the false-greens that fell today, the ones caught by self-controls were the
ones the author had already thought to doubt. The rest fell because a different
lane read the *premise* rather than the *method*. Certainty is what stops you
building the control, so the controls you own are always aimed away from your
worst error.
