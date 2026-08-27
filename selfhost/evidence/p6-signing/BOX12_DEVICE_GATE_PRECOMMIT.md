# Box 12 device gate — acceptance precommitted BEFORE the run

Written before the cell is minted, so the criteria cannot be shaped by what the
device happens to do. Signing certifies only if every row below holds.

## Scope, and what is deliberately NOT repeated

Re-run: **one rejection launch and one recovery launch.** Nothing in the
attribution fix touches the cryptographic boundary, so these are NOT redone:

* Arm A (Dart→Rust signing seam)
* Arm B1/B2 (platform package signing)
* box 9 — the shipped release carries `strict` + DER(K1)
* box 10 — a valid K1 patch is accepted and executed
* host-side K2 verification (correctly signed under the wrong root)

Excluded variables, unchanged from Arm C: `install_only`, beta/alpha routing,
server rollback, corrupted patch bytes, modified hash metadata, debugger
launches, Android. **K2 remains the only intentional defect.**

## Preconditions

    cell           the newly minted one, activated via activate_cell.sh
    coherence      verify_toolchain_coherence.sh PASS for ios
    updater        af6e842ccf87 read out of the SHIPPED app's engine bytes,
                   not the build log, and f729f958e9be ABSENT
    app state      uninstalled first, so patch 1 can be the known-good fallback
    keys           K1 trusted (in the release), K2 wrong; K1 != K2 measured
    device         iPhone 7 / iOS 15.8.8, wired, no debugger, every launch a tap

## The wire-level proof that the new path ran

This is the device equivalent of the host mutation test, and it is a REQUIRED
row rather than a nice-to-have. Across every launch:

| assertion | why |
|---|---|
| `Preparing next boot.` **present** | the single atomic call was reached |
| `Reporting launch start.` **ABSENT** | the old three-call sequence is genuinely gone. Its Rust function still exists, so its ABSENCE from the log — not the binary — is what proves the engine no longer uses it |

If both the old and new lines appear, the run is void: something still reports
launch start, and the defect can recur.

## Launch sequence

    L1  install release, launch          -> SIGN-V1   (base release)
    L2  patch 1 (K1) installed, launch   -> SIGN-V2   (patch 1 executes)
    L3  patch 2 (K2) installed, launch   -> SIGN-V2   THE REJECTION LAUNCH
    L4  launch again, nothing published  -> SIGN-V2   THE RECOVERY LAUNCH

`SIGN-V3` is patch 2's marker and must **never** render, on any launch.

## L3 — the rejection launch

| # | assertion | source |
|---|---|---|
| 1 | renders `SIGN-V2`, not `SIGN-V3`, not `SIGN-V1` | screen |
| 2 | `Patch signature is invalid` | syslog |
| 3 | `Next boot candidate rejected` | syslog |
| 4 | `Prepared boot of patch 1.` | syslog |
| 5 | active path resolves to `patches/1/dlc.vmcode`, digest == P1 | syslog + digest |
| 6 | `last_booted_patch == 1` — **NOT 2** | `pointers.json` |
| 7 | `patch 1: Installed` **and `patches/1/dlc.vmcode` still on disk** | state pull |
| 8 | `patch 2: Bad{ValidationFailed}` | state pull |
| 9 | `success_diag` last entry names `patch=1` | state pull |

Row 6 is the one the old code failed. Row 7 is the consequence that made it
visible: with attribution correct, `cleanup_older_than` cannot reach patch 1.

## L4 — the recovery launch, which is box 12 itself

| # | assertion |
|---|---|
| 10 | renders `SIGN-V2` — **patch 1 continues**, not the base release |
| 11 | `Patch 2 is known bad, skipping.` |
| 12 | active path is `patches/1/dlc.vmcode` again |
| 13 | patch 1 still `Installed` with its artifact present |
| 14 | no `Bad{BootCrash}` tombstone anywhere |

Row 10 is the exact assertion that FAILED in `ARM_C_DEVICE_SIGNATURE.md`, where
the device rendered `SIGN-V1`.

## Anti-vacuity — the patch must actually reach the verifier

A patch refused before verification would satisfy rows 2–14 while proving
nothing about signature checking. So, as in Arm C:

* `__patch_download__ 2` and `__patch_install__ 2` both recorded server-side;
* the client logged that patch 2 will launch on next restart;
* patch 2's on-disk artifact digest equals the server's recorded hash.

## The crashes — a stated stopping rule, decided in advance

Three by-hand launches in the Arm C reproduction crashed before render, each
followed by a clean launch. They are undiagnosed. Decided now, so the outcome
does not get rationalised later:

* crash reports pointing into **updater / Route B / engine initialization** →
  open a blocker before P6 closure;
* crash resolving to an **external launch/permission/harness** condition →
  document and keep outside Signing;
* **still unexplained but recurring** on this rejection run → stop and
  investigate before declaring P6 closed.

Crash reports are preserved BEFORE the run, not after, since the device rotates
them.

## Verdict rule

Signing → `CERTIFIED` only if rows 1–14 hold, both wire-level rows hold, the
anti-vacuity rows hold, and the crash rule does not trigger a blocker. Any single
failure leaves it `UNCERTIFIED` with the failing row named.
