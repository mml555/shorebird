# A_006 — CLEAN SURVIVAL. Counts toward the reproduction tally.

PM ruling, recorded at the run rather than only in a commit message.

    primary evidence      COMPLETE
    syslog                UNUSABLE
    corroboration         REDUCED
    verdict               counts as a clean A observation

Primary durable evidence establishes a healthy first activation of patch 5:

    pid 50807   DART_MAIN_ENTERED ACT-V6 -> FIRST_FRAME +38ms
                heartbeats +0 +100 +250 +500 +1000 +2000 +5000ms   7/7
    success_diag  pid=50807 patch=5
    new crash reports  0 immediate, 0 delayed
    frozen surfaces INTACT, engine byte identity VERIFIED

Syslog was always corroborative in this design. **The asymmetry that makes this
ruling sound:** had A_006 *disappeared*, the missing syslog would have left the
classification incomplete — no SpringBoard or jetsam termination reason. Because it
stayed alive, nothing further was needed from syslog to call it clean.

Cause of the empty syslog: eleven orphaned `idevicesyslog` readers starving the
device's single syslog service. Fixed; see the harness README.
