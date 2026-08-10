<!-- cspell:words idevicesyslog idevicescreenshot noninteractive premain -->

# Route B device evidence

Screenshots kept because the alternative is a claim with nothing behind it.
Standing rule from `MEDIA_PRESERVATION.md` applies here too: **store
verification output**. The first seam-6 pass was observed and then lost, and
re-running it cost two device launches — cheap that time, not always.

## seam 6 — native pre-main activation, 2026-08-10

| file | build | difference from the other arm | `route B value` |
|---|---|---|---|
| `seam6_patched.png` | 6.0.0+1 | `assets/routeb_patch.bytecode` **present** | **NEW** |
| `seam6_control.png` | 6.1.0+1 | that asset **absent** | **OLD** |

Everything else is held constant: same engine (`d393ed01`), same `main.dart`,
same `--patchable_static_calls` snapshot, same device
(`8cb4bc98…`, iPhone 9,1 / iOS 15.8.8), same launch path. The `pubspec.yaml`
delta between the two builds is three lines — the asset declaration and its
comment.

Both apps read the value **once, in `initState`**, and the build contains no
`attachBytecode` / `detachBytecode` / `dynamic_modules` reference at all. The
app therefore has no way to patch itself and no window in which `OLD` could be
observed before a patch landed. The only thing that can have replaced that body
is `Dart_RouteBActivatePatch` running from `root_isolate_create_callback`
(`dart_isolate.cc:163`), before `RunFromLibrary` at `:174`.

### Attribution is behavioral, not log-backed

The hook logs a `ROUTEB:` chain via `FML_LOG`, and **none of it is
recoverable**. No engine log line of *any* kind reaches `idevicesyslog` for a
`--noninteractive` launch on this device — not Flutter's own either — because
those go to stderr, which iOS does not route to syslog. So the absence of
`ROUTEB` lines says nothing about whether the hook ran.

That makes this A/B a *different evidence type* than originally planned, not a
weaker version of the same one. What it rules out is what matters: the control
eliminates the app, the engine, the snapshot flag and the source as
explanations, leaving the hook.

The earlier `ios-deploy --envs` attempt is the same fact inverted — it produced
`OLD` with zero log lines, and only the screenshot told us anything at all.
That is why the trigger moved from environment to file presence: a test
*transport* failure, not a Route B failure.

## Reproducing

Both bundles are built by `build_4a_payload.sh` plus a normal fixture release;
the control is produced by removing exactly one line from `pubspec.yaml`.
Launch attached, so the process survives long enough to photograph — a
`--justlaunch` run is torn down by `safequit` before the first frame:

```bash
ios-deploy --noninteractive --bundle /tmp/seam6_patched.app &   # leave attached
sleep 20
idevicescreenshot seam6_patched.png
```

Screenshots are downscaled (`sips -Z 900`) so the directory stays small; the
text is still legible, which is all they are for.
