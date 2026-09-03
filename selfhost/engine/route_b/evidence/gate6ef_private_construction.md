# Gate 6E / 6F — private construction through the product path

Both gates ran the shipped `shorebird patch ios` end to end against release 142.
Nothing was hand-injected: no `--grant-constructor` on the command line, no
manual census, no compiler archive swapped after resolution.

## Frozen identities (both gates)

| thing | value |
|---|---|
| app | `2e628d42-26c8-d4be-e779-67b07edf1fed` (private-construction-6d) |
| release id / version | `142` / `1.0.3+4` |
| selector (flutter revision) | `e64eb0af52e1c43c3b21a39556d789538d0df9b3` (F4) |
| cell | `cd848320d605ff8af5060cabf9a8d1b35853f752` |
| compiler archive | `7975b27c724240e720f77d338c80fcace5296148bd78c17588cee1b089e3fb22` (19,256,864 B) |
| analyzer (consumed) | `67741a082fcde5a9e2067fdfad1deb7ad69cb89b8d23aba78ed31b5afb6c2f5d` |
| release App binary | `bbea5b9c72a6e25b7d20ba41abaafff9b0392da108b26f7ed673bb61489ff8b2` |
| CLI (6E) | `b68238500de7` |
| CLI (6F) | `6b4f6c422bab55143ef04c8f43f92015ee3b3feb` |

Release 142's manifest, derived by the product path from its own census
(policy p2), grants exactly three constructors and withholds none:

    package:super_fixture/main.dart#_Boxed.new
    package:super_fixture/main.dart#_Other.new
    package:super_fixture/main.dart#_PageState.new

## 6E — negative control: cross-method leakage is refused

`Specimens.negative()` was mutated to construct `_Other`, a class the manifest
DOES grant but which the RELEASE version of `negative()` never constructed.

The producer refused, after the earlier gates passed ("Verifying patch can be
applied… Done", "Extracting release artifact… Done"):

> its body constructs `_Other`, which the RELEASE version of this same method
> never constructed. A patch may reuse a private construction the released
> method already performed; it may not introduce a new one, even where some
> other released method constructed it.
> The whole patch is refused. … Nothing was uploaded.

That wording is only reachable on the branch where release-side evidence was
MEASURED and does not contain the key. The unmeasured case says "did not
measure" instead. So the refusal is itself the v13 reading: candidate side
carries `_Other.new`, release side for that method carries it not at all.

Nothing moved: patches for release 142 0 → 0; patch artifacts 114 → 114; max
patch id 105 → 105; patch object dirs 104 → 104; no patch-creation request in
the control-plane log.

## 6F — positive: a construction the released method already performed

`Specimens.positive()` still constructs `_Boxed`, exactly as the released method
did. The observable depends on the constructed object BEHAVING, not on a patch
merely being active — `_Boxed.render()` computes `value.length`:

    release : BOXED[9]:APP-STATE
    patch   : BOXED[11]:P:APP-STATE

Release-side evidence for that same method:

    privateConstructions: [{"class":"_Boxed","constructor":"new",
      "key":"package:super_fixture/main.dart#_Boxed.new","offset":1567}]

Published: **patch id 106, number 1**, promoted to stable, one iOS aarch64
artifact.

| artifact | sha256 | bytes |
|---|---|---|
| `replacement_0.dart` | `c66f20653979984d92acdf379345000c918b99e1fc340735a83839aabdee920a` | 619 |
| `replacement_0.bytecode` | `0a1f996faa483e2575a15c867df2cf3c3014aa34d928185b08bf3dbf3bd154bf` | 786 |
| `patch.sbrbptch` (uploaded) | `89052f9d0811fd4c591bdfffe1091b49525c7ff24c19b03db0380f2ee3a576d3` | 1891 local / 1187 stored |

Patch id 106 is exactly one past 6E's frozen ceiling of 105, so 6E uploaded
nothing and 6F uploaded exactly one patch.

## What 6F caught

The first attempt was refused with a bare `exit 254`. The grant for `_Boxed.new`
was present and the lowering was correct; dart2bytecode's own stderr said:

    replacement_0.dart:12:9: Error: Method not found: '_Boxed'.

Retention and the manifest grant make the constructor EXIST and be CALLABLE in
the shipped program. Neither says anything about whether the replacement —
compiled as a SEPARATE synthetic library — may SPELL a name private to the
target library. That second problem already had a solution,
`--resolve-private-names-in-library`, but its predicate keyed on private member
ACCESSES alone, and a construction-only body has none.

Fixed in `6b4f6c42`. This is not a broadening of the admission rule: admission
(same-method release evidence AND a manifest grant, per construction) runs and
refuses the whole patch before compile, unchanged, as 6E shows. It decides only
how an already-admitted body gets spelled.

The pre-existing test asserted the lowered SOURCE and nothing else, so it stayed
green across a body that could not compile. The new test asserts the compiler
ARGUMENTS and was verified red before the fix.

## Not yet established

6G — on-device activation — has not run. Nothing here shows the patch booting on
the iPhone 7; it shows it was produced, admitted, compiled and published.
