#!/usr/bin/env bash
# cspell:words dartaotruntime
#
# p44_container_binding_compat.sh -- does the DEVICE-SIDE container reader still
# parse a container carrying P4.4's binding?
#
# WHY THIS EXISTS. The binding is an ADDITIVE header field under container
# format version 1. That reader REFUSES an unknown version on purpose ("a reader
# that tolerates unknown versions ends up defining the format by what it happens
# to accept"), so if it also refused unknown KEYS, adding the binding would
# brick every patch on the shipped engine -- and it would do so on device, after
# the CLI reported success.
#
# The claim is therefore not "unknown keys are probably fine". It is measured
# against the REAL packaging/patch_container.dart, the same source the engine
# side uses.
#
# PRECOMMIT: the device reader must return the release build id, the target
# count, the selector and the exact bytecode from a container that carries a
# binding. If it throws, the binding may not ship in the header and P4.4 needs a
# separate sidecar.
#
#   probes/p44_container_binding_compat.sh
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE=${HERE:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"}
RB=${RB:-"$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"}
REPO=${REPO:-"$(cd "$RB/../../.." >/dev/null 2>&1 && pwd)"}
DART=$OUT/dart-sdk/bin/dart

die() { echo "ERROR: $*" >&2; exit 1; }
[ -x "$DART" ] || die "no host dart at $DART"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# The reader is imported by PATH because it lives in the engine packaging tree,
# not in the CLI package. Copied rather than referenced across packages so the
# import resolves without touching either package's pubspec.
cp "$RB/packaging/patch_container.dart" "$W/patch_container.dart"

cat > "$W/check.dart" <<DART
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:typed_data';

import 'package:shorebird_cli/src/route_b_binding.dart';
import 'package:shorebird_cli/src/route_b_container.dart';

import '$W/patch_container.dart' as device;

void main() {
  final bytes = writeRouteBContainer(
    releaseBuildId: 'deadbeef',
    targets: [
      RouteBPatchTarget(
        library: 'package:app/main.dart',
        selector: 'value',
        bytecode: Uint8List.fromList([1, 2, 3, 4]),
      ),
    ],
    binding: RouteBPatchBinding(
      evidence: const RouteBReleaseEvidence(
        releaseBuildId: 'deadbeef',
        engineRevision: 'cell-1',
        compatibilityRevision: routeBCompatibilityRevision,
      ),
      receipts: const [
        RouteBTargetReceipt(
          library: 'package:app/main.dart',
          member: 'value',
          survivalResult: 'ONE_OR_MORE_QUALIFYING_CALLSITES',
        ),
      ],
    ),
  );

  final read = device.ContainerReader.parse(bytes);
  if (read.releaseBuildId != 'deadbeef') throw 'build id';
  if (read.targets.length != 1) throw 'target count';
  if (read.targets.single.selector != 'value') throw 'selector';
  if (!identical(read.targets.single.bytecode.length, 4)) throw 'bytecode';
  print('    device reader: ok (build id, 1 target, selector, 4 payload bytes)');

  // And a container WITHOUT a binding must still parse, so the field really is
  // optional rather than newly required.
  final bare = writeRouteBContainer(
    releaseBuildId: 'deadbeef',
    targets: [
      RouteBPatchTarget(
        library: 'package:app/main.dart',
        selector: 'value',
        bytecode: Uint8List.fromList([1, 2, 3, 4]),
      ),
    ],
  );
  device.ContainerReader.parse(bare);
  print('    device reader: ok on a container with NO binding too');
  print('    CLI reader   : ok (\${RouteBContainer.parse(bytes).targets.length} target)');
}
DART

echo "==> the real device-side reader, against a container carrying a binding"
"$DART" --packages="$REPO/.dart_tool/package_config.json" "$W/check.dart"
echo
echo "PASS: the binding is additive — neither reader is disturbed by it."
