# D-SUPER-2C — physical closure: signing and device evidence

Three separate parts. **141A and 141B are different installations**, and no
observation from one is evidence about the other. In particular 141A Tap 1 was
observed on the signature-only derivative, whose bundled `shorebird.yaml` had
no `base_url`; it is not evidence about 141B.

  * **Part 1 — 141A baseline.** Signature-only derivative of frozen release 141.
    Installed, launched by hand once, release behaviour confirmed. Ended in a
    blocker: the app asked `api.shorebird.dev`.
  * **Part 2 — 141B derivative mutation.** Endpoint correction. One content
    delta, `flutter_assets/shorebird.yaml`, re-signed with the same material.
  * **Part 3 — 141B activation sequence.** Fresh install, clean state, and the
    human launches that follow.

---

# PART 1 — 141A baseline

A signed, installable derivative of frozen release 141. Release 141 was built
`--no-codesign`, so its archive cannot install on a device. This part records a
derivative that is **release 141's bytes plus a signature**, produced without
any build step.

## Source — proven to be frozen release 141

The local `build/ios/archive/Runner.xcarchive` had been overwritten by later
patch builds, so the archive was **fetched from the control plane**, not reused
from a build directory.

    xcarchive artifact HTTP 200, 11 919 607 bytes
    fetched sha256            f1f9e5c77c3651946ba11db0ec1aceb517f096b051d67e56725fe24b45ed13d3
    == server's recorded hash YES
    bundle id                 dev.shorebird.selfhost.superFixture
    version                   1.0.2+3
    App.framework/App sha256  8280c1257dca7a2d18c9e73bbdb3168ca66cd7aaed7d68c0fde2a36d4abb0bc8
    == release 141's release-artifact digest in route_b.json   YES
    codesign state            "not signed at all" (outer), nested frameworks adhoc

## Signing mechanism — the certified P6 one, unchanged

`selfhost/scripts/make_track_clients.sh` steps 3–5: embed the profile, take
entitlements **from the profile** with `application-identifier` substituted, sign
inside-out, then assert the AOT payload did not move. Only the signing steps were
applied; the bundle-id / display-name / `channel:` edits that script performs for
the tracks arm were **not**.

    identity   EE8685A45DE3BE56F754883C4BF6C94A92EDE6FE
               Apple Development: Pesach Brody (BRDNYM22XL), team SK85S6YZP9
    profile    e3a92ae5-fe6c-4b28-a3b3-ad2212a80330  "iOS Team Provisioning Profile: *"
               application-identifier SK85S6YZP9.*   (wildcard)
               sha256 78b4e9cab6fe26911d5e0aa4d976ce5a…  — the SAME profile hash
               banked in ARM_B_PACKAGE_SIGNING.md
               6 provisioned devices, iPhone 7 8cb4bc98…96c74 among them
               expires 2027-07-31, get-task-allow true
    entitlements  SK85S6YZP9.dev.shorebird.selfhost.superFixture

**No new signing material was minted.** The wildcard profile is what allows this
bundle id to be signed without registering anything, and the identity it pairs
with is one of the two developer certificates the profile itself lists.

No Flutter build, Xcode rebuild, relink, recompilation, or archive regeneration
was performed. The `Runner` LC_UUID is unchanged, which is the check that would
catch a relink.

## Delta checks — only signatures moved

| Property | Frozen 141 | Signed derivative | |
|---|---|---|---|
| `App` AOT payload, signature stripped | `5fa37149a074d122f60dfc78a26cb0a0…` | same | **SAME** |
| `flutter_assets` tree digest | `bb9d78fc3f14198aa3c87cf5c2e67116…` | same | **SAME** |
| `Runner` LC_UUID | `49269044-3AAB-32C8-BE60-89D8E1836518` | same | **SAME** |
| CFBundleIdentifier | `dev.shorebird.selfhost.superFixture` | same | **SAME** |
| version | `1.0.2+3` | same | **SAME** |

The raw *file* hash of `App.framework/App` necessarily changed, because
re-signing rewrites the signature blob inside the Mach-O. That is why the
invariant is the signature-stripped payload — the reasoning already recorded in
`make_track_clients.sh`'s header, and the reason the file hash is the wrong
comparison here.

