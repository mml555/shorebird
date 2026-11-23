// Tests for the analysis version 24 report of an `await` as a call of
// `Future.then` (`visitAwaitExpression`). Compiles `_source` with the host
// Dart, then reads the kernel back with a real type environment. It needs the
// engine's Dart (the `ddm` one below, which cannot compile kernel itself), and
// a standalone Dart as HOST_DART to compile with. CI does not run it.
//
//   SRC=$HOME/shorebird-engine/flutter/engine/src
//   HOST_DART=$(which dart) \
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
mixin Mix {}
abstract class MixSlow extends Object with Mix implements Future<void> {}
abstract class Grand {}
abstract class Parent extends Grand {}
abstract class Leaf extends Parent implements Future<void> {}
abstract class Gen<T> {}
abstract class GenSlow implements Gen<int>, Future<void> {}
abstract class CmpSlow implements Comparable<int>, Future<void> {}
abstract class ForeignSlow implements Foreign, Future<void> {}
class Model {}
Future<Model> retModel() async { return Model(); }
Future<void> awaitModel(Model m) async { await m; }
Future<void> waits(Ticker t) async { await [t, t].wait; }
Future<void> waitsRecord(Ticker t) async { await (t, t).wait; }
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
Future<void> viaMix(Mix m) async { await m; }
Future<void> viaChain(Grand g) async { await g; }
Future<void> viaParent(Parent g) async { await g; }
Future<void> nullableIface(Pingable? p) async { await p; }
Future<void> nullableModel(Model? m) async { await m; }
Future<void> generic(Gen<int> g) async { await g; }
Future<void> genericOther(Gen<String> g) async { await g; }
Future<void> sdkIface(Comparable<int> c) async { await c; }
Future<void> sdkNone(Iterable<Model> i) async { await i; }
Future<void> foreign(Foreign f) async { await f; }
void ign(Ticker t) { t.ignore(); }
void ignPlain(Future<int> f) { f.ignore(); }
void tearIgn(Ticker t) { final f = t.ignore; f(); }
void tearErr(Ticker t) { final f = t.onError<Object>; f((e, s) => 1); }
void onErr(Ticker t) { t.onError<Object>((e, s) => 1); }
void main() {}
''';

const _other = '''
abstract class Foreign {}
''';

/// The release: `Gone` is a Future the patch no longer has.
const _baseSource = '''
abstract class Pingable {}
abstract class Gone implements Pingable, Future<void> {}
Future<void> iface(Pingable p) async { await p; }
void main() {}
''';

/// The patch: the same body, `Gone` deleted.
const _patchedSource = '''
abstract class Pingable {}
Future<void> iface(Pingable p) async { await p; }
abstract class Fresh {}
abstract class FreshSlow implements Fresh, Future<void> {}
Future<void> fresh(Fresh f) async { await f; }
void main() {}
''';

List<Map<String, Object?>> _then(
  Component c,
  TypeEnvironment env,
  String n, {
  FutureWorld? world,
}) {
  for (final lib in c.libraries) {
    if (!lib.importUri.toString().endsWith('app.dart')) continue;
    for (final p in [
      ...lib.procedures,
      for (final cls in lib.classes) ...cls.procedures,
    ]) {
      if (p.name.text != n) continue;
      return [
        for (final r in externalReferencesOf(p, {}, types: env, world: world))
          if (r['member'] == 'then') r,
      ];
    }
  }
  throw StateError('no $n');
}

Component _compile(String host, Directory dir, String name, String source) {
  // Always `app.dart`, so the release and the patch hold the same library URI.
  File(
    '${dir.path}/app.dart',
  ).writeAsStringSync("import 'dart:async';\nimport 'other.dart';\n$source");
  final r = Process.runSync(host, [
    'compile',
    'kernel',
    '${dir.path}/app.dart',
    '-o',
    '${dir.path}/$name.dill',
  ]);
  if (r.exitCode != 0) {
    stderr.writeln(r.stderr);
    exit(2);
  }
  final c = Component();
  BinaryBuilder(
    File('${dir.path}/$name.dill').readAsBytesSync(),
  ).readComponent(c);
  return c;
}

void main() {
  final host = Platform.environment['HOST_DART'];
  if (host == null) {
    stderr.writeln('set HOST_DART to the host dart, see the header');
    exit(2);
  }
  final dir = Directory.systemTemp.createTempSync('await_refs_test');
  try {
    File('${dir.path}/other.dart').writeAsStringSync(_other);
    final c = _compile(host, dir, 'app', _source);
    final core = CoreTypes(c);
    final env = TypeEnvironment(core, ClassHierarchy(c, core));

    check(analysisVersion == 24, 'analysis version is 24');

    List<Map<String, Object?>> then(String n) =>
        _then(c, env, n, world: FutureWorld(env));
    bool narrowed(String n, String cls) =>
        then(n).length == 1 && then(n).single['receiverClass'] == cls;
    bool unnarrowed(String n) =>
        then(n).length == 1 && !then(n).single.containsKey('receiverClass');
    bool nothing(String n) => then(n).isEmpty;
    // Exactly these receiver classes, no other entry.
    // The duplicate check is the `toSet()` clause: equal length and every
    // class in the set would also pass for the same class listed twice.
    bool exactly(String n, Set<String> classes) {
      final entries = then(n);
      return entries.length == classes.length &&
          entries.every((e) => classes.contains(e['receiverClass'])) &&
          entries.map((e) => e['receiverClass']).toSet().length ==
              classes.length;
    }

    check(narrowed('ticker', 'Ticker'), 'await on a Future subtype names it');
    check(unnarrowed('plain'), 'await on a Future<int> is unnarrowed');
    check(unnarrowed('nullable'), 'await on a nullable Future is unnarrowed');
    check(nothing('nonFuture'), 'await on an int, a String, a record: nothing');
    check(unnarrowed('dyn'), 'await on dynamic is unnarrowed');
    check(unnarrowed('futureOr'), 'await on a FutureOr is unnarrowed');
    check(unnarrowed('object'), 'await on Object? is unnarrowed');
    check(
      narrowed('iface', 'Slow'),
      'await on an interface some Future subtype implements names that class',
    );
    check(nothing('retModel'), 'return of a Model reports nothing');
    check(nothing('awaitModel'), 'await on a Model reports nothing');
    check(
      unnarrowed('waits') && unnarrowed('waitsRecord'),
      '[a, b].wait and (a, b).wait are Future.then',
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
    check(exactly('iface', {'Slow'}), 'an interface: exactly [Slow]');
    check(exactly('viaMix', {'MixSlow'}), 'a mixin application subtype');
    check(
      exactly('viaChain', {'Leaf'}),
      'an extends chain, from the grandparent',
    );
    check(exactly('viaParent', {'Leaf'}), 'an extends chain, from the parent');
    check(
      exactly('nullableIface', {'Slow'}),
      'a nullable interface names Slow',
    );
    check(nothing('nullableModel'), 'a nullable Model reports nothing');
    check(exactly('generic', {'GenSlow'}), 'a generic instantiation');
    check(
      exactly('genericOther', {'GenSlow'}),
      'Gen<String> is asked like Gen<int>: the class decides',
    );
    check(
      exactly('sdkIface', {'CmpSlow'}),
      'an SDK interface, Comparable<int>',
    );
    check(nothing('sdkNone'), 'an SDK interface no Future implements');
    check(
      exactly('foreign', {'ForeignSlow'}),
      'an interface of another library',
    );
    check(exactly('ign', {'Ticker'}), 'Future.ignore() names the receiver');
    check(unnarrowed('ignPlain'), 'Future<int>.ignore() is unnarrowed');
    check(exactly('onErr', {'Ticker'}), 'Future.onError() names the receiver');
    check(exactly('tearIgn', {'Ticker'}), 'a tear-off of ignore names it');
    check(exactly('tearErr', {'Ticker'}), 'a tear-off of onError names it');
    check(
      _then(c, env, 'iface').length == 1 &&
          !_then(c, env, 'iface').single.containsKey('receiverClass'),
      'no world: an interface is not narrowed',
    );

    // The release's classes count: `Gone` is only in the base.
    final base = _compile(host, dir, 'base', _baseSource);
    final patched = _compile(host, dir, 'patched', _patchedSource);
    final pCore = CoreTypes(patched);
    final pEnv = TypeEnvironment(pCore, ClassHierarchy(patched, pCore));
    List<Map<String, Object?>> ifaceWith(FutureWorld w) =>
        _then(patched, pEnv, 'iface', world: w);
    check(
      ifaceWith(FutureWorld(pEnv)).isEmpty,
      'patched component alone: a deleted Future subtype is invisible',
    );
    // The same construction the analyzer's main uses.
    final withBase = ifaceWith(futureWorldFor(pEnv, base));
    check(
      withBase.length == 1 && withBase.single['receiverClass'] == 'Gone',
      'a Future subtype only in the release is named: exactly [Gone]',
    );
    // A kernel without its platform: dart:core names no classes.
    final unlinkedBase = _compile(host, dir, 'base', _baseSource);
    unlinkedBase.libraries
        .firstWhere((l) => l.importUri.toString() == 'dart:core')
        .classes
        .clear();
    check(
      !componentIsLinked(unlinkedBase),
      'a platformless kernel is unlinked',
    );
    final unlinked = ifaceWith(futureWorldFor(pEnv, unlinkedBase));
    check(
      unlinked.length == 1 && !unlinked.single.containsKey('receiverClass'),
      'a release kernel that cannot be asked leaves the entry unnarrowed',
    );
    // A class the patch adds has no release counterpart: patched subtypes only.
    final fresh = _then(
      patched,
      pEnv,
      'fresh',
      world: futureWorldFor(pEnv, base),
    );
    check(
      fresh.length == 1 && fresh.single['receiverClass'] == 'FreshSlow',
      'a class only the patch has is asked of the patched component: [FreshSlow]',
    );
    // The same class name under another library URI is not new: the release's
    // subtypes cannot be found, so the entry is not narrowed.
    final moved = _compile(host, dir, 'base', _baseSource);
    moved.libraries
        .firstWhere((l) => l.importUri.toString().endsWith('app.dart'))
        .importUri = Uri.parse(
      'file:///moved/app.dart',
    );
    final missed = ifaceWith(futureWorldFor(pEnv, moved));
    check(
      missed.length == 1 && !missed.single.containsKey('receiverClass'),
      'a class whose library URI moved is not narrowed',
    );
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
