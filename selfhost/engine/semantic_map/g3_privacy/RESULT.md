<!-- cspell:words semantic dill bytecode airgap -->
# SM1-G3 — privacy domains

**Gate:** [#52](https://github.com/mml555/shorebird/issues/52) · **Tracker:** [#48](https://github.com/mml555/shorebird/issues/48)
**Run:** 2026-09-07 · **Verdict: `checks_failed=0`. Every declaration's privacy
domain is derived from a Kernel fact, all four adversarial arms refuse with
distinct categories, both positive controls accept, and every check was
falsified.**

Transcript: [`evidence/g3_privacy.txt`](evidence/g3_privacy.txt) ·
structured: [`evidence/g3_privacy.json`](evidence/g3_privacy.json) ·
the confound: [`evidence/confound_guard_presence.txt`](evidence/confound_guard_presence.txt) ·
falsifications: [`evidence/falsification.txt`](evidence/falsification.txt).
Reproduce: `run_g3.sh`.

## The confound runs first, and it is fatal

G0 recorded it, so this gate **reads** it rather than restating it:

    id          PLATFORM_LIBRARY_GUARD_IS_UNCOMMITTED
    owner_gate  SM1-G3
    statement   the guard refusing --resolve-private-names-in-library on a
                platform library is uncommitted-but-shipped source, present in
                effective tree 7b04b01b and absent from a clean checkout of
                9e8c898a
    consequence a gate built from the wrong tree makes the platform-library arm
                pass vacuously

The failure mode is specific and nasty: **"no platform privacy was granted" and
"the guard never ran" look identical from the outside.** So presence is asserted
three ways, weakest to strongest, and the strongest is the only one that settles
it:

1. the dirty path **exists** — existence-guarded, because a missing file
   otherwise reports as "absent, correct";
2. the refusal **text** is in that file — cheap, and still only a string;
3. the refusal **fires** — a compile with `--resolve-private-names-in-library
   dart:core` must throw the guard's own `StateError`.

Plus an **anti-vacuity control**: the same body under an *app*-library scope must
fail on `_GrowableList`, proving the body genuinely needed `dart:core`'s private
namespace. `run_g3.sh` refuses to score at all unless this reports
`GUARD_PRESENCE=PROVEN_FIRING`.

### The confound assertion was falsified against a real guard-less tree

Not argued — reproduced. The shared engine checkout is **never** mutated (P1.1
had to edit and restore it, and a forgotten restore leaves a shared resource
wrong for every later lane). The dart tree's `package_config.json` uses
**relative** `rootUri`s (`../pkg/front_end`), so an APFS clonefile copy resolves
its *own* CFE:

    cp -c -R .../third_party/dart /Volumes/build/sm1_g3_noguard_dart   # 41s, ~0 bytes
    <delete only the isScheme('dart') StateError>                      # 0005 without its fix

| tree | flag = `dart:core` | verdict |
|---|---|---|
| frozen `7b04b01b` | throws the platform-library `StateError` | `PROVEN_FIRING` |
| guard-less clone | **compiles, rc=0** | `NOT_PROVEN` |

The clone **compiles** it — `dart:core`'s private namespace granted to package
source, which is exactly the hole P1.1 arm A5 found. So the guard is the only
thing refusing it, and the assertion detects its absence.

**One correction the falsification forced on my own probe.** The first version
of the probe body read the app's private member *as well as* `_GrowableList`.
Under `flag=dart:core` the app namespace is out of scope, so that body failed on
the *app* private whether or not the guard existed — arm 3 would have passed for
the wrong reason. Narrowed to a platform private alone, a guard-less tree
compiles it, and the arm discriminates.

## The domain is derived, not assumed

Dart privacy is library-scoped, and Kernel carries the scope on `Name` itself:

```dart
abstract class Name {
  Reference? get libraryReference;   // non-null ONLY for a private name
  bool get isPrivate;
}
bool operator ==(other) => text == other.text && library == other.library;
```

So `privacy_domain` is `name.libraryReference`, read off the node — **not**
inferred from a leading underscore, and not taken to be the enclosing library.
Every row also carries `domain_derivation` naming the Kernel fact used, and the
scorer fails any row whose derivation is not one of them.

    census (base corpus)  20 public
                           2 package:corpus/app.dart
                           1 package:corpus/helper.dart

**The discriminating case is in the corpus by design.** Both `corpus/app.dart`
and `corpus/helper.dart` declare `_privateHelper`. The simple names are
identical, so a name-based check accepts a cross-library reach; only the derived
domain separates them, and Kernel's own `Name` equality agrees.

A domain that cannot be derived is recorded
`UNDERIVABLE_NO_LIBRARY_REFERENCE` and **classified**, per the gate's stop
condition — never defaulted to the permissive case.

## Read is not write, and the shipped key cannot always tell them apart

`RouteBPrivateTarget.name` is VM-shaped: `get:`/`set:`-prefixed for an accessor,
**bare for a field**. That is not a reading of a doc comment — it is what the
real manifests in this repo contain:

    package:airgap_probe/main.dart#_ProbeBodyState#get:_assetsPatch    accessor
    package:airgap_probe/main.dart#RouteBThing#_secret                 FIELD, bare

Counted across every capability manifest this fork has ever produced:

| manifest | private instance keys | bare | `get:` | `set:` |
|---|---|---|---|---|
| release 32 patch 2 | 11 | 9 | 2 | **0** |
| first_activation_probe | 4 | 3 | 1 | **0** |
| sign_probe_app | 2 | 2 | 0 | **0** |
| gate6d release 142 | 3 | 3 | 0 | **0** |

**No release has ever published a `set:` key.** And for a field, one bare key
serves both modes — so:

- for an **accessor**, the two modes are distinguishable (`get:scale` vs
  `set:scale`), and the map says so;
- for a **mutable field**, `capability_key_identifies_mode` is **false**: one
  key authorises both.

The collapsed case is the one that matters. ROADMAP P1.4 device-proved exactly
one access mode — *a private FIELD READ*, release 32 patch 2,
`value() => _secret` — and P1.4 states a private **write is not claimed**. The
device-proven read and an unclaimed write present **the same manifest key**, so
`refuseInstanceMember` cannot separate them. The map carries the mode, which is
what lets the write be refused before publication rather than at load.

This is recorded as a **FINDING**, not a pass and not a failure: the shape exists
in the corpus and in the shipped releases, and the map states it.

## The arms

Every one refuses with an attributable category, and the two ACCEPTs are
load-bearing.

    positive_read_private_field     read   ACCEPT
    positive_invoke_private_method  read   ACCEPT
    cross_library_private           read   CROSS_DOMAIN_PRIVATE
    platform_library_grant          read   PLATFORM_DOMAIN_PRIVATE
    tree_shaken_private             read   NOT_RETAINED
    private_write_read_only_grant   write  WRITE_NOT_GRANTED

Three of these are minimal pairs against the accepted control, which is what
makes each attributable to one dimension:

- `cross_library_private` — same simple name, same mode, **different domain**.
- `tree_shaken_private` — same domain, same grant, same mode, **not retained**.
  `--aot` shook out an unreferenced private; `NOT_RETAINED` is its own category
  because the remedy is re-releasing, not a policy change.
- `private_write_read_only_grant` — **same subject, same grant, same manifest
  key**, differing only in the requested mode. It is the accepted control with
  `read` changed to `write`.

`platform_library_grant` is refused *before* the scope comparison, so a grant
naming a platform library cannot launder itself by matching the domain it names.
Its compiler-side truth is the confound assertion above — two independent
evidence classes for the one arm the confound threatens.

**Category exhaustion is asserted.** Every category the policy can return must
be produced by some arm, or it could be unreachable code that no arm would
notice.

## Every check was falsified

See [`evidence/falsification.txt`](evidence/falsification.txt).

| mutation | must break | observed | failures |
|---|---|---|---|
| one domain for every private name | the domain-distinctness check | `_privateHelper` × 2 no longer produce two domains; census collapses to `3 private` | 6 |
| ignore `retained_in_release` | the tree-shaken arm | `tree_shaken_private` → `READ_NOT_GRANTED` (want `NOT_RETAINED`); `NOT_RETAINED` unexercised | 2 |
| ignore `capability_key_identifies_mode` | the write arm | `private_write_read_only_grant` → **`ACCEPT`**; `WRITE_NOT_GRANTED` unexercised | 2 |
| drop the platform refusal from the policy | the platform arm | `platform_library_grant` → `CROSS_DOMAIN_PRIVATE` (want `PLATFORM_DOMAIN_PRIVATE`) | 2 |
| a policy that refuses everything | both positive controls | both → `CROSS_DOMAIN_PRIVATE` (want `ACCEPT`); 4 categories unexercised | 6 |

Each mutation was reverted and the suite re-run green in the same transcript, so
the failures are attributable to the mutation and not to a broken tree.

**Three of these rows say something the arms alone would not.**

*Mutation 1 does not break the cross-library arm.* With every private collapsed
into one domain, `cross_library_private` still reports
`CROSS_DOMAIN_PRIVATE` — it refuses for a reason that is now accidental. What
catches the mutation is the **domain-distinctness check** (two libraries
declaring the same private simple name must produce two domains) and the
positive controls, which start refusing. An adversarial arm that only asks "was
it refused?" would have passed a map with no library scoping at all.

*Mutation 3 is the sharpest.* Ignoring one boolean turns the private write into
**`ACCEPT`** — a write authorised purely on the strength of a read grant, which
is the precise hazard #52 names, reached by deleting one condition.

*Mutation 4 still refuses.* Dropping the platform rule leaves the platform arm
refusing, just as `CROSS_DOMAIN_PRIVATE`. Only requiring the **right category**
catches it. This is why the arms are scored on category rather than on
refusal.

The last row is the point of the positive controls: arms 1–4 are all satisfied by
`return REFUSE`, so without a case that must be **accepted**, this gate would
certify a policy that refuses every patch. Category exhaustion is the second
net — it caught a dead category in three of the five mutations.

## Parity with G1

The identity is **recomputed** in this tool rather than imported, and compared
against G1's own tool on the same input: **23 shared declarations, 0
disagreements**. Shared code would make the check prove nothing.

`DECLARATION_ID` stays identity-only. Privacy is a separate set of columns, per
the separation G2's acceptance fixed.

## Acceptance (#52)

- [x] Privacy domain is derived for every declaration in the corpus — from
      `Name.isPrivate` / `Name.libraryReference`, with the derivation recorded
      per row and non-Kernel derivations failed
- [x] Read and write capability are distinguished, not merged — and where the
      shipped key *cannot* distinguish them, the map says so and refuses the write
- [x] Each adversarial arm refuses with an attributable reason — four distinct
      categories, three of them minimal pairs against an accepted control
- [x] The guard-presence assertion runs before the platform-library arm is
      trusted — and `run_g3.sh` refuses to score without it

## Not established by this gate

- **No FAIL_OPEN was observed.** #52 defines FAIL_OPEN as a cross-domain
  reference that resolves. None did. This is reported as "not observed on this
  corpus", not as "cannot happen".
- **No real application.** Wonderous and LocalSend are frozen in G0 and not
  exercised here; the corpus is the adversarial one.
- **The write refusal is a map decision, not a runtime one.** This gate shows the
  map refuses an ungranted write before publication. Whether the *engine* would
  also refuse it at load is not tested here.
- **Whether a release could ever grant a write.** No manifest this fork has
  produced contains a `set:` key. Whether the retention interface *could* express
  one, and what it would cost, is SM1-G4's question.
- **`_enumToString`-shaped foreign domains.** The derivation distinguishes a
  private name whose domain is not its enclosing library, but the corpus contains
  no such declaration, so that branch is represented and not exercised.
