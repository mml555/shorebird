<!-- cspell:words idevice requalified -->

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
patch id 105 → 105; patch object dirs 104 → 104.

**Struck 2026-09-03.** ~~no patch-creation request in the control-plane log~~ —
that check was VACUOUS and is withdrawn. `cps-ios` emits no request logging at
all, so an empty grep of its output would have "passed" whatever happened. The
four counts above stand on their own, and patch 106 later landing exactly one
above the ceiling of 105 confirms independently that 6E published nothing.

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

## 6G — activation on a physical iPhone 7

Device `8cb4bc982ddf6437b1952520edee80f898196c74`, D10AP iPhone 7, iOS 15.8.8
(19H422), wired USB. `devicectl` is blind to iOS 15, so detection is by
`idevice_id` / `ios-deploy -c`. Every launch was a by-hand tap: `ios-deploy
--bundle` with no `-d` and no `-L`.

### What was installed

The control plane's OWN xcarchive for release 142 (artifact 540), signed only.

    downloaded          90813a068e2289d6dbf37c3ef700ce9401b3b6a10ab21b3c4b808bf5c8fc7c33
                        11,917,825 B  == the server's recorded hash
    App.framework/App   bbea5b9c72a6e25b7d20ba41abaafff9b0392da108b26f7ed673bb61489ff8b2
                        == release 142's release-artifact digest, the bytes patch 106 binds to

Signed with the certified P6 mechanism, unchanged: profile
`e3a92ae5-fe6c-4b28-a3b3-ad2212a80330`, digest `78b4e9cab6fe2691…` — the same
profile hash banked in SIGN-141 — identity `EE8685A4…` (Apple Development:
Pesach Brody, team `SK85S6YZP9`), entitlements taken from the profile with
`application-identifier` substituted. No new signing material was minted; no
Flutter build, Xcode rebuild, relink or archive regeneration.

Only signatures moved:

| Property | Unsigned archive | Signed derivative | |
|---|---|---|---|
| `App` payload, signature stripped | `8203ab04ca98fd04…` | same | **SAME** |
| `flutter_assets` tree (path-relative) | `08dc0c4e6026d161…` | same | **SAME** |
| `Runner` LC_UUID | `49BA1C58-8E52-3E3B-B4AF-E259CFEFC9CB` | same | **SAME** |

`diff -rq` over the whole bundle reports exactly four differences: `App` and
`Runner` (signature blobs), plus the added `_CodeSignature` and
`embedded.mobileprovision`. `codesign --verify --deep --strict`: exit 0, real
Apple Development authority chain, no adhoc code remaining.

The derivative's own identity, kept separate:

    signed .app tree (path-relative)     3f0dcab49e11b4a0b9f6e161d3de9d1e6cea3dc32b744a1d3f47efb21ab78c64
    signed App.framework/App file        abe9ac7f9ca0913514af4b411815a313a8ad27b3df997690e565172c670d5b1a

**Neither is release 142's release-artifact digest.** That remains
`bbea5b9c…ff8b2`, it is what patch 106 is bound to, and it must never be
substituted with a digest from this row.

The prior superFixture was uninstalled first, so no updater state survived from
release 141 / patch 105.

### Baseline — release behaviour, by hand

Launched from the home screen, in-app `RUN` tapped:

    positive()   BOXED[9]:APP-STATE

**LEN=9 is the RELEASE value.** The patch produces LEN=11. A post-activation
reading of 9 would be a failure, not a pass.

Device-side, before activation:

    state.json      release_version 1.0.3+4          <- identifies as release 142
    pointers.json   next_boot_patch  null (absent)
    patches/         (none)

### Staging is not execution

The first launch fetched nothing: `/Library/Caches/shorebird_updater/` empty and
no patch slot. Cause was the iOS **Local Network** permission, which the
uninstall reset — `base_url` is `http://10.0.0.7:18080`, a local address. Host
side was clean throughout (macOS firewall disabled, `*.18080` LISTEN, HTTP 403
from the LAN address, i.e. serving). Once the permission was granted and the app
relaunched, the updater fetched:

    patches/1/dlc.vmcode   89052f9d0811fd4c591bdfffe1091b49525c7ff24c19b03db0380f2ee3a576d3
                           1891 B  == the produced patch.sbrbptch, byte for byte
    patches/1/state.json   {"kind":"Installed","size":1891}
    pointers.json          next_boot_patch 1
                           last_booted_patch null      <- STAGED, NEVER EXECUTED
                           boot_attempt_count 0

That launch downloaded and staged the patch and is **not** evidence of
execution; `last_booted_patch: null` states it explicitly.

### Activation — force-quit, then a by-hand launch

    positive()   BOXED[11]:P:APP-STATE

Device-side after that launch:

    pointers.json   last_booted_patch        1     <- executed
                    boot_attempt_count       0     <- no retry
                    currently_booting_patch  null  <- no boot left in flight

No `Runner` crash report dated 2026-09-03; the newest are 2026-08-27. Patch 1 is
the only patch that exists for release 142, and it is patch id 106.

**Why LEN is the load-bearing observable.** `_Boxed.render()` computes
`'BOXED[${value.length}]:$value'`. The length is computed by the constructed
object at runtime, not baked into the replacement as a literal, so 11 cannot be
produced by a patch that merely activated — it requires `_Boxed` to have been
constructed and invoked. `last_booted_patch: 1` alone would prove only that the
patch booted.

### Note on syslog

`idevicesyslog` captured the launches (`Runner[18842]` sandbox line, SpringBoard
snapshot activity for `dev.shorebird.selfhost.superFixture`) but no updater
output: on iOS 15 it relays the old syslog and does not carry third-party
`os_log`. That absence is a capture limitation and is NOT evidence about the
updater. The runtime evidence used here is the updater's own on-device state,
read over AFC, plus the crash-report check.

## Not yet established

Persistence across further launches was not requalified — one post-activation
launch, as authorized. Nothing here speaks to Android, to non-exact
constructors, to tear-offs, or to a broad private-construction policy.
