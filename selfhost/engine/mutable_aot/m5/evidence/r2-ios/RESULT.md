# R2 iOS — production replacement smoke: PASS

Real device: **iPhone9,1 (iPhone 7), iOS 15.8.8 (19H422), arm64**, wired.

## Artifact chain

```
fork                    5878283d55e (clean tree, 12193b5ef74)
Flutter.framework       sha256 c9c7f3e875d78e4ef988a48c0b3504e7310bc4a65d3a184ad2a9a8e9c8a3327a
                        12 Dart_Maot* symbols exported, rebuild only, no source change
gen_snapshot            out/ios_release/clang_arm64/gen_snapshot, built from the same fork
                        35 maot strings, target-os stamp "ios"
snapshot version hash   a017f0159cc650151f56047aad3763ee  (generator == runtime)
App.framework           4851648 bytes, arm64, minos 13.0
signing                 Apple Development: Pesach Brody, team SK85S6YZP9,
                        wildcard development profile e3a92ae5 (device provisioned)
```

## Selection proven non-vacuous before deployment

18 declarations selected under `package:maot_smoke/`.
`cls:Hot::method:v`: installable=True, optimizer_escapes=0,
indirect_call_sites_emitted=1.

Negative control proven genuinely incompatible before deployment:
`BadArity` differs from `Hot` in both ABI (p2/2 vs p1/1) and calling
convention (fixed3 vs fixed2).

## On-device result

```
platform=ios   version=Version 15.8.8 (Build 19H422)   namespace.len=64
ffi.malloc / install / version / dump / tramp   all resolved from the
                                                production Flutter.framework

hot.before = OLD:20        version.before = 1

negative.badarity.install = -3      <- REFUSED, fail-closed
negative.hot.after        = OLD:20     behaviour unchanged
negative.version.after    = 1          version unchanged

install.v2 = 0   hot.v2 = NEW:30    version.v2 = -102
install.v3 = 0   hot.v3 = NEW2:17   version.v3 = -103

other.before = other.v2 = other.v3 = OTHER:50    cross-wiring control untouched
```

## Identity invariants, from the on-device registry dumps

FROZEN across before / v2 / v3:

```
declaration_id                lib:package:maot_smoke/main.dart::cls:Hot::method:v
id_declaration_function       4478479745
id_declaration_current_code   4477769217
id_trampoline_code            4477769217
id_trampoline_entry           4415566852
id_dispatch_cell              4480045441
id_release_body               4477769345
```

MOVING, all three distinct:

```
id_cell_impl_function   4478479745 -> 4478479585 -> 4478479425
id_cell_impl_code       4477769345 -> 4477768961 -> 4477767809
id_pinned_current_body  4477769345 -> 4477768961 -> 4477767809
```

installable=True, optimizer_escapes=0 and indirect_call_sites_emitted=1 at
every stage; descriptor version 1 -> 2 -> 3.

No `Dart_MaotDiagnosticCellSwap` was used. Every transition came from
production `StageReplacement`.

## What went wrong on the way, recorded

1. **Snapshot target-OS mismatch.** `maot_host/gen_snapshot` is built with
   `target_os=mac` and stamps snapshots `macos`; the device rejected it with
   "the snapshot requires ... arm64 macos ... but the VM has ... arm64 ios".
   I had proven the snapshot *version hash* matched but never checked the
   *configuration string*. Fixed by building gen_snapshot from the same fork
   inside the iOS engine output.
2. **The engine's own gen_snapshot was stale** (Aug 31, 0 maot strings) — the
   `flutter_framework` target does not build it.
3. **ios-deploy leaves the app trapped.** Launching through its lldb attach
   produced `EXC_BREAKPOINT` in `lldb_image_notifier` with
   `parentProc: Exited process`; the app never ran. Crash reports pulled with
   `idevicecrashreport` showed it was the debugger, not the code.
4. **No console on device.** `print` in a Flutter release build reaches
   neither lldb nor the 290k-line syslog. The fixture writes a progressive
   trace file instead, and runs in `main()` before `runApp` so a UI that
   never appears cannot hide the result.