## Verification

    codesign --verify --deep --strict     valid on disk
                                          satisfies its Designated Requirement
    Identifier        dev.shorebird.selfhost.superFixture
    TeamIdentifier    SK85S6YZP9
    Authority         Apple Development: Pesach Brody (BRDNYM22XL)
                      Apple Worldwide Developer Relations Certification Authority
                      Apple Root CA
    CDHash            d2ca8e1d82b7299b5e7684a1faffe1f4b484d345
    Format            app bundle with Mach-O thin (arm64)

Both nested frameworks were adhoc in the `--no-codesign` archive and both now
carry the same real authority; no adhoc code remains, which a device install
would otherwise reject.

## The derivative's own identity — kept separate from release 141's

    signed .app tree digest              88bb2d17c65f17a5698473cc1d1ca0c1a4c97503fa6e40c78abc3e826be111da
    signed App.framework/App file sha256 42e7213632fc86a2cd23f07374dcc38a0dc09708c30d5ba68be21149c5b3e9e4

**Neither value is release 141's release-artifact digest.** That remains
`8280c125…0bc8`, it is what patch 105 is bound to, and it must never be
substituted with a digest from this row.

## Release-141 semantics still present in the derivative

    shorebird app_id                 41344620-5d2d-9707-47e0-88ab230f8cbf
    candidate engine marker          present (1)
    updater af6e842ccf87             present (1)

### Disambiguation control — the derivative is the UNPATCHED release

The working tree's `lib/main.dart` currently holds the **patch** source, so
"release 141 renders `TICKER:APP-STATE`" was re-proven from the frozen bytes
rather than from the tree.

`_verdict`'s switch cases put the literals `TICKER:APP-STATE`,
`WRAP:TICKER:APP-STATE` and `LEAF:APP-STATE` in **every** build, patched or not,
so their presence proves nothing. The discriminator is the *interpolation piece*
each body needs:

    standalone 'BASE:'   piece : 1      (Base.close   body)
    standalone 'TICKER:' piece : 1      (Ticker.close body)
    standalone 'LEAF:'   piece : 1      (Leaf.close   body)
    standalone 'WRAP:'   piece : 0      <-- decisive

`WRAP:` occurs exactly once in the whole binary and only inside the
`WRAP:TICKER:APP-STATE` verdict constant. A release whose `target()` were
`'WRAP:${super.close()}'` would need a standalone `WRAP:` piece the way the three
`close()` bodies each have one. It has none, so frozen 141's `target()` is plain
`super.close()` and will render `TICKER:APP-STATE`.

The patch side already carries that piece: Gate 3's banked lowered replacement is
`'WRAP:${$routeBSuper(self, …)}'`. Tap 1 and Tap 2 are therefore distinguishable
by the rendered string, not merely by the ledger.

## Install — placed on the device, deliberately NOT launched

iPhone 7 / iOS 15.8.8, wired over USB (`--no-wifi`, so a wireless pairing cannot
be what was installed).

    idevice_id -l   8cb4bc982ddf6437b1952520edee80f898196c74
    ios-deploy -c   D10AP, iPhone 7, iphoneos, arm64, 15.8.8, 19H422,
                    "connected through USB"
    == the UDID the embedded profile provisions   YES

`devicectl` is blind to iOS 15 and reports this device unavailable while wired,
so detection is by `idevice_id` / `ios-deploy -c`.

### Prior state removed — established, not assumed

    exact matches for dev.shorebird.selfhost.superFixture, before install : 0

That check is not vacuous: the same listing shows nine other selfhost probes on
this device (`dev.selfhost.signProbeApp`, `killswitchProbe`, `airgapProbe`, …),
so the filter demonstrably finds what is there. The fixture had never been
installed, so there was no prior install or updater state to clear, and
`InstallingApplication` created a fresh container.

### Installed

    ios-deploy --no-wifi --bundle .../sign141/Runner.app
    -> [100%] Installed package

No `-d` and no `-L`, the certified ARM-C condition: those are the only two flags
that launch, so a plain `--bundle` installs and stops.

