<!-- cspell:words idevicesyslog idevicescreenshot noninteractive premain -->

# Route B device evidence

Screenshots kept because the alternative is a claim with nothing behind it.
Standing rule from `MEDIA_PRESERVATION.md` applies here too: **store
verification output**. The first seam-6 pass was observed and then lost, and
re-running it cost two device launches — cheap that time, not always.

## seam 6 — native pre-main activation, 2026-08-10

| file | build | difference from the other arm | `route B value` |
|---|---|---|---|
| `seam6_patched.png` | 6.0.0+1 | `assets/routeb_patch.bytecode` **present** | **NEW** |
| `seam6_control.png` | 6.1.0+1 | that asset **absent** | **OLD** |

Everything else is held constant: same engine (`d393ed01`), same `main.dart`,
same `--patchable_static_calls` snapshot, same device
(`8cb4bc98…`, iPhone 9,1 / iOS 15.8.8), same launch path. The `pubspec.yaml`
delta between the two builds is three lines — the asset declaration and its
comment.

Both apps read the value **once, in `initState`**, and the build contains no
`attachBytecode` / `detachBytecode` / `dynamic_modules` reference at all. The
app therefore has no way to patch itself and no window in which `OLD` could be
observed before a patch landed. The only thing that can have replaced that body
is `Dart_RouteBActivatePatch` running from `root_isolate_create_callback`
(`dart_isolate.cc:163`), before `RunFromLibrary` at `:174`.

### Attribution is behavioral, not log-backed

The hook logs a `ROUTEB:` chain via `FML_LOG`, and **none of it is
recoverable**. No engine log line of *any* kind reaches `idevicesyslog` for a
`--noninteractive` launch on this device — not Flutter's own either — because
those go to stderr, which iOS does not route to syslog. So the absence of
`ROUTEB` lines says nothing about whether the hook ran.

That makes this A/B a *different evidence type* than originally planned, not a
weaker version of the same one. What it rules out is what matters: the control
eliminates the app, the engine, the snapshot flag and the source as
explanations, leaving the hook.

The earlier `ios-deploy --envs` attempt is the same fact inverted — it produced
`OLD` with zero log lines, and only the screenshot told us anything at all.
That is why the trigger moved from environment to file presence: a test
*transport* failure, not a Route B failure.

## Reproducing

Both bundles are built by `build_4a_payload.sh` plus a normal fixture release;
the control is produced by removing exactly one line from `pubspec.yaml`.
Launch attached, so the process survives long enough to photograph — a
`--justlaunch` run is torn down by `safequit` before the first frame:

```bash
ios-deploy --noninteractive --bundle /tmp/seam6_patched.app &   # leave attached
sleep 20
idevicescreenshot seam6_patched.png
```

Screenshots are downscaled (`sips -Z 900`) so the directory stays small; the
text is still legible, which is all they are for.

## 4b milestone 1 — delivery, 2026-08-10

**Route B artifact delivery through the real iOS Shorebird updater lifecycle is
proven. Native activation of the lifecycle-selected artifact remains under
diagnosis.**

Those are two claims and they are recorded separately on purpose. Whatever the
activation diagnosis turns out to be — wrong release, target missing, or the
hook never armed — none of it reopens what is below.

| file | shows |
|---|---|
| `4b_step1_release_OLD.png` | release 7.0.0+1, `route B value: OLD`, `code patch: none` |
| `4b_step7_first_read_NEW.png` | after the patch: **`code patch: 2`**, `route B value: OLD` |

Despite the filename, the second screenshot is the split result, not a pass. It
is kept because `code patch: 2` is the delivery evidence. The full sequence
passed later on release 9.0.0+1; see below.

### What is closed

```
control plane -> updater download -> inflate against the REAL base
              -> hash verification -> install -> lifecycle promotion
              -> selected as the active artifact
```

Direct evidence, not inference: the installed artifact was pulled back off the
phone and compared.

```
$ ios-deploy --bundle_id dev.selfhost.airgapProbe \
    --download=/Library/Application\ Support/shorebird/shorebird_updater --to /tmp/rbpull
magic:  SBRBPTCH
sha256: 80e650ce374acab6bf3dec6fba0a8b4570254e41be8d5d2bcaa4dd19cb4e5099
        == the published container, byte-identical
```

