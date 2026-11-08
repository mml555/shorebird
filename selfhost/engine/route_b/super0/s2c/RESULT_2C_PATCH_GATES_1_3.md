# D-SUPER-2C · patch gates 1–3 — narrow-v1 super patch PUBLISHED

    release 141   1.0.2+3   F3 ab29aee0…   H3 d4c0dbc2…
    PATCH 1       id 105    channel stable

Releases 139/140, F2, H2, F3, H3 and `39ad75dd…` all unchanged.

## GATE 1 — the site is a legitimate narrow-v1 positive

Banked from the FROZEN H3 analyzer (`18862acd…`) run against release 141's own
kernels — base `release_app.dill` from the uploaded supplement, patched the
build's AOT `app.dill`:

    release method identity   package:super_fixture/main.dart#Leaf.target
                              memberKind Method
    super invocation          offset 1318, member close, kind method
    analyzer target provenance
                              name close, kind Method, fileOffset 966,
                              fileUri file:///…/superapp/lib/main.dart
    releaseSuperTargets       MEASURED (not absent, not empty)
                              [{fileOffset 966, name close, kind Method}]
    ADMISSION LEGAL           True — the site's target IS the release evidence

    analysisVersion 11, verdict accept, Leaf.target in `changed`

The target is the PARENT, verified by offset:

    line 23  Base.close      (class Base)
    line 29  Ticker.close    <- fileOffset 966, the admitted target
    line 36  Leaf.close      (the override, NOT the target)
    line 41  Leaf.target     <- offset 1318, the super site

So the site was not chosen merely for containing `super`: the release version of
this same method direct-called this exact target.

## The patch keeps zero source arguments

    release   String target() => super.close();
    patch     String target() => 'WRAP:${super.close()}';

Behaviour changes; the super call stays zero-argument.

## GATE 2 — real `shorebird patch ios` against release 141

    Running flutter precache... Done          (product hydrated, no manual step)
    Building iOS patch with Flutter (ab29aee059)
    Verifying patch can be applied to release... Done
    Downloading Route B compiler for engine d4c0dbc2... Done
    Creating patch... Done
    Uploading iOS artifacts... Done
    Promoting patch to stable... Done
    ✅ Published Patch 1!                      EXIT=0

### The lowered replacement is the direct proof of admission

`build/route_b/replacement_0.dart`, produced by the compiler:

    @pragma('dyn-module:entry-point')
    @pragma('vm:never-inline')
    @pragma('vm:entry-point')
    String target(Leaf self) => 'WRAP:${$routeBSuper(
        self,
        'package:super_fixture/main.dart', 'Leaf', 'target', 'Method',
        1318,
        'close',
        'file:///…/superapp/lib/main.dart', 966, 'close', 'Method'
      ) as dynamic}';

All THREE fingerprints travel into the intrinsic — origin (library/class/member/
kind), site (offset 1318, member `close`), and expected target (fileUri,
fileOffset 966, name, kind). The instance method is lowered to a top-level
function taking the receiver as argument 0, exactly as narrow-v1 specifies.

    patch.sbrbptch             ea881e2dafc090248079a106bc40dc2a41cd26ed23ed19bd4bdc32166d36fd23
    replacement_0.bytecode     5c62f39b8b99b43478a70edf5153e8fcdbb21babeafac4c101478180241f268f
                               1102 bytes; WRAP: x1, target x1, routeBSuper x1
    replacement_0.dart         4a1f00aa6dd5a3a720ace509c2cb87aa8fc635b7714d6a6260310c4d1ce275b4
    patched_verification.dill  1dbe57e054f1718c8ac7da30b20d404111d7ae15557cee4da8194026fd966258
    retention.json             14332b46e93d905a4bc9ac5e0cf4e9b23f4fa06ce4c4831c99353110b607ebbb
    dynamic_interface.yaml     c0b5945dfa2313c46c13165a93955a8800ec5f13365e4d9e13fd46c450c99091

`patched_verification.dill` exists, which is the 0017 dual-kernel verification
input — the release import kernel bound the replacement while the patched
no-AOT kernel verified the super site.

### A second product-order fix was needed to get here

`patch_command` asserted coherence BEFORE `installRevision`, exactly as
`release_command` had. It refused with
`COHERENCE_UNDETERMINABLE: …/ios-release/gen_snapshot_arm64 is missing` — which
was residue from my own Gate-3-style negative control, and precisely what the
contract should heal. Coherence now runs after selection and hydration there
too, scoped to the RELEASE's revision. 89/89 patch-command tests pass.

Also recorded: the candidate CLI rebuilds its snapshot only on a COMMIT, so an
uncommitted source copy can silently run stale code. Verified that release 141's
producing `release_command.dart` is byte-identical to what CLI6 `5cdae1e4`
committed, so 141 was not produced by unrecorded code.

## GATE 3 — the admission rule can fail, and does

FIRST ATTEMPT WAS THE WRONG CONTROL, and is recorded as such. Moving the super
call into `Leaf.close()` refused — but at the CALL-SITE gate:

    package:super_fixture/main.dart#Leaf.close
      the release contains no surviving call site for it, so a patch would
      attach and change nothing.

True, and fail-closed, but it never reached the narrow-v1 rule. It proves
nothing about release-evidence admission.

CORRECTED CONTROL — same method, same proven-patchable site, only the TARGET
differs. `Leaf.target` patched to call `super.toString()`, which is
zero-argument and which the release version of `target` never direct-called:

    super.toString() resolves to a target this release never direct-called from
    `target`, so there is no evidence it has executable code in the release.
    Route B carries a super call only when the released version of the same
    method already made one to the same target

    EXIT=70, nothing uploaded.

So admission is controlled by the release-evidence rule, not by whether super
syntax compiles. The negative control was NOT published.

## Not yet claimed

Gates 4 and 5. The patch is published but nothing has executed it. The device is
wired and identified:

    iPhone 7, iOS 15.8.8, UDID 8cb4bc982ddf6437b1952520edee80f898196c74

`devicectl` reports it "unavailable" while `ios-deploy -c` and `idevice_id` both
see it — the recorded iOS 15 blindness, not a real absence.

Release 141 was built `--no-codesign`, so device installation requires signing
the generated `.xcarchive` first. And Gate 5 step 5 is a HUMAN TAP, which I
cannot perform.

### Discriminator ready for Gate 4

    exact   super.close() -> Ticker.close() -> WRAP:TICKER:APP-STATE
    virtual super.close() -> Leaf.close()   -> WRAP:LEAF:APP-STATE
    release (unpatched)                     -> TICKER:APP-STATE

The app renders the raw string plus a named verdict, so a photograph
distinguishes all three without reading a log.
