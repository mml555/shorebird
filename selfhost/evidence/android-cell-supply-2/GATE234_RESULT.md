<!-- cspell:words armeabi embedding canonicalization canonicalizer canonicalize armv clonefile unmutated -->

# ANDROID-CELL-SUPPLY-2 · Gates 2–4 — the 30-member schema, qualified

2026-09-04. **59 controls, 0 failures.** Full log:
[`gate234_qualification.log`](gate234_qualification.log), harness
[`../../engine/route_b/qualify_android_cell.sh`](../../engine/route_b/qualify_android_cell.sh).

Nothing live was published by this run — control Z proves the live overlay was
never written and re-verifies `cd848320…` at 16/16 afterwards. The scratch
address was `f85251f344600ae08196925a174e9cff8f0ff18e` over 30 members.

## What changed in the product

| | |
|---|---|
| **`lib/v2_canonicalize.py`** (new) | the canonicalization rule, extracted to ONE file and taught the Maven POM |
| `mint_route_b_cell.sh` | uses that file; renders POMs; discovers publish roots instead of listing them |
| `verify_cell_members.sh` | uses that file; adds the Maven coordinate check; accepts a scratch manifest registry |
| `artifact_policy.conf` | a `macos-ios-android` cell — 30 members |
| `Caddyfile` | `@must_be_local` covers all three release ABIs, not only arm64 |
| `check_protection_matchers.py` | asserts the Android coverage, and asserts what must stay uncovered |
| `stage_android_cell.sh`, `qualify_android_cell.sh` (new) | staging and the gate |

### One authority, because two copies had stopped being safe

`mint_route_b_cell.sh` and `verify_cell_members.sh` each carried their own inline
copy of the canonicalizer. They agreed — but nothing *made* them agree, and the
asymmetry matters: a rule added to the mint and forgotten in the verifier
publishes cells the verifier rejects, while a rule relaxed in the verifier and
not the mint reports **a drifted cell as intact**. Adding a third rule to two
places was where that stopped being acceptable, so both now call
`lib/v2_canonicalize.py`.

Proven not to be a rewrite in disguise: it reproduces `cd848320…`'s two
addressed metadata digests exactly (`0f4e4cb2…` for `artifacts_manifest.yaml`,
`2bb28bc2…` for `engine_stamp.json`) and the live cell still verifies 16/16.

### The POM rule, and the gap a negative control found

Permitted: **exactly one** occurrence of the address, on a line whose content is
exactly `<version>1.0.0-%H</version>`, **positioned before `<dependencies>`**.

The position half was not in my first version, and the control for "the hash in
a dependency `<version>`" is what exposed it: a dependency's version line is
*character-identical* to the project's once stripped, so exact-line matching
alone **accepted the smuggle**. Content cannot discriminate here; position can.
Recorded because the rule looks complete without it.

A POM declaring its version after `<dependencies>` is now refused. That is valid
XML, no generator here emits it, and a loud refusal is the right answer to a
shape this schema has never seen. It is deliberately not generic XML rewriting.

### Publish roots are discovered, not listed

`v2_publish_tree` enumerated `flutter_infra_release/flutter` and
`download.shorebird.dev/shorebird`, which worked while `%H` was always one
directory directly under a known root. Maven breaks that shape twice over: the
version sits four levels down (`…/<artifact>/1.0.0-%H/`) *and* in the filename.
A hard-coded list would have published **nothing** for those eight members while
the manifest still named them — a cell that authenticates against an overlay
which cannot serve it. Roots are now every directory whose own name carries `%H`
and whose ancestors do not, and filenames are rendered inside the staging tree
before any move, so the overlay still sees exactly one mutation per root.

### The Maven coordinate check, which canonicalization cannot do

`canon_hash` proves a POM's *bytes* are the addressed ones. It says nothing
about whether the version the POM declares matches the path it is served from —
and that is the one thing Gradle enforces (`bad version: expected=… found=…`).
Control G4 builds exactly that: a POM whose wrong version contains **no
occurrence of the cell hash at all**, so canonicalization passes it through and
only the coordinate check can see it. Without that check the failure surfaces on
a developer's machine.

## The controls

**Membership and staging.** The twin `macos-ios` / `macos-ios-android` lines are
checked mechanically for divergence and for dropped paths (10 shared, 0 of
either) — duplication is a deliberate choice, so the agreement cannot be left to
hope. Policy derives 30 for the new cell and still 16 for the old one.

**Provenance of the iOS half, stated exactly.** 14 members byte-identical to the
donor; `engine_stamp.json` identical in **canonical form** (it differs only as
template-vs-rendered); and `artifacts_manifest.yaml` differs in **exactly 2
lines**, checked as a count.

That last one is a deliberate delta, not a slip. Its `# target:` line said
`ios`. Carrying that onto a cell that also serves Android would be a quiet
falsehood in the record, so it is regenerated by the product's own
`generate_manifest.sh` with `--target ios+android`; the override list is copied
verbatim. **So the honest claim is 15 of 16 byte-identical plus one deliberately
regenerated, never "16 byte-identical".**

