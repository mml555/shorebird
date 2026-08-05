<!-- cspell:words tearoff misparse minimises selfhost -->

# Dill table-selector inspection tools

The dill readers and the A/B harness used to locate the root cause documented in
[`../../TFA_ROOT_CAUSE.md`](../../TFA_ROOT_CAUSE.md).

Both need `package:kernel` and `package:vm` resolvable, so run them with the
Dart SDK **from the Dart tree you built**, pointed at that tree's package
config — a released SDK will not do, and the dill's binary format version must
match:

```bash
D=<dart tree>            # .../third_party/dart
O=<out/host_release_...> # the build dir containing dart-sdk/

$O/dart-sdk/bin/dart --packages=$D/.dart_tool/package_config.json \
  probe_length.dart app.dill
$O/dart-sdk/bin/dart --packages=$D/.dart_tool/package_config.json \
  dump_selectors.dart app.dill
```

- **`probe_length.dart`** — for `dart:core` `List` and `Map`, prints each
  member's assigned getter/method selector id alongside the `call_count`,
  `tear_off_uses` and `has_tearoff_uses` actually sitting at that id. This is
  the tool that showed `List.length` at `call_count=0` from `frontend_server`
  and `call_count=200` from `gen_kernel` for the same program.
- **`dump_selectors.dart`** — whole-table summary: selector count, how many
  have `call_count > 0`, how many are `torn_off`, and the count of *implausible*
  entries (values too large to be counts), with the top offenders listed.
- **`layout_scan.dart <dill> <A..G>`** — reads the same table under seven
  candidate binary layouts and reports, per layout, how many records come out
  with a `flags` byte greater than 3. Only two flag bits are defined, so that
  count is an alignment metric: the layout the writer actually used is the one
  that minimises it. This is what ruled out "Shorebird added a field" and showed
  the divergence is semantic. Layout `A` is vanilla's own format.
- **`fe_ab.sh`** — compiles one app twice, changing only the frontend binary,
  with the exact argument list `flutter_tools` builds for an iOS release.
  Requires `APP` and `PKG`; everything else has a default. This is the
  experiment the conclusion rests on.
