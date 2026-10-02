# Baseline — what this fork actually is, 2026-08-18

Written to answer three questions before any restructuring: how far ahead are we
*really*, what is proven versus experimental, and what is reviewable.

## 1. THE DIVERGENCE IS NOT 40k LINES — IT IS 3.8M, AND 98% IS NOT OUR WORK

    vendor/                    3,727,214 lines   15,945 files   <- vendored copies
    selfhost/engine               35,094            251
    packages/shorebird_cli        19,249 / -1,204    98
    packages/code_push_server     18,426             57
    selfhost/evidence             15,373            421
    selfhost/fixtures              5,752             57
    selfhost/ docs+scripts+plans  ~20,000            60
    packages/code_push_runtime     2,611             18

**`vendor/flutter` alone is 15,724 tracked files.** It is a complete Flutter
checkout committed into this repository for bootstrap durability
(`UPSTREAM_INDEPENDENCE.md` item 10). It is the single reason the fork looks
unreviewable.

**We now keep FOUR copies of Flutter:**

| copy | purpose | status |
|---|---|---|
| `vendor/flutter` (15,724 files, in-repo) | bootstrap durability | **redundant** |
| `selfhost/cdn/mirrors/flutter.git` (bare, 2,605 refs) | offline bootstrap | bootstrap-from-mirror VERIFIED |
| `mml555/shorebird-flutter-mirror` | offsite insurance | RESTORE-tested 2026-08-06 |
| `mml555/shorebird-flutter` | **our fork, carries `route-b`** | new, 2026-08-18 |

Only build scripts reference `vendor/flutter`, and only as a DEFAULT root that
already accepts `--root` (`selfhost/engine/build.sh`,
`selfhost/engine/publish_to_store.sh`).

`vendor/updater` (221 tracked files) is different and STAYS: it is the Rust
updater source we build and ship, and its 1.6G `target/` is correctly untracked.

## 2. WHAT IS PROVEN, WHAT IS IN TESTING, WHAT IS EXPERIMENTAL

Maturity is already recorded across the tree; consolidated here.

### PROVEN — has device or independently-corroborated evidence

| capability | evidence |
|---|---|
| Route B iOS end-to-end execution | 8 specimens, 4 with device screenshots showing patched value + `code patch` (`routeb_behavioral_evidence_audit.md`) |
| Foldability as the execution discriminator | isolated on a matched pair, then confirmed by one-line repair on the failing target (`foldability_verdict.txt`, `routebvalue_repair_verdict.txt`) |
| `0012`/`0013` target→pool instrument | established, and positive locator proven (`claim1_0012_instrumentation_verdict.txt`) |
| Mint provenance generator | `mint-provenance/proven_verdict.txt` |
| Publish durability | both halves content-read; `audit_log`/`releases`/`patches` dense, high-water == max(id) (`durability_audit_log_verdict.md`) |
| Self-host independence | `UPSTREAM_INDEPENDENCE.md` — 6 items **Built/Done**, incl. patch binary byte-identical to upstream's |
| PARITY surface | 191 PROVEN / 78 VERIFIED markers |

### IN TESTING — partially measured, blocked, or awaiting a step

| item | state |
|---|---|
| Tombstone / retry lifecycle | **parked mid-sequence**, one manual tap outstanding (`tombstone_lane_RESUME_HERE.md`) |
| Arm A (original specimen) | **INCONCLUSIVE** — not re-scored; a repaired successor passed (`STATUS.md`) |
| `TPOOL_AMBIGUOUS` | never observed in the field |
| Upstream Flutter bump `cac7b89` | merge cost measured (5 conflicts), NOT applied (`UPSTREAM_INTEGRATION.md`) |
| Windows / Intel-Mac host cells | deliberately `compat-mirrored`, not built |
| PARITY | 21 BLOCKED, 2 UNPROVEN, 2 INCONCLUSIVE |

### EXPERIMENTAL — works, but not a supported contract

| item | note |
|---|---|
| Route B itself | the whole bytecode-patching path is research; `compatibility.yaml` pins what is supported and Route B is not in the supported CLI contract |
| Engine patches `0001`–`0013` | now branched at `mml555/shorebird-flutter@route-b`; the `.patch` files are generated artifacts |
| PARITY | 7 EXPERIMENTAL markers |
| `code_push_runtime` | fork-only package, no upstream counterpart |

## 3. WHAT IS ACTUALLY REVIEWABLE

Stripping vendored copies and investigation artifacts, the fork's own reviewable
source is roughly:

    packages/code_push_server      18,426   the control plane (new package)
    packages/shorebird_cli         19,249   Route B CLI integration (69 modified upstream
                                            files are ADDITIVE: +763/-6 shaped)
    packages/code_push_runtime      2,611   runtime discovery package
                                   ------
                                   ~40,000  and this is the number to split

`selfhost/` (docs, scripts, fixtures, evidence) is fork-internal operational
material, not code review material. `selfhost/evidence` in particular is 421
files of investigation artifacts — binaries, screenshots, verdicts.

## 4. THE BASELINE FOR FUTURE INTEGRATION

    supported pin        CLI 1.6.115+selfhost.1, Flutter c15ef63794,
                         engine 69f9831c, updater 1f85c4ab, protocol 0.1.0+1
    upstream distance    8 commits behind origin/main; 3 are Flutter bumps,
                         1 is a real fix (aot_tools), 1 is Stripe (irrelevant)
    engine fork          mml555/shorebird-flutter @ route-b (base c15ef63794)
    dart branch          local route-b (base 6b58bb3a), 121,349 commits history,
                         NO REMOTE YET
    bump cost            5 conflicts / 39 files / ~3,350 upstream commits;
                         updater_rev UNCHANGED so the wire contract is safe;
                         SNAPSHOT_HASH WILL move
