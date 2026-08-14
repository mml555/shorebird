# A1 — Android build-configuration compatibility enforcement

> At the end, a patch whose **effective build configuration** differs from its release is refused on Android **before any patch artifact exists**, the refusal is provoked by a regression that cannot be satisfied by app routing, and the before-fix product-gap specimen is still on the device to compare against.

| field | value |
|---|---|
| status | **DESIGN ONLY — nothing implemented.** The architecture questions below are answered from measurement; the code is not written |
| owns | `packages/shorebird_cli` (code + tests). No device, no mint, no CDN. `R2` only if the lane chooses to re-prove on hardware, which it does not need to |
| excludes | anything that would disturb the preserved negative specimen (see *Do not*), and any change to the on-disk provenance JSON shape |
| blocked by | nothing |
| unblocks | the PARITY row *"release `--flavor foo`, patch `--flavor bar` → REFUSED"* actually meaning what it says on Android |
| device needed | no |
| mint needed | no |

**Provenance.** Written 2026-08-14 directly after the gap was measured on hardware.

**Read the anchors before trusting them, and this time there is a specific reason.** They were
taken from the WORKING TREE at `efa31f3b` while a concurrent lane held **uncommitted** edits to
`patch_command.dart`, `release_command.dart` and four other files. So the `patch_command.dart`
line numbers in Q2 describe a state that was not committed and will move when that lane lands.
The *order* of the steps is the durable claim; the numbers are a convenience. Re-locate by
grepping the quoted code (`maybeGetReleaseArtifact`, `Download and extract the supplement
archive`, `patcher.buildPatchArtifact(releaseVersion`, `patcher.createPatchArtifacts(`) rather
than by line.

## The gap this closes, stated once

> Android patching does not currently enforce Route B effective build-configuration
> compatibility. A patch built for flavor `bar` can be published against a `foo` release and
> execute on device, changing the runtime flavor identity.

Measured 2026-08-14, both arms, `evidence/android/g42-flavor/`:

| setup | result | what actually refused |
|---|---|---|
| two `app_id`s | exit 70 `Release not found` | **`app_id` routing** (`shorebird_yaml.dart:69-72`) — says nothing about configuration |
| one `app_id` | **exit 0, patch published**, applied on device | **nothing** |

`RouteBBuildConfig` hits in `android_patcher.dart`: **0**.

## Q1 — where can Android obtain the release's effective config?

**Answer: the release supplement. The carrier already exists on both sides and is already
platform-neutral.**

* `android_releaser.dart:35` `supplementPlatformSubdir => 'android'`
* `android_releaser.dart:38` `supplementArtifactArch => 'android_supplement'`
* `android_patcher.dart:71` `supplementaryReleaseArtifactArch => 'android_supplement'`

So nothing new has to be invented, transported or registered. **One thing must change:** the
supplement is assembled by the *shared* base class and is gated on obfuscation —

```dart
// releaser.dart:227-234 (the gate is :232)
Directory? assembleSupplementDirectory() {
  final hasObfuscationMap = useObfuscation && obfuscationMapFile.existsSync();
  final supplementDir = artifactManager.getReleaseSupplementDirectory(
    platformSubdir: supplementPlatformSubdir,
    create: hasObfuscationMap,          // <-- today: no map, no supplement at all
  );
  if (supplementDir == null) return null;
```

— so an **unobfuscated** Android release ships no supplement, and therefore has nowhere to
put a build config. The gate must widen from "create when there is an obfuscation map" to
"create when there is anything to record", with the build config always being something to
record.

> **Why not a new artifact arch.** A second arch means a second upload, a second download, a
> second failure mode, and a protocol change. The supplement is already fetched on the patch
> side for every platform that declares one, and is already the place the obfuscation map and
> the Route B interface travel. Adding a file to an existing carrier is strictly smaller than
> adding a carrier.

## Q2 — at what point can the patcher refuse, before producing or uploading a patch?

**Answer: in `patch_command._buildPlatformPatch`, immediately after the supplement is
extracted — and that is EARLIER than iOS currently manages.**

Measured order inside `createPatch` / `_buildPlatformPatch` (`patch_command.dart`):

| line | step |
|---|---|
| `:604` | `maybeGetReleaseArtifact` (**supplement**) |
| `:612` | `downloadReleaseArtifact` (release archive) |
| `:620-639` | **extract the supplement**, pick up `obfuscation_map.json` |
| `:813` | `patcher.buildPatchArtifact(...)` ← **the patch build** |
| `:835` | `assertUnpatchableDiffs` |
| `:841` | `patcher.createPatchArtifacts(...)` ← **artifacts produced** |

The insertion point is **immediately after `:639`** (the close of the extraction block): the
release's supplement is on disk, and
nothing has been built, diffed, bundled or uploaded. That satisfies the invariant *"mismatch
refusal happens before container/artifact production"* in its strongest form — before the
patch **build**, not merely before the container.

