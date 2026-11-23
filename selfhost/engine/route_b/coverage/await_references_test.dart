// Tests for the analysis version 24 report of an `await` as a call of
// `Future.then` (`visitAwaitExpression`). Compiles `_source` with the host
// Dart, then reads the kernel back with a real type environment.
//
//   SRC=$HOME/shorebird-engine/flutter/engine/src
//   HOST_DART=$SRC/out/host_release_arm64/dart-sdk/bin/dart \
//   $SRC/out/host_release_arm64_ddm/dart-sdk/bin/dart \
//     --packages=$SRC/flutter/third_party/dart/.dart_tool/package_config.json \
//     selfhost/engine/route_b/coverage/await_references_test.dart
// cspell:words
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_environment.dart';

import 'analyze_coverage.dart';

var _failures = 0;

void check(bool ok, String what) {
  if (!ok) {
    _failures++;
    stderr.writeln('FAIL: $what');
  } else {
    stdout.writeln('ok: $what');
  }
}

const _source = '''
abstract class Ticker implements Future<int> {}
Future<void> ticker(Ticker t) async { await t; }
Future<void> plain(Future<int> f) async { await f; }
Future<void> nullable(Future<int>? f) async { await f; }
Future<void> nonFuture() async { await 1; }
Future<void> dyn(dynamic d) async { await d; }
Future<void> futureOr(FutureOr<int> d) async { await d; }
Future<void> object(Object? d) async { await d; }
Future<void> twice(Ticker t, int i) async { await t; await i; await t; }
Future<void> none() async {}
void main() {}
''';

List<Map<String, Object?>> _then(Component c, TypeEnvironment env, String n) {
  for (final lib in c.libraries) {
    if (!lib.importUri.toString().endsWith('app.dart')) continue;
    for (final p in lib.procedures) {
      if (p.name.text != n) continue;
      return [
        for (final r in externalReferencesOf(p, {}, types: env))
          if (r['member'] == 'then') r,
      ];
    }
  }
  throw StateError('no $n');
}

void main() {
  final host = Platform.environment['HOST_DART'];
  if (host == null) {
    stderr.writeln('set HOST_DART to the host dart, see the header');
    exit(2);
  }
  final dir = Directory.systemTemp.createTempSync('await_refs_test');
  try {
    File(
      '${dir.path}/app.dart',
    ).writeAsStringSync("import 'dart:async';\n$_source");
    final r = Process.runSync(host, [
      'compile',
      'kernel',
      '${dir.path}/app.dart',
      '-o',
      '${dir.path}/app.dill',
    ]);
    if (r.exitCode != 0) {
      stderr.writeln(r.stderr);
      exit(2);
    }
    final c = Component();
    BinaryBuilder(
      File('${dir.path}/app.dill').readAsBytesSync(),
    ).readComponent(c);
    final core = CoreTypes(c);
    final env = TypeEnvironment(core, ClassHierarchy(c, core));

    check(analysisVersion == 24, 'analysis version is 24');

    final t = _then(c, env, 'ticker');
    check(
      t.length == 1 &&
          t.single['library'] == 'dart:async' &&
          t.single['class'] == 'Future' &&
          t.single['receiverClass'] == 'Ticker',
      'await on a Future subtype names it as the receiver',
    );
    final p = _then(c, env, 'plain');
    check(
      p.length == 1 && !p.single.containsKey('receiverClass'),
      'await on a Future<int> is Future.then with no narrower receiver',
    );
    check(
      _then(c, env, 'nullable').length == 1,
      'await on a nullable Future is Future.then',
    );
    check(_then(c, env, 'nonFuture').isEmpty, 'await on an int reports nothing');
    check(
      _then(c, env, 'dyn').length == 1 &&
          !_then(c, env, 'dyn').single.containsKey('receiverClass'),
      'await on dynamic is Future.then, unnarrowed',
    );
    check(
      _then(c, env, 'futureOr').length == 1,
      'await on a FutureOr is Future.then',
    );
    check(
      _then(c, env, 'object').length == 1,
      'await on Object? is Future.then',
    );
    check(
      _then(c, env, 'twice').length == 1,
      'two awaits on one receiver class are one entry',
    );
    check(_then(c, env, 'none').isEmpty, 'no await, no entry');
  } finally {
    dir.deleteSync(recursive: true);
  }
  if (_failures > 0) exit(1);
  stdout.writeln('all passed');
}