### Verified

    exact matches for the bundle id, after install : 1
    device installation database  CFBundleIdentifier         dev.shorebird.selfhost.superFixture
                                  CFBundleShortVersionString 1.0.2
                                  CFBundleVersion            3
    --get_pid                     pid: -1        (not running)

### It has not executed

Data container read back from the device (`--download`/`--list` attach no
debugger):

    /Documents/               0 children
    /Library/Caches/          0 children
    /Library/Preferences/     0 children
    patches/ directory        absent
    any shorebird updater path absent

Four `/Library/SplashBoard/Snapshots/…ktx` entries exist. Those are the launch
placeholders SpringBoard renders from the launch storyboard at install time; they
are not evidence of execution, and the load-bearing facts are that the process
pid is `-1` and the updater has written nothing. **No Dart code has run.** Tap 1
will be this build's first execution.

## STOPPED HERE — awaiting Tap 1 (human)

> Superseded by the Tap 1 result below. Retained because it records what was
> required of Tap 1 *before* it was observed.

Expected at Tap 1: `TICKER:APP-STATE` / verdict `RELEASE (unpatched)`. If the
device instead renders `WRAP:TICKER:APP-STATE` on the first launch, the run is
void and stops: it would mean a patch became active during the very launch that
is supposed to establish the unpatched baseline.

## BLOCKER found at 141A Tap 1 — the shipped app asks upstream Shorebird

The app launched (`pid 8354`) and the updater initialised, but obtained nothing.
Two reads, minutes apart, agree:

    container entries            33 (from 13)
    patches/ directory           absent
    dlc.vmcode                   absent
    state.json                   { client_id, release_version "1.0.2+3", queued_events: [] }
    state_diag.log               SAVE_END result=ok, then LOAD instance=2..6
                                 — state machine healthy, no patch state at all

### Cause

The release's bundled `App.framework/flutter_assets/shorebird.yaml` carries
**only** `app_id`:

    app_id: 41344620-5d2d-9707-47e0-88ab230f8cbf

No `base_url`. The updater's compiled-in default is the only endpoint string in
`Flutter.framework/Flutter`:

    https://api.shorebird.dev

So the device asks **upstream Shorebird** for patches to an app that exists only
on this fork's control plane. Patch 105 can never be offered. This is not a
device, signing, install, or Route B fault — the signed derivative is correct and
the updater is working.

The fixture project's `shorebird.yaml` is unmodified `shorebird init` output.
Every other self-hosted project here sets the field
(`compat-corpus/wonderous` → `http://localhost:18080`, Jewgo →
`https://cps.jewgo.app`); the superapp fixture was hand-made and never went
through a preparer script, so nothing supplied it.

### This exact symptom is already banked

`p6-flavor-ios` superseded release 114 for a "device-unreachable `base_url`
[that] failed silently", and `prepare_killswitch_fixture.sh:31` records:

    2026-08-14: with localhost, state.json on device carried no patch state at all.

That is precisely the state.json observed here.

### Product gap — absent is not refused, only localhost is

The guard is in the **fixture preparer shell scripts**
(`prepare_flavored_fixture.sh:168`, `prepare_airgap_fixture.sh:151`,
`prepare_killswitch_fixture.sh:28`), not in the CLI. Nothing in
`packages/shorebird_cli` refuses an absent `base_url` — `ShorebirdYaml.baseUrl`
is a plain `String?`. A fixture that skips the preparers gets no guard, and an
**absent** `base_url` is treated as "use upstream" rather than as a missing
value, so it fails silently where `localhost` would have been refused.

This is the same defect class as the descriptor bug closed in `6ffa93a0`
("descriptor parsing must distinguish absent from invalid"): absent collapsed
into a benign default instead of being reported.

### Device-reachable address, for whatever route is authorised

    this Mac (en0)               10.0.0.7
    control plane                port 18080 OPEN (8443 also open; 8080, 443 closed)
    precedent from p6-custom-target  PUBLIC_BASE_URL=http://10.0.0.7:18080

## STOPPED — awaiting a ruling before Tap 2

