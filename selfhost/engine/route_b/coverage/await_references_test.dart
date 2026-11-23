// Tests for the analysis version 24 report of an `await` as a call of
// `Future.then` (`visitAwaitExpression`). Compiles `_source` with the host
// Dart, then reads the kernel back with a real type environment. It needs the
// engine's Dart, so CI does not run it.
//
//   SRC=$HOME/shorebird-engine/flutter/engine/src
//   HOST_DART=$SRC/out/host_release_arm64/dart-sdk/bin/dart \
//   $SRC/out/host_release_arm64_ddm/dart-sdk/bin/dart \
//     --packages=$SRC/flutter/third_party/dart/.dart_tool/package_config.json \
//     selfhost/engine/route_b/coverage/await_references_test.dart
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
abstract class Pingable {}
abstract class Slow implements Pingable, Future<void> {}
class Box<T extends Future<int>> { Future<void> f(T t) async { await t; } }
extension type Wrapped(Future<int> f) implements Future<int> {}
Future<void> ticker(Ticker t) async { await t; }
Future<void> plain(Future<int> f) async { await f; }
Future<void> nullable(Future<int>? f) async { await f; }
Future<void> nonFuture() async { await 1; await 'a'; await (1, 2); }
Future<void> dyn(dynamic d) async { await d; }
Future<void> futureOr(FutureOr<int> d) async { await d; }
Future<void> object(Object? d) async { await d; }
Future<void> iface(Pingable p) async { await p; }
Future<void> twice(Ticker t, int i) async { await t; await i; await t; }
Future<void> none() async {}
Stream<int> gen(Ticker t) async* { await t; }
Future<void> closure(Ticker t) async { final f = () async { await t; }; }
Future<void> local(Ticker t) async { Future<void> g() async { await t; } }
Future<void> awaitFor(Stream<int> s) async { await for (final x in s) {} }
Future<void> ext(Wrapped w) async { await w.f; await w; }
Future<int> ret(Ticker t) async { return t; }
Future<int> retInt() async { return 1; }
Future<int> retSync(Ticker t) { return t; }
Stream<int> retGen(Ticker t) async* { yield 1; return; }
Future<int> retClosure(Ticker t) async { final f = () { return t; }; return 1; }
void completer(Ticker t) { Completer<int>().complete(t); }
void value(Ticker t) { Future<int>.value(t); }
void wait(Ticker t) { Future.wait([t]); Future.any([t]); }
void stream(Ticker t) { Stream.fromFuture(t); t.asStream(); }
void unrelated() { Completer<int>().complete(1); Future<int>.value(1); }
void main() {}
''';

List<Map<String, Object?>> _then(Component c, TypeEnvironment env, String n) {
  for (final lib in c.libraries) {
    if (!lib.importUri.toString().endsWith('app.dart')) continue;
    for (final p in [
      ...lib.procedures,
      for (final cls in lib.classes) ...cls.procedures,
    ]) {
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

    List<Map<String, Object?>> then(String n) => _then(c, env, n);
    bool narrowed(String n, String cls) =>
        then(n).length == 1 && then(n).single['receiverClass'] == cls;
    bool unnarrowed(String n) =>
        then(n).length == 1 && !then(n).single.containsKey('receiverClass');
    bool nothing(String n) => then(n).isEmpty;

    check(narrowed('ticker', 'Ticker'), 'await on a Future subtype names it');
    check(unnarrowed('plain'), 'await on a Future<int> is unnarrowed');
    check(unnarrowed('nullable'), 'await on a nullable Future is unnarrowed');
    check(nothing('nonFuture'), 'await on an int, a String, a record: nothing');
    check(unnarrowed('dyn'), 'await on dynamic is unnarrowed');
    check(unnarrowed('futureOr'), 'await on a FutureOr is unnarrowed');
    check(unnarrowed('object'), 'await on Object? is unnarrowed');
    check(
      unnarrowed('iface'),
      'await on an interface a Future could implement is unnarrowed (Slow)',
    );
    check(narrowed('twice', 'Ticker'), 'repeated awaits are one entry');
    check(nothing('none'), 'no await, no entry');
    check(narrowed('gen', 'Ticker'), 'an await in an async* body');
    check(narrowed('closure', 'Ticker'), 'an await in a closure');
    check(narrowed('local', 'Ticker'), 'an await in a local function');
    check(nothing('awaitFor'), 'await for reports no then');
    check(unnarrowed('ext'), 'await on an extension type implementing Future');
    check(
      narrowed('ret', 'Ticker'),
      'return of a Future subtype from an async body',
    );
    check(nothing('retInt'), 'return of an int from an async body');
    check(nothing('retSync'), 'return from a non-async body is not a chain');
    check(nothing('retGen'), 'return in an async* body is not a chain');
    check(nothing('retClosure'), 'a closure that is not async does not chain');
    check(narrowed('completer', 'Ticker'), 'Completer.complete(future)');
    check(narrowed('value', 'Ticker'), 'Future.value(future)');
    check(unnarrowed('wait'), 'Future.wait and Future.any are unnarrowed');
    check(narrowed('stream', 'Ticker'), 'Stream.fromFuture and asStream');
    check(nothing('unrelated'), 'Completer.complete(1), Future.value(1)');
    final boxMember = then('f');
    check(
      boxMember.length == 1 && !boxMember.single.containsKey('receiverClass'),
      'await on a T extends Future<int> is Future.then',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
  if (_failures > 0) exit(1);
  stdout.writeln('all passed');
}
