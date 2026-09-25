# Mutable-AOT — production risk register

Open items that are **decided**, not open questions awaiting more measurement.

## R1 — `gen_kernel` startup cost: UNRESOLVED

> Positive signal weakened under interleaving; the replication lacked the
> resolution to exclude a single-digit startup cost.

| | dataset 1 (`92589f5e5`) | dataset 2 (`d1de3374d`) |
|---|---|---|
| effect median | +7.17% | +3.03% |
| direction | 11+ / 1- | 8+ / 4- |
| floor envelope | 6.17% | 36.23% |
| effect block load | 140.7 - 167.9 | 163.2 - 200.4 |
| floor block load | 115.5 - 137.6 | 163.2 - 200.4 (same rotation) |

**Why it is not closed either way.** Dataset 1's separation was produced with
the floor measured on a materially quieter machine than the effect -- a known
bias toward finding an effect. Dataset 2 removed that confound by interleaving,
and the signal weakened in both magnitude and direction. But dataset 2's floor
widened to 36.23%, which cannot discriminate an effect in the single-digit
range, so it does not establish absence either.

The "inside the floor implies environmental variance" branch is **not** applied
here: that branch implicitly requires a floor capable of resolving the effect
under test, and this one was not.

**Disposition.** No further benchmarking. Both datasets stand; neither
supersedes the other. Carried as a production risk.

**What would change it.** A startup measurement on a host whose contemporaneous
floor is narrow enough to resolve single-digit percentages -- i.e. a quiet,
dedicated machine, not this shared rig. Not scheduled.

**Bounding context.** Only `gen_kernel` shows it. `nst` startup is clear in both
datasets (+1.77% then -1.12%, direction 7/5 then 6/6). `smith` startup was
valid but unresolved at a 20.87% floor. Two of five applications have no
measurable startup invocation at all.

## R2 — iOS ARM64 and Android ARM64 production replacement smoke: NOT RUN

Required before global-default readiness by an earlier ruling, and not
satisfied by any host measurement. Not benchmarking -- a correctness smoke.

Hardware is present and was verified: `iPhone9,1` on iOS 15.8.8 over USB,
and `CPH2551` on Android 16 `arm64-v8a` over adb.

Two concrete blockers, both checked rather than assumed:

* `Flutter.framework` exports exactly one `Dart_` symbol,
  `_Dart_RouteBActivatePatchTraced`. The `Dart_Maot*` entry points are exported
  only from the standalone runtime via `runtime/bin/BUILD.gn`'s `-Wl,_Dart_*`,
  so `DynamicLibrary.process()` on device finds nothing today. That single
  existing export is the precedent for adding one; it is a symbol-list change,
  not a dispatch change.
* The iOS engine output predates every MAOT runtime change. It does share this
  fork -- there is one Dart checkout at `src/flutter/third_party/dart` -- so a
  rebuild picks the sources up. **Android has no `out/android_*` directory at
  all** and needs a configure plus full build.

## R3 — Size cost is density-dependent, not a single percentage

Established, not a risk to resolve -- a fact to carry into the policy decision.

`286.8 B per selected declaration`, stable within +-0.63 pp across five
applications spanning a 23x size range. The percentage is set by selection
density, from +0.27% (`smith`, 45 selected/MB) to +9.26% (`analysis_server`,
321 selected/MB).

Any default-policy discussion should use **bytes per selected declaration plus
expected selection density**, never a single "Mutable-AOT costs X%" figure.

## R4 — `#68` constant-inference escapes observed in the wild

Four distinct declarations across the five-application population, fail-closed
and refused rather than shipped installable. One in `dart2wasm`, three in
`analysis_server`. Identities recorded in `STAGE47-POPULATION.md`.

Not a defect. Watch the population; investigate only if it grows.
