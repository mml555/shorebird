# P4.1 — what the profile channel costs

`probes/p41_profile_cost.sh --all`, 2026-08-25. Implementation sizing, not
mechanism research: the channel was already chosen on the evidence in
`p41_measurement_note.md`.

Measured in the **iOS release shape** — `--snapshot_kind=app-aot-assembly` with
`--patchable_static_calls`, which is what `flutter_tools` actually invokes for
Apple targets. `bare` and `with` are the minimum of 3 `gen_snapshot` runs.

| app | binary B | bare ms | with ms | time delta | profile B | gzip B | prof/bin | gz/bin | nodes | edges |
|---|---|---|---|---|---|---|---|---|---|---|
| TOY container_target | 988,064 | 472 | 504 | +6.8% | 1,522,563 | 337,299 | 154% | 34% | 23,117 | 80,416 |
| REAL airgap_app (Flutter, TFA) | 6,011,504 | 3,700 | 3,935 | +6.4% | 8,877,444 | 1,841,304 | 148% | 31% | 117,673 | 468,839 |
| WIDE airgap + broad framework | 9,540,912 | 6,018 | 6,357 | +5.6% | 13,388,561 | 2,710,307 | 140% | 28% | 168,266 | 716,267 |

`binary B` is a real binary: the same `release.dill` snapshotted a second time as
an ELF, purely to have an honest denominator. The first run of this arm used the
**assembly text** as the denominator and reported 41.8%, which flattered the
profile roughly 3× — assembly text is about 3.4× the binary clang emits from it.
The corrected numbers are above.

## The precommitted threshold is tripped, and this note says so

The rule fixed before the run was: *profile > 25% of AOT bytes, or time delta >
25%, is pathological and reopens the channel choice.*

- Time: **not tripped.** +5.6% to +6.8%, and it shrinks as the app grows.
- Size: **tripped, and not marginally.** The profile is 140–154% of the binary —
  larger than the program it describes.

What the rule failed to capture is *where* the bytes go. Nothing extra ships to a
device: the profile is a build-time sidecar consumed once, by the producer, at
publication. In device-facing terms the cost is zero. In release-storage terms it
is 1.8 MB gzipped for a real Flutter app and 2.7 MB for a much wider one, against
release artifacts that are already larger than that.

So the size ratio, as written, was the wrong quantity to threshold — but that is
stated here rather than quietly reinterpreted, because the rule was precommitted
and it fired. **Whether that is acceptable is a product decision, not one this
arm gets to make.** If the answer is no, the fallback is a narrowed sidecar (only
the nodes and pool edges reachable from granted targets), which was never priced.

## Scaling

Stable across a ~10× binary-size range: 140–154% uncompressed, 28–34% gzipped,
+5.6–6.8% snapshot time, and gzip holds near 3.5:1 throughout. Profile size
tracks retained program size, so a 30 MB app extrapolates to roughly 40 MB
uncompressed / 8 MB gzipped and a still-single-digit time delta. That is an
extrapolation from three points, labelled as such.

## What stayed unmeasured, and why

`flutter_gallery` (20.5k lines of real app, in the pinned tree) was the intended
large data point. Every package in that tree declares `resolution: workspace`, so
pricing it needs a `pub get` at the root of the **pinned build tree** that cell
reproducibility depends on. Mutating that tree for a sizing number is not a
trade worth making, so the largest measured point is WIDE and a genuinely large
app remains unmeasured. A copy out of the tree was tried first and pub refused
it: *"it has resolution `workspace` … found no workspace root including it"*.

Also unmeasured: the cost inside a full `flutter build ios` (xcodebuild, dSYM,
asset bundling). The delta measured here is the whole cost of the flag, since
profile emission happens entirely inside `gen_snapshot`, so it can only shrink as
a fraction of a full release build.