> Superseded: the ruling authorised SIGN-141B, and the next launch is
> **141B Tap 1B**, not Tap 2. Retained as the state at the time of the ask.

Tap 1's own requirement is unaffected: nothing is patched, and no patch state
exists. Tap 2 is unreachable with this artifact as installed.

## 141A Tap 1 — PASS (baseline established)

By-hand icon tap, then a by-hand tap on **RUN target()**. No debugger attached at
any point (installed with no `-d`/`-L`; device state read only with
`--list`/`--download`).

    rendered   TICKER:APP-STATE
    verdict    RELEASE (unpatched)

That is the release outcome, and it is the one the frozen bytes predicted: the
binary has a standalone `TICKER:` interpolation piece and **no** standalone
`WRAP:` piece, so `target()` is plain `super.close()`. The observation and the
static prediction agree.

Not `LEAF:APP-STATE`, so dispatch went to `Ticker.close` and not virtually to
`Leaf.close` — the release half of the narrow-v1 super specimen behaves as the
producer's evidence rule assumed.

Not `WRAP:TICKER:APP-STATE`, so no patch was active on the first launch. The
run is not void.

### Updater behaviour at Tap 1

Nothing was offered, downloaded, or staged — see the blocker above. So the
"staged ≠ active" distinction the milestone asks about could not be exercised
at Tap 1: there was no staged patch to distinguish from an active one.

**Tap 1 stands on its own terms** (release renders the release string, nothing
patched). It does not yet establish that a staged-but-inactive patch leaves the
release behaviour intact, because no patch reached the device.


---

# PART 2 — 141B derivative mutation

Everything below this line concerns a **different installation** from Part 1.

## Readiness proof — everything except `base_url` is already correct

Run before any ruling, because none of it depends on one. The device's own
patch-check was replayed against the control plane using the phone's real
`client_id`, the updater's default channel (`stable`, `config.rs:24`) and its
declared kinds (`["code","assets"]`, `network.rs:307`):

    POST http://10.0.0.7:18080/api/v1/patches/check
    { app_id 41344620-…, channel stable, release_version "1.0.2+3",
      platform ios, arch aarch64, client_id 259e7cf5-…,
      supported_patch_kinds ["code","assets"] }

    -> HTTP 200
       patch_available true
       number          1
       kind            code
       hash            ea881e2dafc090248079a106bc40dc2a41cd26ed23ed19bd4bdc32166d36fd23
       download_url    http://10.0.0.7:18080/download/9f01f2b7…

Identical answer from `localhost` and from the LAN address, so the server is
reachable on the address a phone would use.

### The offered patch is patch 105

    artifacts row for token 9f01f2b7…
      owner_kind  patch
      owner_id    105          <-- not inferred from the hash; the server says so
      arch/platform aarch64/ios
      status      verified
      size        1317

### TRAP: the number on the device will be 1, not 105

`number` is the **release-scoped** patch number the updater stores; `105` is the
server-side id. A between-taps check that greps device state for "105" would
fail wrongly. Bind by hash, or by `owner_id` in the server's `artifacts` row.

### The hash chain, resolved

The served bytes do **not** hash to the advertised `hash`, and that is correct
rather than a defect. Chased to the end so it is not left as a lurking doubt:

    stored blob / served bytes   1317 B   ffa1df3781eed9cf…   (zstd, the compressed diff)
    that blob decompressed       2206 B   875253a12a61a406…   (the diff stream)
    build/route_b/patch.sbrbptch 2194 B   ea881e2dafc09024…   == the server's recorded hash

`ios_patcher.dart:448` computes `hash = sha256(patchBuildFile)` — the
**reconstructed** patch — while `patchFile`, the thing uploaded, is the diff
produced by `createDiff` (`:437-445`). The device downloads the diff, applies it
to the base, and hashes the reconstruction. So the recorded hash is over
`patch.sbrbptch`, and a local file hashing to exactly `ea881e2d…` was found to
prove it rather than argue it. This is also why ARM_C could report the installed
`dlc.vmcode` matching the server's hash exactly.

