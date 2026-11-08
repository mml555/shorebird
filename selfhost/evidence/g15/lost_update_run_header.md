# LOST-UPDATE RUN — reproducibility header

Recorded before the build. Interpretation table is `lost_update_precommit.md`,
frozen and unchanged.

    instrumentation commit  2199c3568c9f9af3a9b2df5ef16ea8d5d71e940d
    updater HEAD            2199c3568c9f9af3a9b2df5ef16ea8d5d71e940d   clean=yes
    flutter HEAD            2c7b8c3ea59253d3cda5a7d3f73ac3fa20f71a9f   (untracked .gcs_entries only)
    dart HEAD               9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c
    selfhost HEAD           35b4175671d842c43b621a1c6bfa43cdc674ff84   clean=NO

    rig cell BEFORE run     f8654294c253a132ae5da9e38ddf9aa85d6a257e
    release BEFORE run      105 / 1.5.0+1, App 2B1851FF, engine 4C4C442E
    patch BEFORE run        1, Installed, healthy (last=1, tally 0)
    device g15_mode         success
    server                  cps-assets:local-m9, migration 9, dedupe fix live

A fresh patch identity will be used: the instrumented engine forces a new cell and
a new release, so reuse does not arise.

## SUBSTITUTE FOR THE FINAL-FINGERPRINT CORRELATION

The trace's `fingerprint=` is Rust `DefaultHasher` over the serialized state, which
cannot be recomputed faithfully outside the binary. Rather than assume the last
`SAVE_END` line won, the durable state itself is read: `state.json` is pulled in the
same capture and inspected for whether `recovered_after_ambiguity` is present in
`queued_events`. That answers "what was actually on disk" directly, which is the
substantive question the fingerprint correlation was for.
