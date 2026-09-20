// Gate C / Gate D / compact production replacement regression.
//
// Three replaceable subjects, one never-replaced CALLER, and one control.
//
//   topLevel      a top-level function        -> static call, #67 lowering
//   Inst.v        an instance method, no subclass and no interface, so the
//                 optimizer devirtualizes the call -> static call, #67 lowering
//   ShareA.v /    two declarations whose bodies are written identically. If
//   ShareB.v      the serializer's Dedup canonicalizes them onto ONE Code,
//                 replacing A must leave B alone -- that is the shared-body
//                 case, and whether it arises at all is measured rather than
//                 assumed.
//
// Caller.all is ITSELF a mutable declaration, and is never installed. That is
// not decoration: a mutable declaration's Function::CurrentCode is its
// trampoline, so the only way to read the machine code that HOLDS the call
// sites is through the registry's pinned body -- which is what
// Dart_MaotBodyWordsForTesting reads. A non-mutable caller has no registry
// entry and therefore no way to be found by name at run time.
import 'dart:ffi';
import 'dart:io' show Platform;

final int input = int.tryParse(Platform.environment['M5_INPUT'] ?? '') ?? 10;

@pragma('maot:mutable')
String topLevel(int x) => 'OLD:${x * 2}';
@pragma('maot:mutable')
String topLevelNew(int x) => 'NEW:${x * 3}';
@pragma('maot:mutable')
String topLevelNew2(int x) => 'NEW2:${x + 7}';

class Inst {
  @pragma('maot:mutable')
  String v(int x) => 'OLD:${x * 2}';
}
class InstNew {
  @pragma('maot:mutable')
  String v(int x) => 'NEW:${x * 3}';
}
class InstNew2 {
  @pragma('maot:mutable')
  String v(int x) => 'NEW2:${x + 7}';
}

class ShareA {
  @pragma('maot:mutable')
  String v(int x) => 'SHARED:${x * 4}';
}
class ShareB {
  @pragma('maot:mutable')
  String v(int x) => 'SHARED:${x * 4}';
}
class ShareANew {
  @pragma('maot:mutable')
  String v(int x) => 'NEW:${x * 3}';
}
class ShareANew2 {
  @pragma('maot:mutable')
  String v(int x) => 'NEW2:${x + 7}';
}

// The cross-wiring control: a mutable declaration sharing the selector that
// must be untouched by every install.
class Other {
  @pragma('maot:mutable')
  String v(int x) => 'OTHERDECL:${x * 5}';
}

class Caller {
  // Mutable so its pinned body is readable; never installed.
  @pragma('maot:mutable')
  @pragma('vm:never-inline')
  String all(Inst i, ShareA a, ShareB b, Other o, int x) =>
      '${topLevel(x)}|${i.v(x)}|${a.v(x)}|${b.v(x)}|${o.v(x)}';
}

@pragma('vm:never-inline')
String siteTop(int x) => topLevel(x);
@pragma('vm:never-inline')
String siteInst(Inst i, int x) => i.v(x);
@pragma('vm:never-inline')
String siteShareA(ShareA a, int x) => a.v(x);
@pragma('vm:never-inline')
String siteShareB(ShareB b, int x) => b.v(x);
@pragma('vm:never-inline')
String siteOther(Other o, int x) => o.v(x);

const _lib = 'lib:package:m5gatec/fixture_m5_gatec.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _install = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>, Int64, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>, int,
        Pointer<Uint8>)>('Dart_MaotInstallForTesting');
final _version = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotCurrentVersionForTesting');
final _dump = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotDumpForTesting');
final _words = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>(
    'Dart_MaotBodyWordsForTesting');
final _poolOff = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotCellPoolOffsetForTesting');

Pointer<Uint8> _c(String s) {
  final u = s.codeUnits;
  final p = _malloc(u.length + 1);
  for (var i = 0; i < u.length; i++) {
    p[i] = u[i];
  }
  p[u.length] = 0;
  return p;
}

void _emit(String k, Object v) => print('$k=$v');
final _ns = Platform.environment['MAOT_NAMESPACE'] ?? '';
int _stage(String decl, String impl, int v) =>
    _install(_c('$_lib::$decl'), _c('$_lib::$impl'), v, _c(_ns));
int _ver(String decl) => _version(_c('$_lib::$decl'));

const _caller = 'cls:Caller::method:all';
const _subjects = <String, List<String>>{
  // key: [declaration, v2 implementation, v3 implementation]
  'top': ['fn:topLevel', 'fn:topLevelNew', 'fn:topLevelNew2'],
  'inst': ['cls:Inst::method:v', 'cls:InstNew::method:v',
           'cls:InstNew2::method:v'],
  'sharea': ['cls:ShareA::method:v', 'cls:ShareANew::method:v',
             'cls:ShareANew2::method:v'],
};

final _inst = Inst();
final _a = ShareA();
final _b = ShareB();
final _other = Other();

void _observe(String stage) {
  _emit('top.$stage', siteTop(input));
  _emit('inst.$stage', siteInst(_inst, input));
  _emit('sharea.$stage', siteShareA(_a, input));
  _emit('shareb.$stage', siteShareB(_b, input));
  _emit('other.$stage', siteOther(_other, input));
}

void _snapshot(String stage, String dumpDir) {
  for (final k in _subjects.keys) {
    _emit('version.$k.$stage', _ver(_subjects[k]![0]));
  }
  _emit('caller.digest.$stage',
      _words(_c('$_lib::$_caller'),
          _c(dumpDir.isEmpty ? '' : '$dumpDir/caller_$stage.words')));
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_$stage.json'));
}

void main() {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('input', input);
  // Retain every replacement body and the caller.
  _emit('retain', [
    topLevelNew(input), topLevelNew2(input),
    InstNew().v(input), InstNew2().v(input),
    ShareANew().v(input), ShareANew2().v(input),
    Caller().all(_inst, _a, _b, _other, input),
  ].join('|'));

  for (var i = 0; i < 50000; i++) {
    siteTop(input);
    siteInst(_inst, input);
    siteShareA(_a, input);
    siteShareB(_b, input);
    siteOther(_other, input);
  }

  // Which pool slot each declaration's cell occupies, so a decoded
  // `ldr xN,[PP,#off]` names a declaration instead of "some cell".
  _emit('pool.caller', _poolOff(_c('$_lib::$_caller')));
  for (final k in _subjects.keys) {
    _emit('pool.$k', _poolOff(_c('$_lib::${_subjects[k]![0]}')));
  }
  _emit('pool.shareb', _poolOff(_c('$_lib::cls:ShareB::method:v')));
  _emit('pool.other', _poolOff(_c('$_lib::cls:Other::method:v')));

  _observe('before');
  _snapshot('before', dumpDir);

  for (final k in _subjects.keys) {
    _emit('install.$k.v2', _stage(_subjects[k]![0], _subjects[k]![1], 2));
  }
  _observe('v2');
  _snapshot('v2', dumpDir);

  for (final k in _subjects.keys) {
    _emit('install.$k.v3', _stage(_subjects[k]![0], _subjects[k]![2], 3));
  }
  _observe('v3');
  _snapshot('v3', dumpDir);
}
