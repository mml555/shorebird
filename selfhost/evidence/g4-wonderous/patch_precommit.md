# §4 Wonderous — PATCH arm, outcomes precommitted BEFORE the run

Written before `shorebird patch ios` is invoked. **Do not edit this table to match
reality.**

## The question

Release 88 proved a real third-party app **builds** a Route B release, and reported
**17,736 patchable call sites**. That number is a count of sites the producer
*identified*; it says nothing about whether a patch to one of them is accepted,
compiles, and links. This arm asks the next question and only that one:

> Does the producer accept, build and publish a patch to a real third-party app?

## Target — chosen for reachability, not convenience

`StringUtils.getYrSuffix(int yr)` at `lib/logic/common/string_utils.dart:60`.

```dart
static String getYrSuffix(int yr) => yr < 0 ? $strings.yearBCE : $strings.yearCE;
```

**Why this one.** It has **6 live call sites** and its result is rendered directly
into `Text(...)` widgets (e.g.
`expanding_time_range_selector.dart:151,158,178`), so it is on a path the app
actually takes and is *displayable* — which keeps a later device arm constructible.
It also carries an `int` parameter, so it exercises the parameter ABI on real
third-party code rather than on the acceptance fixture.

**A deliberately rejected candidate, recorded because it is the trap.**
`StringUtils.truncateWithEllipsis(int, String)` looked ideal and has **zero callers**
in `lib/`. §16's lesson is exactly this: *consumption is necessary but not
sufficient — reachability is a separate property, and no byte-level gate can see
it.* A patch to dead code could report success while proving nothing, and might not
even survive tree-shaking into the release.

## Patch body

```dart
static String getYrSuffix(int yr) => yr < 0 ? 'BCE-PATCHED' : 'CE-PATCHED';
```

Literals only — no `$strings` global — so the replacement is self-contained and any
refusal is about the MECHANISM rather than about an unresolvable reference.

## Precommitted outcomes

| # | observation | verdict |
|---|---|---|
| 1 | patch builds AND publishes against release 88 | **The producer accepts a patch to a real third-party app.** The strongest claim available without a device. Says NOTHING about whether the patched code runs |
| 2 | the CLI/analyzer REFUSES, naming a specific reason | **A real finding, and a good one** — it names where the boundary falls on real code rather than on the fixture. Record the reason verbatim; a refusal citing the parameter or a resolution failure is a different result from one citing an unsupported spelling |
| 3 | the toolchain fails — `gen_snapshot`, linking, `dart2bytecode` | a MECHANISM failure, distinct from a producer refusal. Record which stage and the exit code |
| 4 | patch publishes but the container carries **no replacement**, or a zero/near-zero replacement for `getYrSuffix` | **FALSE GREEN — this is the outcome to hunt for.** A published patch that replaces nothing would look identical to success in the CLI output. Inspect the artifact for a named replacement before banking anything |
| 5 | patch fails because the release's artifacts cannot be fetched or the app/release is not found | **NOT a §4 result** — a rig/plumbing failure. Say so rather than reporting a producer limit |

## Anti-false-green rule

Outcome 1 is the favourable one and therefore the one to interrogate. Before banking
it, confirm:

1. the published patch **names `getYrSuffix`** in its replacement set;
2. the replacement is non-trivial (a byte size and a lowered signature, not an empty
   body);
3. the patch was cut against **release 88** specifically, not a re-cut release.

## Not claimed by this arm, whatever the result

Nothing about runtime. The release was built `--no-codesign` and cannot be installed,
so **no device arm is constructible from it** and no statement about the patched code
executing is available here.

---

# ADDENDUM — the discriminating arm, precommitted 2026-08-14 after arm 1's refusal

Arm 1 hit **outcome 2**: `StringUtils.getYrSuffix` refused, *"the bytecode compiler
refused its replacement body (exit 254)"*, whole patch refused, nothing uploaded.

`getYrSuffix` is **static**. §3's proven surface is **instance** methods. That is a
hypothesis, not a conclusion, and one run separates it.

**Arm 2 target:** `SearchData.write()`
(`lib/logic/data/wonders_data/search/search_data.dart:16`) — an *instance* method
returning `String`, patched to a pure literal so the body shape matches arm 1's as
closely as possible. The only deliberate variable is static vs instance.

| observation | meaning |
|---|---|
| arm 2 PUBLISHES | **the boundary is static-vs-instance.** Static methods are refused by the bytecode compiler while instance methods are accepted — so the 17,736 call-site count materially overstates the patchable surface |
| arm 2 refused with the SAME "bytecode compiler refused" message | static-ness is **NOT** the discriminator. Something broader about this app or this body shape is being refused, and the next question is what |
| arm 2 refused citing "not in the interface" / not found | **a DIFFERENT failure** — the target was tree-shaken out of the release (`write()` is called only from `lib/_tools/`). Says nothing about static vs instance; the arm is void and needs a live target |

Known weakness, recorded before the run: `write()`'s only call site is in
`lib/_tools/artifact_search_helper.dart`, so it may not survive into the release.
That outcome is listed above precisely so it cannot be read as either of the others.
