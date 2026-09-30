// pack_patch.dart -- build a Route B patch container.
//
// This is the host-side half of step 4, and the shape `shorebird patch` will
// eventually wear (step 5). It stays a separate tool so the container format
// can be exercised without the CLI existing yet.
//
//   pack_patch.dart --release-build-id <hex> --out patch.sbrb \
//     --target 'package:app/main.dart#greet=greet.bytecode' \
//     --target 'package:app/main.dart#Holder.tag=tag.bytecode'
//
// cspell:words SBRBPTCH sbrb
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'patch_container.dart';

void main(List<String> args) {
  String? buildId;
  var outPath = 'patch.sbrb';
  final specs = <String>[];

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) _die('$a needs a value');
      return args[++i];
    }

    switch (a) {
      case '--release-build-id':
        buildId = next();
      case '--out':
        outPath = next();
      case '--target':
        specs.add(next());
      case '-h':
      case '--help':
        print('''
pack_patch.dart --release-build-id <hex> [--out patch.sbrb]
                --target '<library-uri>#<selector>=<bytecode-file>' ...
''');
        return;
      default:
        _die('unknown argument: $a');
    }
  }

  // Required, not defaulted. A container with no release identity is one that
  // will be applied to the wrong build eventually, and the failure would show
  // up as a corrupt interpreted body rather than a refusal.
  if (buildId == null) _die('--release-build-id is required');
  if (specs.isEmpty) _die('at least one --target is required');

  final targets = <PatchTarget>[];
  for (final spec in specs) {
    final eq = spec.lastIndexOf('=');
    final hash = spec.indexOf('#');
    if (hash <= 0 || eq <= hash) {
      _die("--target must be '<library-uri>#<selector>=<file>', got: $spec");
    }
    final file = File(spec.substring(eq + 1));
    if (!file.existsSync()) _die('no such bytecode file: ${file.path}');
    targets.add(
      PatchTarget(
        library: spec.substring(0, hash),
        selector: spec.substring(hash + 1, eq),
        bytecode: Uint8List.fromList(file.readAsBytesSync()),
      ),
    );
  }

  final bytes = writeContainer(releaseBuildId: buildId, targets: targets);
  File(outPath).writeAsBytesSync(bytes);

  stderr.writeln('wrote $outPath (${bytes.length} bytes)');
  stderr.writeln('  release build id: $buildId');
  for (final t in targets) {
    stderr.writeln('  ${t.library}#${t.selector}  ${t.bytecode.length} bytes');
  }
}

Never _die(String message) {
  stderr.writeln('error: $message');
  exit(2);
}
