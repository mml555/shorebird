<!-- cspell:words semantic dill bytecode airgap -->
# SM1-G3 — privacy domains

**Gate:** [#52](https://github.com/mml555/shorebird/issues/52) · **Tracker:** [#48](https://github.com/mml555/shorebird/issues/48)
**Run:** 2026-09-07, hardened after two PM reviews · **Verdict:
`checks_failed=0`, 13 arms, all 8 policy categories exercised. Every
declaration's privacy domain is derived and its *effective* domain resolved
through the owner; seven refusal causes are separated; four positive controls
accept; every check was falsified.**

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

## The owner decides for a public member of a private class

Round 1 got this wrong, and the corpus hid it.

```dart
class _Hidden {
  int ping() => 1;      // its own Name is PUBLIC
}
```

`ping`'s own `Name` is public, so the row carried `privacy_domain: public` with
`owner_is_private: true`. The policy gated on `is_private or owner_is_private`
— correctly deciding a grant was needed — and then compared the **member's own**
domain against the grant scope:

    'public' != 'package:corpus/app.dart'   ->  CROSS_DOMAIN_PRIVATE

So a legitimate same-library access to a public member of a private class was
refused as cross-domain. The base corpus contains no private class, so the green
result never touched the path. A matching defect sat in the grant construction:
granted read keys were collected where `is_private` was true, which omits every
public-named member under a private class — so even with the comparison fixed,
the access would have failed as `READ_NOT_GRANTED`.

**The fix records the three facts separately and derives the fourth.** Each row
now carries the member's own privacy, the owner's, and the effective domain with
the source that decided it:

| declaration | member | owner | effective domain | source |
|---|---|---|---|---|
| `_Hidden` (class) | private | — | `package:corpus/app.dart` | `member` |
| `_Hidden.ping` | **public** | private | `package:corpus/app.dart` | `owner(public-member-of-private-class)` |
| `_Hidden._secretPing` | private | private | `package:corpus/app.dart` | `member` |
| `_Hidden.<unnamed>` | **public** | private | `package:corpus/app.dart` | `owner(...)` |
| `_Hidden.seed` | **public** | private | `package:corpus/app.dart` | `owner(...)` |

Effective privacy is what the policy gates on, and what the synthetic grant set
is built from. "Wholly public" is now one test (`effective == 'public'`) rather
than two flags that could disagree with the domain being compared.

### A class has no Kernel `Name`, and the row now says so

Kernel models `Class.name` as a plain `String` — there is no `libraryReference`
to read. Round 1 synthesised a `Name` from `cls.name` and let the row carry the
member rule's derivation label, which asserted a Kernel fact that **does not
exist for classes**. Class privacy is now derived from the two facts Kernel does
carry, and the derivation string says exactly that:

    derived:Class.name(leading-underscore)+Class.enclosingLibrary
            (kernel-has-no-Name-node-for-a-class)

The scorer's allowlist accepts it as a distinct value rather than folding it in
with the `kernel:Name.*` labels.

### Construction is its own mode

The unnamed constructor exposed a third gap. Its `Name` text is the empty
string, so `''.startsWith('_')` is false and its own privacy is public — the
quietest case the owner rule exists for. But `accessKeys` returned no key at all
for a constructor, so a legitimate construction of a private class reported
`NO_SUCH_MODE`.

Constructors are neither read nor written. The shipped manifest already keeps
constructibility in its **own** list with its own key shape:

    package:super_fixture/main.dart#_Boxed.new     privateClassesConstructible

so the map now emits `capability_key_construct` (`library#Class.new` for the
unnamed constructor, matching that spelling) and `construct` is a third mode
with its own `CONSTRUCT_NOT_GRANTED` category.

### The counts are asserted, not eyeballed

Fixing the census surfaced a disagreement worth keeping a check for:
`private_count` was computed from effective privacy while the census was still
keyed on the member's own domain, so the same document reported **11**
effectively-private rows and a census summing to **4** non-public. Both numbers
were emitted; neither was compared. The scorer now asserts they agree, and the
document carries `member_own_domains` alongside `domains` so the two are visibly
different numbers rather than one number that could silently be either.

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

    positive_read_private_field                 read       ACCEPT
    positive_invoke_private_method              read       ACCEPT
    cross_library_private                       read       CROSS_DOMAIN_PRIVATE
    platform_library_grant                      read       PLATFORM_DOMAIN_PRIVATE
    tree_shaken_private                         read       NOT_RETAINED
    private_write_read_only_grant               write      WRITE_NOT_GRANTED
    privowner_public_method_same_library         read       ACCEPT
    privowner_public_method_foreign_scope        read       CROSS_DOMAIN_PRIVATE
    privowner_unnamed_constructor_same_library   construct  ACCEPT
    privowner_second_library_same_class_name     read       CROSS_DOMAIN_PRIVATE
    privowner_construction_withheld              construct  CONSTRUCT_NOT_GRANTED
    privowner_read_withheld                      read       READ_NOT_GRANTED
    privowner_write_final_field                  write      NO_SUCH_MODE

The four private-owner arms are their own minimal-pair set. All four name a
member whose OWN name is public, so a member-only model treats them
identically; only the owner's derived domain separates accept from refuse:

- `privowner_public_method_same_library` vs `..._foreign_scope` — same subject,
  same mode, **only the grant scope moves**.
- `privowner_second_library_same_class_name` — `helper.dart` declares its own
  private `_Hidden`, so the class simple name, the member simple name and the
  mode all match the accepted case. If owner domains collided this would be
  accepted.

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
| ignore `retained_in_release` | the tree-shaken arm | → `READ_NOT_GRANTED` (want `NOT_RETAINED`); category unexercised | 2 |
| ignore `capability_key_identifies_mode` | the write arm | `private_write_read_only_grant` → **`ACCEPT`**; category unexercised | 2 |
| drop the platform refusal | the platform arm | → `CROSS_DOMAIN_PRIVATE` (want `PLATFORM_DOMAIN_PRIVATE`) | 2 |
| a policy that refuses everything | all four positive controls | 7 of 8 categories unexercised | 11 |
| **6a** member-only privacy, as originally shipped | the same-library owner arms | same-library method and unnamed constructor → `CROSS_DOMAIN_PRIVATE` (want `ACCEPT`) | 6 |
| **6b** ignore the owner entirely | the foreign-scope owner arms | foreign scope and second-library → **`ACCEPT`**; `_Hidden.ping` effective domain `public` via `neither` | 8 |
| **7** skip the construct membership check | the withheld-construction arm | `privowner_construction_withheld` → **`ACCEPT`**; `CONSTRUCT_NOT_GRANTED` unexercised | 2 |
| **8** add a ninth return to `decide()` | the derived inventory | surface reads **9 categories**; `SPURIOUS_CATEGORY` flagged unexercised | 1 |
| **9** withhold a mode the subject has no key for | the withholding guard | "nothing was withheld and the arm would prove nothing"; the arm then → `ACCEPT` | 3 |

Each mutation was reverted and the suite re-run green in the same transcript, so
the failures are attributable to the mutation and not to a broken tree.

**Mutation 8 is the one that settles the inventory question.** Adding a return
`decide()` could produce but no arm exercises makes the surface read **nine**
categories and fails on the new one. A hand-written set would have stayed at
eight and noticed nothing — which is precisely how `CONSTRUCT_NOT_GRANTED`
shipped unexercised while the gate reported full coverage.

**Mutation 9 keeps the new withholding machinery honest.** `withhold_modes` is
how the ungranted categories are reached, so a withhold that removes nothing
would make those arms vacuous. Pointed at a mode the subject has no key for, the
scorer says so and the arm then wrongly accepts.

**The two owner mutations fail in opposite directions, which is the point.**
6a is the round-1 defect exactly: compare the *member's* domain and a legitimate
same-library access is **refused**. 6b drops the owner instead, and the same
declarations become wholly public — so a patch scoped to `helper.dart` is
*accepted* against `app.dart`'s private class. One direction blocks valid
patches; the other authorises invalid ones. 6b also **passes** the
count-agreement assertion while being wrong (`4 effectively-private of 18` —
internally consistent, and wrong); what catches it is the `_Hidden.ping` row
check and the foreign-scope arms.

**Three more rows say something the arms alone would not.**

*Mutation 1 does not break the cross-library arm.* With every private collapsed
into one domain, `cross_library_private` still reports `CROSS_DOMAIN_PRIVATE` —
refusing for a reason that is now accidental. The **domain-distinctness check**
and the positive controls catch it. An arm that only asks "was it refused?"
would pass a map with no library scoping at all. (The *class*-level distinctness
check still passes here, because class domains come from
`Class.enclosingLibrary` rather than the mutated member rule — the two
derivations are independent, and the transcript shows it.)

*Mutation 3 is the sharpest.* Ignoring one boolean turns the private write into
**`ACCEPT`** — a write authorised purely on the strength of a read grant.

*Mutation 4 still refuses.* Dropping the platform rule leaves the platform arm
refusing, just as the wrong category. Only scoring on category catches it.

## The category inventory is derived from the policy, not written beside it

Round 2 shipped an exhaustion check that read:

> every category the policy can return must be exercised

with a **hand-written set of five**, while `decide()` could return **eight**.
`READ_NOT_GRANTED`, `CONSTRUCT_NOT_GRANTED` and `NO_SUCH_MODE` sat outside the
check entirely — so the newest category, added in the same round as the
`construct` mode, had no arm and the gate still reported that every category was
covered. A hand-maintained inventory is exactly how a harness comes to overstate
itself.

The inventory is now **read out of `decide()`'s own source**: its AST is parsed,
every `Return` in the function is resolved against the module's constants, and
the resulting set is the inventory. It cannot drift from the policy, because it
is derived from it. It is fail-closed too — a return the reader cannot resolve
to a literal aborts the scorer rather than being quietly dropped from the set.

The check now runs in both directions: a category in the surface that no arm
produced fails, and an outcome produced that is not in the surface fails.

### Retaining a thing and granting it are different facts

Reaching the ungranted categories needed a way to say "the release retained this
and did not grant it". That is not hypothetical — the shipped manifest carries
`constructionWithheld` and `refused` lists for precisely this — so a case may
name `withhold_modes`, and the scorer removes that subject's own key for those
modes from the synthetic manifest.

The withholding is itself guarded: naming a mode the subject has no key for
fails the case, because nothing would have been withheld and the arm would prove
nothing.

Three arms complete the surface, each a minimal pair against an accepted case:

    privowner_construction_withheld  construct  CONSTRUCT_NOT_GRANTED
    privowner_read_withheld          read       READ_NOT_GRANTED
    privowner_write_final_field      write      NO_SUCH_MODE

`NO_SUCH_MODE` is deliberately not `WRITE_NOT_GRANTED`: `seed` is `final`, so no
write mode exists for anyone. "This cannot be written at all" and "this write
was not granted by this release" have different remedies, and collapsing them
would send a patch author looking for a grant that could never exist.

## Parity with G1

The identity is **recomputed** in this tool rather than imported, and compared
against G1's own tool on the same input: **23 shared declarations, 0
disagreements**. Shared code would make the check prove nothing.

`DECLARATION_ID` stays identity-only. Privacy is a separate set of columns, per
the separation G2's acceptance fixed.

## Acceptance (#52)

- [x] Privacy domain is derived for every declaration in the corpus — from
      `Name.isPrivate` / `Name.libraryReference` for members and from
      `Class.name` + `Class.enclosingLibrary` for classes, with the derivation
      recorded per row and any unrecognised derivation failed
- [x] Member privacy and owner privacy are recorded **separately**, and the
      effective domain is derived from them with its source named — a public
      member of a private class is access-controlled by the owner
- [x] Read and write capability are distinguished, not merged — and where the
      shipped key *cannot* distinguish them, the map says so and refuses the write
- [x] Each adversarial arm refuses with an attributable reason — seven distinct
      refusal categories, most of them minimal pairs against an accepted control
- [x] Every category the policy can return is exercised, against an inventory
      **derived from the policy's own source** rather than maintained beside it
- [x] The guard-presence assertion runs before the platform-library arm is
      trusted — and `run_g3.sh` refuses to score without it

## What round 1 got wrong

Three defects, all in the same place, and the corpus is what hid them: the
frozen base corpus contains **no private class**, so the entire owner path was
unexercised while the gate reported green.

1. **A public member of a private class was refused as cross-domain.** The
   policy compared the member's own domain (`public`) against the grant scope.
2. **The synthetic grant set omitted those members.** Keys were collected where
   `is_private` was true, so even a fixed comparison would have failed
   `READ_NOT_GRANTED`.
3. **A class's derivation claimed a Kernel fact that does not exist.** A `Name`
   was synthesised from `cls.name` and the row carried the member rule's label.

A fourth surfaced while fixing them: the constructor had **no** capability mode,
so constructing a private class reported `NO_SUCH_MODE`. Construction is its own
mode in the shipped manifest, and now in the map.

Round 2 then shipped a fifth, in the harness rather than the model: the
exhaustion check carried a hand-written set of five categories against an
eight-way policy surface, so the `construct` mode's own refusal category had no
arm while the gate reported full coverage. The inventory is now derived from
`decide()`'s source.

None of this changes the guard evidence or the six original arms, which are
unmodified. The corpus gained `g3_privowner`; the base corpus stays frozen.

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