Truncation fault ruled out: `fail_after` (`api.dart:1901`, non-production only)
was not in the URL, and `content-length` equalled the artifact's full size.

The decompressed diff carries `WRAP:` ×1 and `routeBSuper` ×1 — the narrow-v1
super patch, not some other payload.

### Download path is not IP-gated

`@must_be_local` (`Caddyfile:163`) matches only engine-artifact paths
(`flutter_infra_release/…`, `download.flutter.io/…`, `…/shorebird/<sha>/…`). It
does not match `/download/<token>` or `/api/v1/patches/check`, and the control
plane publishes `0.0.0.0:18080`, so the phone is not blocked.

### Conclusion

Signing, install, patch publication, patch identity, artifact integrity, channel
eligibility and network reachability are all correct. **The single blocker is the
missing `base_url`**, which sends the device to `api.shorebird.dev` instead.

## The mutation

Built from the **frozen release-141 archive extract**, not from 141A, so there is
a single signing pass rather than a re-sign of a re-sign. The frozen extract was
re-verified pristine first: `App.framework/App` = `8280c125…0bc8`, outer bundle
"not signed at all".

The only content edit, and it is purely **additive** — the frozen file had no
trailing newline, so its 44 bytes are a byte-exact prefix of the new file:

    frozen  (44 B)  app_id: 41344620-5d2d-9707-47e0-88ab230f8cbf
    141B    (76 B)  app_id: 41344620-5d2d-9707-47e0-88ab230f8cbf
                    base_url: http://10.0.0.7:18080

    first 44 bytes byte-identical to frozen : YES
    app_id line unchanged                   : YES
    base_url exactly the LAN endpoint       : YES

`base_url` parses correctly despite containing colons: the updater splits on the
**first** colon only (`yaml.rs:51`, `split_once(':')`), and iterates `lines()`,
so the absent trailing newline is fine. No trailing slash, because the updater
builds `{base_url}/api/v1/patches/check` (`network.rs:16`).

Signed with the identical material as 141A — identity `EE8685A4…`
(Apple Development: Pesach Brody), profile `e3a92ae5-…`, `SK85S6YZP9.*`,
embedded profile digest `78b4e9cab6fe2691…` byte-identical to 141A's.
`codesign --verify --deep --strict`: exit 0.

## Full bundle delta — frozen 141 → 141B

Every file in the bundle compared, not a sampled subset.

    files only in frozen : 0
    files only in 141B   : 2   ./_CodeSignature/CodeResources
                               ./embedded.mobileprovision
    files in both        : 50
    of those, differing  : 5   Frameworks/App.framework/App
                               Frameworks/App.framework/_CodeSignature/CodeResources
                               Frameworks/App.framework/flutter_assets/shorebird.yaml
                               Frameworks/Flutter.framework/Flutter
                               Runner

Four of those five are signature machinery: the two `CodeResources` seals, the
new outer seal, the embedded profile, and the signature blobs inside the three
Mach-Os. **Exactly one is content: `flutter_assets/shorebird.yaml`.**

`flutter_assets` compared on its own: 9 files, 0 added, 0 removed, exactly 1
differing — `shorebird.yaml`. Requirement 5 met.

## Requirement 1, stated precisely

