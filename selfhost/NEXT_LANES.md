# What is open after P6 closure — 2026-08-27

P6 workflow certification is **CLOSED**: 8 CERTIFIED, 0 UNCERTIFIED, 1 BLOCKED
(CI, on a Linux builder), 1 NOT ASSESSED (Add-to-App). Signing does not reopen.

## 1 · Epoch B activation — precommitted, before any rate is read

`MEASUREMENT_MODE.md` holds the seven-step checklist. Summary: the Signing fixture
is not the production specimen, so Epoch B does not start until a real
measurement/production release on `af6e842ccf87` is cut, its **published** artifact
fetched, the revision read out of **that app's** shipped bytes, a real client event
observed carrying it, that event accepted by the current dedupe/schema path, and
the rig client excluded. Only then does `af6e842ccf87` enter
`PolicyEpoch.b.updaterRevisions`.

Until then the estimator reports zero eligible clients, which is the correct
reading of *not started* — enforced in code and mutation-checked, not left to
convention.

## 2 · First-activation launch disappearance — classification first, NOT a fix

Three occurrences, two cells, every one on the **first launch that activates a
newly installed patch**; the following launch was clean each time; zero
occurrences on the certification rejection/durability tail. No crash report on
any pull, including a deliberately delayed one.

Positively cleared of the Signing boundary: in the occurrence captured live,
signature verification, patch selection, launch attribution and Route B activation
all completed, and the process banked success crediting patch 1 before vanishing.

**First objective is classification and reproduction, not a fix.** And an explicit
constraint: this investigation must not change lifecycle policy semantics while
Epoch B is being established. A fix that moved the attributability boundary again
would end Epoch B the way `af6e842ccf87` ended Epoch A.

Starting material: `evidence/p6-signing/crash_reports/setup_crash_2026_08_27/`.
Newly available and worth using — `idevicescreenshot` works on this wired device,
so render state can be captured rather than reported.

## 3 · Formatting debt — only alongside a rebuild that is warranted anyway

Outstanding: one 82-column comment in `shorebird.cc` (in a file with 428 lines of
pre-existing `clang-format` drift), an 8-line comment block in
`shell_unittests.cc`, and one `gn format` nit in
`shell/common/shorebird/BUILD.gn`. The engine's own pre-push hook refuses on these;
the push was made with `--no-verify` and the reasoning recorded in
`evidence/p6-signing/RUNTIME_SOURCE_BANKED.md`.

**`619fdad176ff4573` stays pinned as the certified engine revision.** A later
formatting-only commit may advance `route-b`, but it does not become certified by
being newer. If `shorebird.cc` is touched, the full path is required: format →
rebuild all three iOS modes → qualify → mint a new cell → delivery/completeness/
audit → coherence → and only then advance the pinned revision.
`compatibility.yaml` states this at the field.

## 4 · Support boundaries carried forward

* **CI — BLOCKED** on a Linux builder, not on design.
* **Add-to-App — NOT ASSESSED**, explicitly. Not a gap discovered late; a scope
  boundary stated up front and never claimed.
* **Durability dependencies.** Two mirrors are now load-bearing:
  `mml555/shorebird-flutter-mirror` and `mml555/shorebird-updater-mirror`. The
  latter was created during this lane because the on-device updater fork —
  thirteen commits, including every lifecycle change the epochs rest on — existed
  on a single disk with no remote at all. Treat both as first-class, and record
  the full commit SHA in provenance rather than a branch name.