> **A CORRECTION THIS LANE SHOULD CARRY, because it will confuse the next reader.**
> `ios_patcher.dart` places its own `_verifyBuildConfigAgrees` inside `createPatchArtifacts`
> and explains: *"the release supplement, and so the release's provenance, is not downloaded
> until after that build."* That is true **of the patcher**, which only receives
> `supplementDirectory` as a `createPatchArtifacts` argument. It is **not true of
> `patch_command`**, which has the extracted supplement by `:639`, ~174 lines before `:813`. So iOS
> is checking later than it needs to. Moving it is **not this lane's job** — but the comment
> should stop asserting an impossibility that is only an artifact of where the check was put.

## Q3 — reuse `RouteBBuildConfig`, or promote it?

**Answer: promote the NAME and the placement; keep the TYPE and the on-disk shape exactly.**

What argues for reuse as-is:

* its content is already platform-neutral in substance — `effectiveDefines`, `obfuscate`,
  `flavor`, `canonicalForm` (`route_b_build_config.dart:241-248`), `fingerprint`, `agreesWith`;
* the platform-specific part is the **flavor value**, and that is already a caller-supplied
  parameter (`fromBuildArgs(..., flavor:)`), which is exactly how iOS's scheme-casing and
  Android's CLI-token spellings coexist without the type knowing about either;
* `canonicalForm` deliberately excludes `splitDebugInfoPath` *on evidence*, and that reasoning
  is platform-independent.

What argues for promotion:

* the name says `RouteB`, and Android's diff path is **not** Route B — a reader hitting
  `RouteBBuildConfig` in `android_patcher.dart` will reasonably conclude the file is in the
  wrong place;
* it is referenced in 5 files today, all iOS/Route B, so the rename is small **now** and grows
  with every platform that adopts it.

**Hard constraint on any promotion:** `toJson`/`fromJson` must stay byte-compatible. Existing
iOS releases carry `route_b_provenance.json` with a `buildConfig` object
(`route_b_provenance.dart:162-171`), and a key rename would make every already-published
release unreadable to a newer CLI — turning a refactor into a compatibility break. Promote by
introducing the neutral name and keeping the serialized shape and `canonicalForm` string
identical, so a fingerprint computed before the change equals one computed after.

## Invariants this lane must preserve

1. `effectiveDefines`, **including the synthesized `FLUTTER_APP_FLAVOR`**, stay semantic —
   they are what compatibility is decided on.
2. Raw `--flavor` provenance stays **audit-only** (`route_b_build_config.dart` records
   `flavor` beside `rawArgs`; `canonicalForm` does not read it directly).
3. Mismatch refusal happens **before** container/artifact production — per Q2, before the
   patch build.
4. A **matching** effective config continues through to a real Android patch. The fix must not
   turn the working same-flavor path into a refusal; G4.2's B4 arm is the guard.
5. The current mismatched `bar` patch on `dev.selfhost.flavorprobe.foo` stays intact as the
   **before-fix specimen**.

## The regression that matters

```
one app_id · release --flavor foo · patch --flavor bar
  -> REFUSED for effective-config mismatch, before any patch artifact exists
```

**It must not involve app routing.** The two-`app_id` shape already produced a right-looking
refusal for the wrong reason (`Release not found`), and banking that would re-close the arm
without testing anything. The regression therefore pins:

* one `app_id` shared by both flavors, so routing cannot refuse;
* the refusal names the **configuration difference**, not the app or the release;
* it fires **before** `buildPatchArtifact` — assert no patch artifact was produced, not merely
  that the command exited non-zero;
* a **negative control**: same flavor both sides still succeeds (invariant 4).

## Precommitted outcomes

| observation | meaning |
|---|---|
| ⚠ the wrong-flavor patch is refused and the test passes first try | check **where** it refused. If the message mentions the app or the release rather than the configuration, it is routing again and proves nothing |
| refusal happens, but after `buildPatchArtifact` | the check landed in the patcher rather than in `patch_command`; correct but weaker than Q2 allows, and invariant 3 is only half met |
| same-flavor patch starts failing | invariant 4 broken — the canonical form is reading something it should not, most likely raw `--flavor` instead of the synthesized define |
| existing iOS releases stop being patchable | the on-disk shape moved. Revert the serialization, keep the rename |
| an unobfuscated Android release still ships no supplement | Q1's gate was not widened; the config has nowhere to travel and every later arm is vacuous |

## Do not

* **Do not clear `dev.selfhost.flavorprobe.foo` on `R2`.** It is running the mismatched `bar`
  patch and is the before-fix demonstration. Same for the other two specimens recorded in
  `R2`'s claims row.
* **Do not delete patch 2 on app `cd447816…`.** It *is* the evidence.
* **Do not copy `ios_patcher._verifyBuildConfigAgrees` verbatim.** Its placement is a
  consequence of the patcher-level vantage described in Q2, not a design choice worth
  inheriting.
* **Do not change the provenance JSON keys** — see Q3's hard constraint.
* **Do not stage broadly.** A second session is committing to this tree; stage explicit paths.
