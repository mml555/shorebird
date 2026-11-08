<!-- cspell:words armeabi embedding armv canonicalization canonicalizer canonicalize pristine clonefile prebuilt gclient ninja cipd openjdk riscv ddm pathed unmutated -->

# ANDROID-CELL-SUPPLY-2 — the Android-capable cell exists, is served, and builds

2026-09-04. All six gates passed.

    new cell address              f85251f344600ae08196925a174e9cff8f0ff18e
    members authenticated         30 / 30   (on disk AND fetched back over HTTP)
    identity members built by us  14 / 14
    workflow closure resolved     24 / 24   (14 from the cell, 10 by fallback)
    Android release produced      YES  — exit 0, 48 MB APK, three ABIs
    Android patch qualified       NO   — deliberately out of scope

`cd848320…` is untouched and still verifies 16/16. `lineage.cell_address` in
SUPPORTED_STATE.yaml **still names `cd848320…`**: a release is not a patch, and
until an Android patch is physically qualified against the new cell, neither
cell carries an Android support claim.

## Provenance, per platform

There is deliberately **no single `producer_engine_revision`** for this cell.

| half | producer | how |
|---|---|---|
| 16 macOS/iOS members | `dfa2b24ac38477f3705ff0357530f33fe09474b8` | the bytes `cd848320…` already published |
| 14 Android members | `f1a59b8a1609c51397601c36d586ad7763d57153` | built by us; **parent is exactly `dfa2b24a…`** |

Relabelling the first 16 with the Android producer would be a false claim about
16 artifacts, so the record splits the field
([`../../engine/route_b/SUPPORTED_STATE.yaml`](../../engine/route_b/SUPPORTED_STATE.yaml), `cells:`).

And the member accounting is stated the way it actually is, not rounded up:

    14  byte-identical to cd848320's published bytes
     1  engine_stamp.json — identical in CANONICAL form (template vs rendered)
     1  artifacts_manifest.yaml — REGENERATED, `target: ios` -> `ios+android`
    14  newly built by us
    30

The regeneration is deliberate. Carrying `# target: ios` onto a cell that also
serves Android would be a quiet falsehood, so the product's own
`generate_manifest.sh` rewrote it; the override list is copied verbatim and the
diff is exactly two lines, asserted as a count.

## Gate 1 — the build, and the one engine change

[`GATE1_RESULT.md`](GATE1_RESULT.md). armv7 could not configure at `dfa2b24a…`:
`create_macos_analyze_snapshot_{arm64,x64}_arm` demanded a host
`analyze_snapshot` that Dart declines to build for a 32-bit target. Option A was
authorized and the gate is Dart's own applicability predicate —
`x64 || arm64 || riscv64`, verbatim from `runtime_args.gni` — so it cannot
broaden the tool to a target Dart refuses.

Deliberately **not** the condition the brief pointed at; that one is false for a
macOS-host x64 build and would have dropped `analyze_snapshot` from x64, which
the fix is required to leave alone. Recorded as a deviation with the truth table.

Non-impact for arm64 was answered at the build-graph level — same 21,856
targets, identical target lists — after my first attempt at it (a byte
comparison across a hand-rewritten out dir) turned out to be an inconsistent
partial rebuild. That attempt is banked as **INVALID** rather than quietly
dropped.

## Gates 2–4 — the schema

[`GATE234_RESULT.md`](GATE234_RESULT.md), 59 controls, 0 failures,
[`gate234_qualification.log`](gate234_qualification.log). Headlines:

- the canonicalization rule now lives in **one** file used by both the mint and
  the verifier, and reproduces `cd848320…`'s two addressed metadata digests
  exactly
- the POM rule permits the address in exactly one place: the project
  `<version>`, **before `<dependencies>`** — the position half exists because a
  negative control found that a dependency's version line is character-identical
  to the project's once stripped, and exact-line matching **accepted the
  smuggle**
- publish roots are discovered rather than listed, because Maven puts `%H` four
  levels down *and* in the filename; a listed root would have published nothing
  for eight members while the manifest still named them
- a Maven coordinate check joins the verifier, with a control built so
  canonicalization cannot see the fault at all
- `@must_be_local` covers all three release ABIs; the matcher checker was
  falsified (reverting the regexp yields exactly 16 findings and exit 1)

## Gate 5 — published and served

[`gate5_publish.log`](gate5_publish.log),
[`gate5_mint/`](gate5_mint/) (manifest, address, address provenance).

    30 / 30  verified on disk
    30 / 30  fetched back THROUGH THE CDN and compared byte-for-byte
             (rendered metadata compared in canonical form)
     4 / 4   POMs declare 1.0.0-<address>, so Gradle's consistency check passes
    AUDIT CLEAN for f85251f3… (macos-ios-android), missing-required 0

