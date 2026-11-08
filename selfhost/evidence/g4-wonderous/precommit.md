# §4 Wonderous — outcomes precommitted BEFORE the run

Written before `shorebird release ios` is invoked, per the precommitment rule.
**Do not edit this table to match reality.** Record the result beside it.

## What is under test

§4's `KNOWN GAP` row: *"A Route B iOS release of a real third-party app does not
build: Wonderous fails its retention-interface annotation even at app-only breadth
(`get:_file` for `ThrottledSaveLoadMixin`, where the annotator's component has
`_file` bare)."*

The remedy — enumerate privates from the **non-AOT import kernel** — landed at
`cd453304`, so the row describes the tree before it. **What is owed is the RUN, not
the design.** This is that run.

## Identity

| field | value |
|---|---|
| app | `/Users/mendell/compat-corpus/wonderous` at `747b945` (`wonders` 2.2.7+236) |
| app_id | `589036b4-39ee-389b-c9fe-94fd42474a03` on `cps-ios` (`R8`) |
| CLI | the RIG CLI at `ba4e1c02`, which contains `cd453304`. It does **not** carry this branch's later commits; Wonderous is unflavored, so `f06fa056`'s flavor-spelling fix cannot affect the verdict |
| engine | cell `40eaa0ef6cb6485833bf2e10ac97224ca82cbf25`, per `~/.shorebird`'s stamp |
| auth | `SHOREBIRD_TOKEN` (API key), not OAuth — the rig CLI could not refresh a Shorebird-issued token |

## THE FALLBACK TRAP — the whole reason this table exists

`ios_releaser.dart` falls back to **prepass** enumeration whenever the import kernel
is missing or disagrees with the prepass, and **that fallback still produces a
release**. So a green build is consistent with both success and with the exact
silent narrowing that does not work on a real app.

> **"It built" is worth NOTHING on its own.** Read
> `build/shorebird/route_b/route_b_retention.json` FIRST and check
> `privateEnumerationSource`.

## Precommitted outcomes

| # | observation | verdict |
|---|---|---|
| 1 | build succeeds AND `privateEnumerationSource: "import"` | **THE GAP IS CLOSED ON THE PRODUCT PATH.** `cd453304` works on a real third-party app. Earns BUILT for the §4 row — not PROVEN, which needs the patch running on a device |
| 2 | build succeeds BUT `privateEnumerationSource: "prepass"` | **THE GAP IS NOT CLOSED**, and this is the outcome most likely to be misread. The release exists by falling back to exactly the enumeration §4 says does not work. Record the `fallbackReason` verbatim — it names which half failed |
| 3 | build FAILS at the retention-interface annotation (`get:_file` or any `<accessor>:<private>` shape) | **THE GAP REPRODUCES on the product path.** `cd453304` did not close it. A real finding and the most valuable failure available here |
| 4 | build fails for an unrelated reason — Xcode, signing, CocoaPods, Flutter version, Android tooling | **NOT A §4 RESULT.** Inconclusive; say so rather than reporting a gap that was never reached. `shorebird init` already failed on gradlew, so this branch is live |
| 5 | `route_b_retention.json` absent after a green build | **NOT a pass.** Means Route B did not run at all — check whether the release took the Route B path before interpreting anything |

## Anti-false-green rule

Outcome 1 is the favourable one and therefore the one to interrogate hardest. Before
banking it, confirm all three:

1. `privateEnumerationSource == "import"` and `fallbackReason` is null/absent;
2. the retention interface actually names private members (an EMPTY private set
   would make "import" true and meaningless);
3. the build consumed cell `40eaa0ef`, not a stock engine.