**Mutation — one byte must move the address.** Five members, one flipped byte
each, on copy-on-write clones:

| member mutated | address |
|---|---|
| *(unmutated clone)* | `f85251f3…` — the baseline |
| Maven JAR (`arm64_v8a`) | `adb81cd4…` |
| arm64 `gen_snapshot` | `a19449f3…` |
| arm64 `artifacts.zip` | `e205d36c…` |
| **armv7 `gen_snapshot`** | `ff72c8ff…` |
| **x86_64 `gen_snapshot`** | `292ff441…` |
| an ordinary POM field (`<packaging>`) | `8087b4a4…` |

The unmutated clone is the control that stops the other six being vacuous: if
cloning alone perturbed the address, every "address moved" line would mean
nothing. The `<packaging>` case exists so "the POM is canonicalized" cannot be
misread as "the POM's content does not matter".

**Refusal — 7 controls, each asserting the refusal TEXT, not merely a non-zero
exit.** A script that dies for an unrelated reason must not read as a passing
negative control.

| probe | refused with |
|---|---|
| baseline: the project `<version>` | **accepted** — so the rest are about placement |
| hash in a dependency `<version>` (isolated to one line) | `outside the project <version> element` |
| hash in a POM comment | `outside the project <version> element` |
| a *second* `<version>1.0.0-hash</version>` | `2 hash-bearing lines, exactly 1 permitted` |
| a second hash on `engine_stamp.json`'s single line | `residual hash after canonicalization` |
| hash on a data line of `artifacts_manifest.yaml` | `on a non-comment line` |
| hash in a member with no permitted field | `no permitted hash-bearing field` |

Two of these were **wrong on the first attempt and looked like passes**: the
dependency probe replaced all four `2.7.0` versions, so the occurrence budget
refused it before the placement rule was ever reached; and the `engine_stamp`
probe asserted a budget message that cannot fire for a single-line JSON file.
Both now isolate what they claim to test, and the dependency probe asserts
"exactly one hash-bearing line" *before* asserting the refusal.

**Publication and fetch-back.** 30 rendered paths present; 8 Maven files under 4
version directories; no literal `%H` in any published path or any rendered
metadata body; 4 of 4 POMs declaring `1.0.0-<address>`; **24 of 24 non-metadata
members byte-identical after publication**; and the published tree reconstructs
the addressed manifest byte-for-byte and recomputes the address.

**The verifier made to go red, four ways.** A green verifier proves nothing
until it has been falsified: one byte in a published JAR → `DRIFTED` on the
exact member; the address smuggled into a forbidden POM location → refused, not
normalised; a coordinate mismatch → reported; a member removed → `MISSING`, not
a silent pass. Green again after every probe was reverted.

**Transaction.** A second publish refuses; a collision on a *Maven* root refuses
the whole transaction and leaves the pre-existing bytes untouched with no other
root moved; a stage missing one POM refuses before any address exists and banks
no address.

**Protection.** All 14 identity-bearing members are must-be-local at the new
address; the 9 probed cache/transport paths remain fallback-permitted, so the
fix is narrow. The matcher checker was itself falsified — reverting the regexp
to arm64-only produces exactly 16 `NOT PROTECTED` findings and exit 1.

## The `@must_be_local` change, and what it changes

    android-arm64-release/        ->  android-(arm|arm64|x64)-release/

ANDROID-CELL-SUPPLY-1 named this asymmetry: 4 of the 14 identity-bearing members
were fallback-permitted, and each carries the host `gen_snapshot` that compiles
the `libapp.so` shipping for armv7 and x86_64.

**This changes behaviour for mapped hashes that do not publish those paths: they
now 404 instead of falling through to the pinned revision.** That is intended,
it is what arm64 has always done, and it is the right answer for a cell whose
Android support is recorded as unsupported — a loud absence rather than a
different lineage's engine, which is the silent cross-toolchain mix that cost a
full warm run in August.

Maven needed no change: `download.flutter.io/io/flutter/` was already protected
host-wide and hash-generically, which is the only thing that can work there.

## Two process notes

**A control caught me editing under a running transaction.** An earlier run
failed with `v2: artifact_policy.conf changed during the transaction` — because I
added a `cspell` line to that file while the qualification was running. The
policy freeze is not decoration; it fired on a real concurrent edit.

**`DONOR` was silently emptied** by sourcing the mint library, which declares its
own `DONOR=""` for argument parsing. `stage_v13_cell.sh` already records this
trap; I walked into it anyway and section B reported 0 of 14 byte-identical.
Both new scripts now use `CELL_DONOR` and restore it after sourcing.

## Not done in this gate

Gate 5 (mint and publish live, wire the CDN, fetch back through it) and gate 6
(prove the 24-object Android workflow closure resolves against the new cell).
Physical Android patch qualification remains out of scope.