The fetch-back is over HTTP on purpose. Publication proves bytes are on disk;
only a request through the thing a developer actually talks to proves the
rewrite rules, the protection matchers, the fallback map and the cache all agree
— and every one of those has been wrong at least once in this programme.

## Gate 6 — the ordinary Android workflow, against the new cell

[`gate6_workflow.log`](gate6_workflow.log), request log
[`gate6_requests.jsonl`](gate6_requests.jsonl), harness
[`../../scripts/acs2_gate6.sh`](../../scripts/acs2_gate6.sh).

A clone of the qualified CLI checkout, its Flutter's `engine.version` **committed**
to the new cell, `bin/cache/artifacts/engine` and every engine stamp deleted, and
an empty `GRADLE_USER_HOME`. The qualified checkout at
`/Volumes/build/route-b/shorebird-candidate` was only ever read, and still selects
`cd848320…` afterwards.

    shorebird release android --artifact apk   ->  exit 0
    app-release.apk  48 MB   three ABIs, each with libflutter.so + libapp.so

**Attribution, which is the whole question.** Every request went through a
recording forwarding origin that logged the body's sha256 — a 200 proves only
that *something* answered; the digest proves *which bytes* did
([`../../scripts/lib/acs2_attribute.py`](../../scripts/lib/acs2_attribute.py),
re-derivable from the banked log without rebuilding).

| | |
|---|--:|
| Android identity members served **from the new cell** | **14 / 14** |
| identity members not requested | 0 |
| identity members with wrong bytes | 0 |
| identity requests answered **via a redirect** | **0** |
| cache/transport paths served by fallback | 10 |
| total measured workflow closure resolved | **24 / 24** |

The 10 fallback-served paths are *exactly* the 10 objects ANDROID-CELL-SUPPLY-1
classified CACHE/TRANSPORT — the debug and profile engines `precache` fetches
unconditionally and a release build never consumes. The split was predicted by
measurement and reproduced by the CDN without being told: every `-release/`
object answered with 0 redirects, every profile/debug object with 1.

Only two non-200 answers in the whole run: a `400` on `/` (a probe) and the
`404` on `aot-tools.dill`, which ANDROID-CELL-SUPPLY-1 already proved incidental
by a run that succeeded without it.

**And the engine that ships.** The APK's `libflutter.so` is not byte-identical to
the cell's jar and cannot be: AGP strips debug symbols, so the packaged library
is 6–9% of the jar's size. A first version of this control asserted equality and
reported MISMATCH on three correct ABIs. The discriminator that survives
stripping is the engine revision string:

    arm64-v8a     13,878,552 bytes ( 8% of the jar)   producer x1, fallback x0
    armeabi-v7a    9,870,112 bytes ( 6% of the jar)   producer x1, fallback x0
    x86_64        15,572,672 bytes ( 9% of the jar)   producer x1, fallback x0

The negative is not vacuous: the fallback's own jar was checked first and names
*its* revision exactly once, so "zero occurrences" means the fallback engine is
absent, not that the string never appears in an engine.

## Things I got wrong, since they are part of the record

1. **`--dry-run` published for real.** Sourcing the mint library resets `DRY=0`,
   so the flag was silently discarded and step 2 wrote the live overlay. The
   controls had already passed 59/0, so the publication is at the qualified
   address and legitimate — but it happened via a flag bug, not by my decision
   to proceed at that moment. `DONOR` had already been clobbered the same way
   twice; the rule now is that nothing these scripts parse may share a name with
   a mint variable, and `--verify-only` exists so the proofs can be re-run
   without re-publishing.
2. **A policy edit under a running transaction** tripped
   `v2: artifact_policy.conf changed during the transaction`. The freeze is not
   decoration; it fired on a real concurrent edit of mine.
3. **The dry run left 525 MB of rendered artifacts in the evidence directory.**
   The rendered tree is a working copy, not evidence; the mint now removes it.
4. **Two negative controls that looked like passes** for the wrong reason, and
   **one APK control** asserting a byte-equality that a build-system transform
   makes impossible. All three are described where they live.

## Boundary

Not done, and not authorized here: physical Android patch qualification; moving
`lineage.cell_address`; any Android release cut; any change to `cd848320…`,
which remains immutable and verifying 16/16; any change to Route B compiler
behaviour (Route B is iOS-only and Android patches are bidiff).
