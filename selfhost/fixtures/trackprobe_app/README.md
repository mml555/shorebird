# trackprobe_app — G6's track-selection fixture

Answers G6's device row: *"a patch reaches exactly the devices its track
selects, and no others."* The second clause is the hard one, and it is what this
fixture is shaped around.

## Why a separate fixture from `manual_api_app`

G8's fixture is a settled claim with committed device evidence. Re-releasing it
to add track buttons would put that evidence's app into a new state. This one is
a copy with per-track controls and its own `app_id`.

## The design that makes the negative falsifiable

Two patches, and **the order is the experiment**:

| patch | track | marker |
|---|---|---|
| 1 | `stable` | `TRACKPROBE-STABLE` |
| 2 | `beta` | `TRACKPROBE-BETA` — **published second, so it is NEWER** |

A device asking for `stable` must receive **patch 1**. If track selection were
not real — if the server or updater simply served the newest patch — the device
would receive **patch 2**, because patch 2 is newer. So "asked stable, got
STABLE" is a discrimination and not a tautology.

Publishing beta's patch *first* would have made the arm unfalsifiable: asking
stable and getting the stable patch would then be consistent with both
"tracks work" and "latest wins".

## Why the track is chosen in Dart, not in config

`compileShorebirdYaml` never copies `channel` (`shorebird_yaml.dart:68-70`), so
the updater falls back to `DEFAULT_CHANNEL = "stable"` (`config.rs:24`, `:148`)
and the server resolves `str('channel') ?? 'stable'`. An unmodified device
therefore always asks for `stable`. `checkForUpdate(track:)` / `update(track:)`
is the route that is actually open — the one PARITY's G6 row names — so the
track is a per-call argument here, never configuration.

`android/` is generated (`flutter create`) and gitignored; `pubspec.yaml`
resolves `shorebird_code_push` by **path** from `vendor/updater/`.
