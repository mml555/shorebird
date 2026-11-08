<!-- cspell:words flavoredprobe airgap precommitted nostart -->

# P6 · iOS flavor arm — PASS

Release **115** (`1.3.0+1`, flavor `foo`, development-signed) on
`P6_DEVICE_EPOCH = 8e65981251dc945356d532120e424836da10245c`, app
`flavoredprobe-p6` (`1c99c679-8650-ba82-3899-681349a59416`), patch **79**.

## The precommitted table, as observed

| # | requirement | observed |
|---|---|---|
| 1 | built through the real flavored Xcode configuration/scheme | `Release-Foo` / scheme `Foo`, bundle `dev.selfhost.flavoredProbe.foo` |
| 2 | release records the intended flavor | `buildConfig.effectiveDefines.FLUTTER_APP_FLAVOR = Foo` |
| 3 | the patch's configuration AGREES with the release | the patch published; a mismatch is refused by P5 before any build |
| 4 | the exact current cell in the lineage | `route_b.json` `engineRevision = 8e65981251dc9453`, read from the SERVER-fetched sidecar |
| 5 | P4 release evidence present | snapshot profile + binding, both digest-verified against the bytes as delivered and against the ACTUAL signed App binary `add3fb11013090a2` |
| 6 | baseline visible | **`FLAVORED-FIXTURE-V1` · `V1/Foo` · `BAKED-INTO-RELEASE`** — `03_r115_baseline_tap.png` |
| 7 | the patch publishes through the real producer | patch 79, `ready`/`stable`/`active`/100 %, `aarch64/ios` `dd3e88a53bc4bdbe` |
| 8 | manual icon launch only | every observation from a by-hand tap. One earlier `--justlaunch` install was recorded and DISCARDED |
| 9 | the device renders the patched value | **`V2/Foo`** — `04_r115_patched_tap.png` |
| 10 | an unrelated control unchanged | `release:` still `FLAVORED-FIXTURE-V1`, `asset:` still `BAKED-INTO-RELEASE` |

`V2/Foo` carries both facts in one reading: the patch **executed**, and the flavor
reached the **patch's own compile**. The release marker staying `V1` is what stops
that being confused with having quietly picked up a new release.

## Corroborated off-screen, not from the screenshot alone

    device   patches/1/dlc.vmcode.routeb          the Route B container, installed
             patches/1/dlc.vmcode.routeb.trace
    server   POST /api/v1/patches/check -> 200    the device did reach the control plane

Both absent on the failed attempts, which is what made those diagnosable.

## One instrument refused, and it is not banked

`probes/classify_routeb_trace.py` on the device trace:

    REFUSED: trace format v=5. v1 recorded Code accessors under the uep_ names…
             Re-run with a v2 engine.

The classifier understands v2; this engine writes v5. Per the standing rule that
*a tooling refusal is never banked as a result*, this is recorded as neither
support nor contradiction. **The arm does not rest on it** — requirements 6, 9
and 10 are rendered output with independent corroboration. Recorded as a debt:
the trace classifier has drifted behind the engine's trace format.

## Three defects this arm found, none of them about flavors

**1 · Route B: a replacement did not inherit the target library's imports.** The
patch would not build — `exit 254`, no compiler diagnostic. Dart imports are not
transitive, so a body referencing anything the target library IMPORTS could not
resolve. `appFlavor` here; equally a widget or a `jsonEncode` in any real patch.
P1/P2 never hit it because those bodies used only the target's own members and
`dart:core`. Fixed, with relative imports refused by name rather than dropped.

**2 · The fixture's `base_url` was device-unreachable, and failed silently.**
Patch live at 100 %, two hand taps, device still read `V1/Foo`. The updater's
state showed no patch and an empty queue; the app had
`base_url: http://localhost:18080` baked in, and `localhost` on a phone is the
phone. Nothing errored: release published, patch published, app showed its
baseline. The preparer now refuses that combination once an `--app-id` is present.

**3 · iOS Local Network permission gates the whole transport.** After the base
URL was corrected the device STILL never reached the server — the log showed only
this workstation's own requests. The app declares
`NSLocalNetworkUsageDescription`, so iOS gates LAN access behind a user grant,
and an ungranted app fails silently. Once granted, the very next launch produced
`POST /api/v1/patches/check -> 200` and the patch applied.

**This is a real prerequisite for every device row on this rig, not a flavor
detail**, and it is invisible from the host: the release is fine, the patch is
fine, the rollout is 100 %, and the app shows its baseline for ever.

## A correction to my own guard

I added a guard reading "a `localhost` base_url is device-unreachable". That is
**too broad**. It is correct for a Wi-Fi LAN address and wrong for a
USB-forwarded port — and this fixture's own usage string says *"over the USB
link"*, which is presumably why `localhost` was the default. The guard as written
would push a future arm toward Wi-Fi when USB forwarding was intended.

The guard is kept, because a silent failure is worse than a false alarm and it
prints the host's real address, but it is **narrower than its message claims**
and should be revisited if a USB-forwarded arm is ever wanted.

## Scope

This certifies the **iOS flavor workflow end to end**: real flavored scheme →
real CLI release on the current cell with complete P4/P5 evidence → real producer
patch → physical execution, controls unmoved. The **wrong-flavor negative stays
at the P5 host layer** as precommitted; no mismatched flavor was sent to the
phone.

Rollback was NOT run and is NOT claimed here — it is independently device-proven
and is not the flavor seam.
