<!-- cspell:words widnows -->
<!-- "widnows" is a deliberate misspelling below: an example of the typo the
     free-form `platform` field accepts. Not a word, so not in the global
     dictionary. -->

# Shorebird Per-Platform Artifact Matrix (self-host control plane)

Derived from the CLI source (`packages/shorebird_cli`) + protocol
(`packages/shorebird_code_push_protocol`). This is the complete set of
`platform` / `arch` / filename / `can_sideload` / supplement tuples a
self-hosted control plane must accept on **release-artifact register**,
**patch-artifact register**, and **device `/patches/check`**.

We have only exercised **android + ios arm64**. Everything else below is
untested against our server.

## Key facts up front

- **`ReleasePlatform` wire enum** (`release_platform.dart`) has exactly **5**
  values: `android`, `ios`, `linux`, `macos`, `windows`. There is **no**
  separate wire platform for AAR or iOS-framework add-to-app.
  - `ReleaseType.aar` → `ReleasePlatform.android` (wire `android`)
  - `ReleaseType.iosFramework` → `ReleasePlatform.ios` (wire `ios`)
  So add-to-app releases are distinguished **only by the `arch` string**
  (`aar` vs `aab`, `xcframework` vs `xcarchive`) under a shared `platform`.
- **`Arch` enum** (`platform/platform.dart`) arch strings: `arm32`→`arm`,
  `arm64`→**`aarch64`**, `x86_64`→`x86_64`. (Apple/desktop patchers hardcode
  the string `aarch64`, not the enum name.)
- The `arch` field on the wire is an **opaque catch-all**: it carries real ABI
  names (`arm`, `aarch64`, `x86_64`) *and* bundle/kind tags (`aab`, `aar`,
  `xcarchive`, `runner`, `xcframework`, `app`, `win_archive`, `bundle`) *and*
  supplement tags (`android_supplement`, etc.) — all in the same column.

## Matrix

### RELEASE artifacts registered (`createReleaseArtifact`, arch / can_sideload / podfile_lock_hash)

| Release type | wire `platform` | arch values registered | can_sideload | podfile_lock_hash | source |
|---|---|---|---|---|---|
| **android** | `android` | `arm`, `aarch64`, `x86_64` (per-ABI `libapp.so`, only ABIs the build produced) → `false`; `aab` → `true`; `android_supplement` (obfuscated only) → `false` | mixed | null | `createAndroidReleaseArtifacts` |
| **ios** | `ios` | `xcarchive` → `false`; `runner` → **`isCodesigned`**; `ios_supplement` (obfuscated only) → `false` | mixed | **set on `xcarchive`+`runner`** | `createIosReleaseArtifacts` |
| **macos** | `macos` | `app` → `true`; `macos_supplement` (obfuscated only) → `false` | true | **set on `app`** | `createMacosReleaseArtifacts` |
| **windows** | `windows` | `win_archive` → `true`; `windows_supplement` (obfuscated only) → `false` | true | null | `createWindowsReleaseArtifacts` |
| **linux** | `linux` | `bundle` → `true`; `linux_supplement` (obfuscated only) → `false` | true | null | `createLinuxReleaseArtifacts` |
| **aar** (add-to-app) | `android` | `arm`, `aarch64`, `x86_64` (per-ABI `libapp.so`) → `false`; `aar` → `false`; `aar_supplement` (obfuscated only) → `false` | false | null | `createAndroidArchiveReleaseArtifacts` |
| **ios-framework** (add-to-app) | `ios` | `xcframework` → `false`; `ios_framework_supplement` (obfuscated only) → `false` | false | null | `createIosFrameworkReleaseArtifacts` |

> **ADD-TO-APP-1 (2026-09-03): neither add-to-app row is usable on the frozen
> stack, and both were measured.** `shorebird release ios-framework` fails in
> `flutter build` — the cell publishes a device-only `Flutter.xcframework` — and
> even given the artifact, the control plane refuses to ACTIVATE a release whose
> only arch is `xcframework` (or `aar`), because `Api._requiredArchs` gates on
> the full-app sets. Route B is not implemented for `ios-framework` at all. See
> [`evidence/addtoapp1/RESULT.md`](evidence/addtoapp1/RESULT.md). The rows below
> describe the WIRE SHAPE, which is unchanged and still correct.

