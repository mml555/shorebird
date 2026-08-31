# What is open after P6 closure

> ### STATE UPDATE — 2026-08-28
>
>     Epoch B                        ACTIVATED at f9d784ad, COLLECTING from zero
>     First-activation disappearance CLOSED -- NOT REPRODUCED (evidence 78c9324a)
>                                    historical events remain unexplained
>     NEXT ACTIVE                    CI / noninteractive -- Linux builder
>     DEFERRED                       Add-to-App; formatting-only engine rebuild
>
> Sections 1 and 2 below were written before either outcome and are kept for the
> reasoning they record, not as current status.
>
> **Frozen operational rule from the reliability lane:**
>
>     WILL_TERMINATE = orderly termination
>     WILL_TERMINATE != identity of initiator
>
> And its generalisation, which cost nine defects to learn: **observational
> tooling must be treated as potentially causal until independently validated.**
> Every instrumentation defect found in that lane would have biased toward
> *finding* a problem.

P6 workflow certification is **CLOSED**: 9 CERTIFIED, 0 UNCERTIFIED, 0 BLOCKED,
1 NOT ASSESSED (Add-to-App). Signing does not reopen, and neither does CI: R12 was
certified 2026-08-30 on two independent clean Linux/amd64 executions
(`evidence/r12-linux-ci/`).

R12 proves the noninteractive workflow runs on a clean Linux builder. It does
**not** mean a maintained GitHub Actions / self-hosted-runner deployment exists —
that is an operationalization task, not a remaining parity blocker.

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

**Activate as a CANARY, not as fleet collection.** One controlled production
specimen discharging the checklist, with a real non-rig client. Broad collection
comes after, not as part of activation.

**The allow-list change is its own commit**, containing nothing else:

    b(
      updaterRevisions: {'af6e842ccf87'},
      cell: '4792f0eca461f3761001a1adbe131b4b115e3684',
      closed: false,
    )

Combining it with unrelated work would make the moment the sample started
impossible to identify later from history alone. Before it: Epoch B metrics `[]`.
After it: only `af6e842ccf87` clients may appear, Epoch A stays separately
queryable, and the two are never unioned.

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
would end Epoch B the way `af6e842ccf87` ended Epoch A — Epoch C on arrival.

**Do not touch**, while Epoch B is starting: boot-start timing, success timing,
the ambiguity definition, retry accounting, retirement behaviour.

**Instrument outside that semantic boundary instead:** process lifetime
timestamps, app lifecycle callbacks, scene and application termination signals,
SpringBoard/process-exit observations, and any durable trace written *after*
launch success. If a reliable reproduction eventually points at something
downstream of launch-success, fix that layer — and prefer a fix that leaves the
ambiguity contract untouched.

This is the highest-priority reliability investigation, but it does **not** block
the small canary needed to activate the telemetry epoch.

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

## 5 · Frozen operational rule — branches are not provenance

Never identify certified source as `route-b` or `selfhost/3.44.8`. Those are
transport refs and they move. Provenance is **repository + full immutable SHA**:

    evidence       mml555/shorebird                 3b6a5ab83bd5d36fd022731b67c918be348c57f8
    control plane  mml555/shorebird                 58b4998007f1736b654e00e9034116f38b459be4
    engine         mml555/shorebird-flutter         619fdad176ff457331b50230b9511e7230a6ed93
    updater        mml555/shorebird-updater-mirror  af6e842ccf87a083d1598b1e7c9e0868c5731931

The 12-character `updater_revision` in `compatibility.yaml` is the **wire** form
the client stamps into events — an eligibility key, not a provenance identity.
Both are recorded, and the distinction is stated at the field.

## 6 · Standing rule from here

**Stop touching the certified runtime** except for a demonstrated production
defect. The next meaningful milestone is not a code change: it is *Epoch B
activated from a real production specimen and collecting from zero.*

    Mechanism engineering       CLOSED
    P6 workflow certification   CLOSED
    Signing                     CERTIFIED
    Lifecycle policy Epoch A    CLOSED
    Lifecycle policy Epoch B    ACTIVE / COLLECTING — 0 / 100
    CI / noninteractive Linux   CERTIFIED — two independent clean arms
    Add-to-App                  DEFERRED, explicitly unassessed
    formatting-only rebuild     DEFERRED, negative value on its own