Requirement 1 asks that `App.framework/App` remain exactly `8280c125…0bc8`.
**That digest cannot survive any re-signing, and it did not survive 141A's
either.** `8280c125…` is the digest of the *adhoc-signed* file as it sits in the
archive; re-signing rewrites the signature blob inside the Mach-O, so the file
hash necessarily changes. Requirement 8 ("no rebuild/relink/rearchive that
changes executable **payloads**") is the achievable form of the same intent, and
it is the invariant `make_track_clients.sh` uses for exactly this reason.

Measured on that basis:

    App payload, signature stripped
      frozen 141  5fa37149a074d122f60dfc78a26cb0a094c51cdcf1760a233476bc44123d5ad8
      141A        same
      141B        same

    App file digests (each derivative's OWN identity, never release 141's)
      frozen 141  8280c1257dca7a2d18c9e73bbdb3168ca66cd7aaed7d68c0fde2a36d4abb0bc8
      141A        42e7213632fc86a2cd23f07374dcc38a0dc09708c30d5ba68be21149c5b3e9e4
      141B        1a5a319d407bfd5f69b4fd0a65fe1d8886285da0fc3a5b3b58322a024eecf74e

`8280c125…` remains release 141's release-artifact digest, is what patch 105
binds to, and is held server-side. Nothing on the device verifies the base
binary (`make_track_clients.sh` header; `updater.rs:327` hashes the downloaded
patch, not `libapp.so`), so re-signing cannot disturb that binding.

## Requirements 2 and 3 — Flutter and Runner

    Flutter payload, signature stripped   63a7e1e6ae631f3f8bd6bdc1a6f3103d…  SAME
    Runner LC_UUID                        49269044-3AAB-32C8-BE60-89D8E1836518  SAME

`Runner`'s signature-stripped payload does **not** match frozen, and that needed
explaining rather than waving through. The frozen `Runner` was *unsigned*, so
signing it adds an `LC_CODE_SIGNATURE` load command and extends `__LINKEDIT`;
stripping the signature afterwards does not restore the original layout. `App`
and `Flutter` were already adhoc-signed, which is why they round-trip exactly.

Two independent confirmations that this is signing overhead and not content:

    141A Runner payload  8172bcd2f1a2a867c7beb3d1efa19a61d79053bb3a71880614776cdd51b9a05b
    141B Runner payload  same  — identical in both derivatives
    frozen 75 360 B  ->  both derivatives 94 896 B

And a per-section comparison of the Mach-O, frozen vs 141B — all 38 sections:

    37 file-backed sections   SAME   (__text, __stubs, __const, all __swift5_*,
                                      __cstring, __unwind_info, __eh_frame,
                                      __DATA_CONST/*, __DATA/*, …)
    __DATA,__bss             (not comparable)

`__bss` first read as DIFFER, and that was **my measurement error, not a
finding**: its section record is `offset 0`, `flags 0x00000001` (`S_ZEROFILL`),
so it has no file content at all and the read was hitting the Mach-O header.
Zero real deltas. Only the header, load commands and `__LINKEDIT` moved.

## Requirements 4, 6, 7

    CFBundleIdentifier   dev.shorebird.selfhost.superFixture   SAME
    version              1.0.2+3                               SAME
    app_id               41344620-5d2d-9707-47e0-88ab230f8cbf   unchanged
    base_url             http://10.0.0.7:18080                  exact LAN endpoint

## Requirement 9 — 141B's own identity, banked separately

    signed .app tree digest   6eb488042f5b95217c86c8ec133ddc4b25927f5ae8be6ed99d1e12efddd0f55e
    signed App file sha256    1a5a319d407bfd5f69b4fd0a65fe1d8886285da0fc3a5b3b58322a024eecf74e
    bundled shorebird.yaml    3b4cb590768bd1f7bf109b1a2b3ba33d530d21fb2825b81a8ebe51ae979d2d09
    CDHash                    dd317034175d9507a5cf54e6e022b5b2a533168e
    Identifier                dev.shorebird.selfhost.superFixture
    TeamIdentifier            SK85S6YZP9
    Authority                 Apple Development: Pesach Brody (BRDNYM22XL)
                              Apple WWDR CA / Apple Root CA

None of these is release 141's, 141A's, F3's, H3's, or patch 105's identity.

    141A tree 88bb2d17…   141B tree 6eb48804…   — different installations

## Release-141 semantics still present in 141B

    candidate engine marker            present (1)
    updater af6e842ccf87               present (1)
    standalone 'TICKER:' piece         1
    standalone 'WRAP:'   piece         0   -> still the UNPATCHED release

**Result: one content delta, exactly `shorebird.yaml`. No second delta. Proceed.**

---

# PART 3 — 141B activation sequence

## Fresh install

141A was removed rather than upgraded, so no updater state or container could
carry across.

    ios-deploy --no-wifi --uninstall_only --bundle_id dev.shorebird.selfhost.superFixture
      -> [ OK ] Uninstalled package

    exact matches for the bundle id, after uninstall : 0
    control: dev.selfhost.* probes still listed      : 8   (the filter works)

    ios-deploy --no-wifi --bundle .../sign141b/Runner.app
      -> [100%] Installed package        (no -d, no -L)

    exact matches after install : 1
    device installation database: CFBundleIdentifier dev.shorebird.selfhost.superFixture
                                  1.0.2 + 3
    --get_pid                   : pid: -1        (not running)

## Clean state established

    container entries        13
    /Documents/              0 children
    /Library/Caches/         0 children
    /Library/Preferences/    0 children
    shorebird_updater/       absent
    state.json               absent
    patches/ , dlc.vmcode    absent

The four `SplashBoard` snapshot UUIDs differ from 141A's, which is independent
evidence that this is a **new container** and not 141A's reused.

No Dart code has run under 141B.

## STOPPED — awaiting 141B Tap 1B (human)

Required baseline again: `TICKER:APP-STATE` / `RELEASE (unpatched)`.

The additional observable this time is the updater lifecycle: patch
`ea881e2d…` (server-side id **105**, release-scoped number **1**) should now be
reachable, since the endpoint is corrected. Whether it is offered, downloaded or
staged *before* this launch's `target()` runs depends on updater timing, and the
lifecycle will be recorded as it actually occurs rather than forced into an
expected shape. If staging only completes after the launch, that is the finding,
not a failure.

Device-side patch identity binds to the **hash / reconstructed artifact
identity**, never by searching for `105` — the device stores number `1`.

The launch after this one is the activation test.

## 141B first launch — reached the app, but not the server

    app ran, fresh client_id 63982225-836e-417c-be2f-eae9b602a27c
    state.json     release_version 1.0.2+3, queued_events []
    patches/       absent
    control plane  NO POST /api/v1/patches/check in the window

Ruled out at the time, each by measurement rather than assumption:

    base_url value        p6-flavor-ios:72 confirms http://10.0.0.7:18080 is the
                          certified device address. (169.254.x in the container env
                          is the USB link-local, which changes every session:
                          ledger has .189.3, then .46.190, now en17 169.254.249.216.)
    server reachability   POST to 10.0.0.7:18080 over the non-loopback interface -> 200
    phone off Wi-Fi       10.0.0.227 answers ~50ms, randomised MAC (7e: prefix,
                          iOS private Wi-Fi address); syslog shows Rssi -38, Snr 35

The leading hypothesis was iOS local-network permission: `Info.plist` carries no
`NSLocalNetworkUsageDescription`, and this bundle id had never been granted
local-network access. **That remains probable but UNPROVEN** — syslog was not
being captured during this launch, so no denial was observed. What is certain is
that the first launch's request never reached the server and the next one's did,
with a request to tap "Allow" on any local-network prompt in between.

A first syslog capture attempt was inconclusive for a mundane reason worth
recording so it is not re-attempted the same way: it ran only ~1 minute (the
background process was killed early) and, more importantly, **the app was already
running** — the updater logs only at launch, so a capture that does not span a
cold start observes nothing.

## 141B second launch — the endpoint correction works, and the lifecycle answers itself

Captured with `idevicesyslog`, which attaches no debugger. The updater's own
words, from the launch that ran (pid 8607):

    [shorebird] Preparing next boot.
    [shorebird] Prepared boot of the base release.
    Shorebird updater: no active patch.
    Starting Shorebird update
    [shorebird] Sending patch check request: PatchCheckRequest { app_id:
        "41344620-5d2d-9707-47e0-88ab230f8cbf", channel: "stable",
        release_version: "1.0.2+3", platform: "ios", arch: "aarch64", … }
    [shorebird] Patch check response: PatchCheckResponse { patch_available: true,
        patch: Some(Patch { number: 1,
        hash: "ea881e2dafc090248079a106bc40dc2a41cd26ed23ed19bd4bdc32166d36fd23", … })
    [shorebird] Downloading patch 1 for app 41344620-… (version 1.0.2+3)
    [shorebird] Downloading patch from: http://10.0.0.7:18080/download/9f01f2b7…
    [shorebird] Downloaded patch to: …/downloads/1 (1317 bytes)
    [shorebird] Inflating patch from …/downloads/1 (1317 bytes)
    [shorebird] Patch successfully applied to …/patches/1/dlc.vmcode
    [shorebird] Patch 1 successfully downloaded. It will be launched when the app
        next restarts.
    [shorebird] Update thread finished with status: Update installed

`base_url` is confirmed in effect by the device's own log line naming
`http://10.0.0.7:18080`, not merely by the file we wrote.

### The lifecycle, recorded as it actually occurred

**Staging happens after the baseline execution, not before it.** The updater
prepared the base release and reported `no active patch` *first*, then checked,
downloaded and staged. So the launch that fetches a patch necessarily runs
unpatched, and `It will be launched when the app next restarts` is the updater's
own statement of that model. This was not forced into an expected shape — it is
what the log shows, and it is the answer to the question the milestone left open.

    ROUTEB activation lines in the whole capture : 0

### The staged patch, identified BY HASH

Never by searching for `105`; the device stores release-scoped number `1`.

    device  patches/1/dlc.vmcode          2194 B   ea881e2dafc09024…
    server  artifacts.hash (owner_id 105)          ea881e2dafc09024…
    host    build/route_b/patch.sbrbptch  2194 B   ea881e2dafc09024…

Three independent points agree, so the staged bytes are patch 105's
reconstructed artifact. Contents:

    standalone 'WRAP:'  piece : 1     <-- the piece the release LACKS
    routeBSuper               : 1
    'TICKER:'                 : 0     (the release supplies that half)

    patches/1/state.json  { kind: "Installed", signature: null, size: 2194 }

`signature: null` is consistent: this release sets no `patch_public_key`, so
`patch_verification` is not strict here. Patch-signature enforcement is ARM_C's
subject and is not claimed by this row.

### State at the moment of writing

    pid 8607 still alive, running the BASE RELEASE
    patch 105 staged, Installed, not active
    activation will occur on the next cold start

This is precisely the state the milestone asked for: **offered, downloaded and
staged, but not yet influencing execution.**

## 141B Tap 1B — PASS (endpoint-corrected baseline, with staged ≠ active PROVEN)

By-hand tap on **RUN target()**, performed on the *still-running* pid 8607 —
deliberately without a force-quit, so the reading comes from the same execution
the updater staged into.

    rendered   TICKER:APP-STATE
    verdict    RELEASE (unpatched)

Verified at the moment of the reading:

    pid                                    8607   (unchanged; no restart intervened)
    cold starts in the whole capture       1
    ROUTEB / activation lines              0
    patches/1/dlc.vmcode                   present, kind "Installed", ea881e2d…

### Why this is stronger than 141A Tap 1

141A Tap 1 established only "release renders the release string" — no patch had
reached the device, so the staged-vs-active distinction could not be exercised
and was explicitly not claimed.

Tap 1B closes that gap. Patch 105 was **downloaded, inflated and staged on this
very execution**, and this execution still rendered `TICKER:APP-STATE`. So:

  * a staged patch does **not** influence the execution that staged it;
  * the release behaviour is intact with a patch present on disk;
  * `WRAP:` is absent from the rendered result even though the staged bytes
    contain the `WRAP:` interpolation piece — the patch is on the device and
    inert.

Not `LEAF:APP-STATE`, so dispatch again went to `Ticker.close`, not virtually to
`Leaf.close`.

The identifier binding is by hash throughout: device `dlc.vmcode`, server
`artifacts.hash` for `owner_id 105`, and host `patch.sbrbptch` all equal
`ea881e2d…`. The device's own number is `1`.

## STOPPED — awaiting the activation launch

The next cold start is the activation test. Required:

    WRAP:TICKER:APP-STATE      -> PATCHED narrow-v1 super   (the pass)
    TICKER:APP-STATE           -> patch failed to activate
    LEAF:APP-STATE             -> WRONG: virtual dispatch, narrow-v1 rule violated

`WRAP:TICKER:` is the discriminating outcome: it proves the synthetic top-level
function reached `Ticker.close` — the exact super-target the release itself
direct-called — rather than re-dispatching virtually to `Leaf.close`.