Supplement arch strings per releaser (`Releaser.supplementArtifactArch`):
`android_supplement`, `ios_supplement`, `macos_supplement`,
`windows_supplement`, `linux_supplement`, `aar_supplement`,
`ios_framework_supplement`. The supplement is a **separate, later** network
call (`uploadSupplementArtifact`) and is only uploaded when an obfuscation map
exists. It is a normal release artifact row (so it counts toward "all
verified" — see server audit).

### PATCH: primary release artifact downloaded to diff, and patch arch(es) registered

The patch command downloads `patcher.primaryReleaseArtifactArch` as the
"release archive" for the unpatchable-diff check + release-version extraction,
plus `supplementaryReleaseArtifactArch` (the supplement) when present.
Android/AAR additionally download **every per-ABI `libapp.so` release
artifact** inside `createPatchArtifacts` to diff each ABI.

| Patcher | primary release arch downloaded | supplementary arch | patch arch(es) registered | notes |
|---|---|---|---|---|
| **android** | `aab` | `android_supplement` | `arm`, `aarch64`, `x86_64` diffs (only ABIs present) | multi-arch patch |
| **ios** | `xcarchive` | `ios_supplement` | **`aarch64`** only, with `podfile_lock_hash` | single-arch |
| **macos** | `app` | `macos_supplement` | **`aarch64` AND `x86_64`**, both with `podfile_lock_hash` | **multi-arch patch (both must upload/verify)** |
| **windows** | `win_archive` | `windows_supplement` | **`x86_64`** only | ⚠ release arch (`win_archive`) ≠ patch/device arch (`x86_64`) |
| **linux** | `bundle` | `linux_supplement` | **`x86_64`** only | ⚠ release arch (`bundle`) ≠ patch/device arch (`x86_64`) |
| **aar** (add-to-app) | `aar` | `aar_supplement` | `arm`, `aarch64`, `x86_64` diffs | multi-arch patch |
| **ios-framework** (add-to-app) | `xcframework` | `ios_framework_supplement` | **`aarch64`** only | reads `ios-arm64` slice |

### Device `/patches/check` — the `arch` the updater sends per platform

The device requests a patch artifact by **(`arch`, `platform`)**, and it must
match a **patch** artifact row exactly. The `arch` the updater sends:

| platform | device `arch` value(s) |
|---|---|
| android | `arm` / `aarch64` / `x86_64` (the device's ABI) |
| ios | `aarch64` |
| macos | `aarch64` (Apple Silicon) or `x86_64` (Intel) |
| windows | `x86_64` |
| linux | `x86_64` |

Note the desktop cases: the device asks for `x86_64`, which is the **patch**
arch — never the release-side `win_archive` / `bundle` tag. Any server code
that assumed "the release artifact arch == the check arch" would break on
Windows/Linux.

---

## Server audit — `packages/code_push_server/lib/src/{api,repository}.dart`

**Headline: the server storage + lookup layer is already fully platform- and
arch-agnostic.** A grep of `lib/` for `aarch64|arm64|android|ios|x86_64|
xcarchive|libapp|aab|win_archive` returns **zero hits** — there are no
hardcoded arch or platform literals anywhere in the server. `arch` and
`platform` flow through as opaque strings:

- `createArtifact` (`repository.dart:627`) stores `arch`/`platform` verbatim
  from the multipart fields; register handlers `_createReleaseArtifact`
  (`api.dart:406`) and `_createPatchArtifact` (`api.dart:426`) pass them
  through without any whitelist.
- `patchArtifact(patchId, arch, platform)` (`repository.dart:706`) looks up by
  `(owner_id, arch, platform)` — correct and generic for every platform/arch,
  including macOS's two arches and the desktop `x86_64` case.
- `_patchesCheck` (`api.dart:611`) reads `arch`+`platform` from the body and
  looks up the patch artifact by that pair (`api.dart:660`). No platform
  branching. Works for all 5 wire platforms as-is.
- `_maybeMarkPatchReady` (`api.dart:538`) marks a patch `ready` only when
  **all** its artifact rows are verified — so macOS's 2-arch patch correctly
  won't go ready until both `aarch64` and `x86_64` are uploaded. Multi-arch
  patches are already handled.

So the "we only did android+ios arm64" gap is **not** blocked by hardcoded
assumptions. The gaps that remain are these:

### Server changes needed for full platform parity (checklist)

1. **[correctness — top priority] Scope the release-finalize "all artifacts
   verified" check by platform.** `_updateRelease` (`api.dart:380-388`) calls
   `repo.releaseArtifacts(releaseId)` **with no platform filter**, then requires
   every non-failed artifact of the *entire release row* to be `verified`
   before activating. But the finalize is per-platform (`body['platform']` is
   already in scope and used at `api.dart:379`). Because one release row
   (UNIQUE `app_id`+`version`) can hold artifacts for multiple wire platforms
   at the same version (android+ios, or add-to-app `aar` sharing `android`,
   `ios-framework` sharing `ios`), activating platform A is wrongly gated on
   platform B's artifacts all being verified. Fix: pass `platform:` into
   `repo.releaseArtifacts(releaseId, platform: platform)` — the repo method
   (`repository.dart:683`) already supports the filter. This is the change most
   likely to bite as soon as a self-host releases more than one platform at a
   single version.

2. **[robustness] No `(owner_id, arch, platform)` uniqueness on `artifacts`.**
   The `artifacts` table (`repository.dart:228`) has no unique constraint
   beyond `token`. The real Shorebird server returns 409 on a duplicate
   register (the CLI explicitly catches `CodePushConflictException` and prints
   "… already exists, continuing" in `createAndroid/AndroidArchive…`). This
   server silently inserts duplicates instead, so a re-run/retry of a release
   creates shadow artifact rows. Multi-arch platforms (android/aar per-ABI,
   macOS 2-arch) and the shared-`platform` add-to-app cases (`aab`+`aar` both
   under `android`; `xcarchive`+`xcframework` both under `ios`) make collisions
   more likely. Add a unique index and have register return 409 on conflict, or
   upsert.

3. **[correctness] `_getReleaseArtifacts` picks `.first` on the CLI side.** The
   CLI's `getReleaseArtifacts` fetches by `(arch, platform)` and takes
   `artifacts.first`. Combined with (2), duplicate rows make the chosen
   artifact nondeterministic. Fixing (2) resolves this; no separate server
   route change needed, but worth verifying once dupes are prevented.

4. **[validation, optional] No arch/platform whitelist on register.** Because
   `arch`/`platform` are free-form, a typo (`platform=widnows`) is accepted and
   only surfaces later as a device that never finds its patch. Optional: reject
   unknown `platform` values (the 5 `ReleasePlatform` wire values) at register
   time. Do **not** whitelist `arch` — the set is open-ended (`aab`, `aar`,
   `xcarchive`, `runner`, `xcframework`, `app`, `win_archive`, `bundle`,
   supplements, plus real ABIs) and adding a whitelist would be more fragile
   than helpful.

5. **[verify, not a code change] `store.verify` hashes only release artifacts.**
   `_upload` (`api.dart:523`) calls `store.verify(..., checkHash: art.ownerKind
   == 'release')`. This is arch/platform-independent and fine for all platforms;
   noted only so it isn't mistaken for an android-specific path. Confirm the
   desktop `win_archive`/`bundle` zips and the macOS `app` zip pass the
   size/hash verify the same way android's `aab` does (they should — the CLI
   computes the same sha256 over the uploaded bytes).

### What needs NO change

- `/patches/check` routing and `(arch, platform)` patch lookup — generic.
- Multi-arch patch readiness (`_maybeMarkPatchReady`) — already all-must-verify.
- `podfile_lock_hash`, `hash_signature`, `can_sideload` columns — already
  present on `artifacts` and round-tripped by register + `_getReleaseArtifacts`
  + `_patchesCheck`, so iOS/macOS podfile-lock and code-signing metadata already
  flow through untouched.
</content>
</invoke>