That also settles the base-reader finding **empirically**: `inflate()` produced
correct bytes rather than failing, so a Route B engine
(`shorebird_use_interpreter = false`) can install a normal code artifact through
the existing updater path. Before this change every such install died inside
`inflate()` before reading a byte.

### What is not closed, and why nothing here proves it

The hook refused and left nothing to read — no engine log line of any kind
reaches `idevicesyslog` on this device. The taxonomy existed and was unreadable,
which is the seam-6 evidence gap one level up.

**Do not treat "the app booted" as evidence the content sniff worked.** On iOS
the base snapshot is also reachable through `App.framework`'s exported symbols,
so clearing `application_library_paths` can be survivable. A successful boot
therefore does not distinguish:

- the container was correctly classified and kept out of snapshot loading, from
- the container was misclassified and the app happened to survive it.

Engine `591a9f8d` adds a `<artifact>.routeb` report written beside the installed
file. It makes the next run a hard fork: **no file** means the hook was never
armed and the fault is in classification, before activation; **a file** names the
exact boundary that failed.

## 4b milestone 1 — the full sequence, 2026-08-10

**All ten steps pass on release 9.0.0+1.** Route B code push is delivered by the
real control plane, installed by the real updater, activated natively before
`main`, persists across relaunch, and rolls back to pristine AOT.

| step | file | shows |
|---|---|---|
| 1 | `4b_m1_step1_OLD.png` | fresh release: `route B value: OLD`, `code patch: none` |
| 2–4 | `4b_m1_step2_download.png` | updater discovers, downloads, inflates, installs |
| 5–7 | `4b_m1_step7_NEW.png` | **`route B value: NEW`**, `code patch: 1` |
| 8 | `4b_m1_step8_relaunch_NEW.png` | still `NEW` from persisted lifecycle state |
| 9 | `4b_m1_step9_rollback_seen.png` | after `withdraw?rollback=true` |
| 10 | `4b_m1_step10_pristine_OLD.png` | **`OLD`**, `code patch: none` |

`4b_m1_activation.routeb.txt` is the engine's own report, pulled off the device:

```
hook entered
parsed, targets=1, built-for=3527f0133aaf33819a49d9953973f050
running=3527f0133aaf33819a49d9953973f050
applied 1/1 targets, entering main
```

Two identical blocks, one per launch — the hook re-activates from the persisted
artifact on every boot rather than caching anything.

After rollback the lifecycle removed the patch directory entirely and
`pointers.json` reads all-null, so step 10 is running pristine AOT rather than a
detached-but-present patch.

### The failure that cost two releases, and its signature

Releases 7.0.0+1 and 8.0.0+1 both reported **`applied 1/1 targets` and showed
`OLD`**. Nothing was wrong with delivery, the container, the build-ID check or
the attach — the report was honest. The releases were built **without**
`--extra-gen-snapshot-options=--patchable_static_calls`, so AOT emitted the
ordinary direct call: `AttachBytecode` really did make `routeBValue`
interpreted, and the call site in `routeBProbe` branched straight to the AOT
body without ever consulting `Function.entry_point_`.

> **`applied N/N targets` plus `OLD` on screen means a NON-PATCHABLE RELEASE,
> not a broken hook.**

This is the most dangerous shape of failure in this project — a mechanism
reporting truthful success while behaviour is unchanged — and the flag's absence
is silent at every other layer. The release step now passes it, and the +4.53 %
App binary growth (3,989,024 -> 4,169,856 bytes) is a cheap corroboration that
it reached `gen_snapshot`; the CLI log confirms it directly.

### What the diagnostic settled for free

- **Build-ID derivation is correct.** `running=` and `built-for=` match, so
  `OS::GetAppBuildId` does resolve to the App dylib's `LC_UUID` on iOS.
- **Content sniffing works.** The hook is only armed on the `SniffFile` ->
  `kOk` branch, so its firing is direct evidence — replacing the wrong inference
  recorded above, which argued from "the app booted".
