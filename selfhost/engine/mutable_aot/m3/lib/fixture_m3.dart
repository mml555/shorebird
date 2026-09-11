// The canonical #67 release program. Compiled once, into the release; every
// call below is a call site the release compiler emitted, and none of them is
// recompiled after installation.
import 'dart:ffi';
import 'dart:io' show Platform;

// ---- the declarations under replacement ---------------------------------
@pragma('maot:mutable')
String work() => 'OLD';

class StaticTarget {
  @pragma('maot:mutable')
  static String work() => 'OLD-STATIC';
}

// Replacement implementations. For #67 the chosen replacement form is another
// AOT-compiled Dart implementation present in the release image, selected by
// descriptor; delivering an externally-built body is #72/#77.
@pragma('maot:mutable')
String workNew() => 'NEW';
@pragma('maot:mutable')
String workNew2() => 'NEW2';
@pragma('maot:mutable')
String staticNew() => 'NEW-STATIC';
@pragma('maot:mutable')
String staticNew2() => 'NEW2-STATIC';

// Selected but never replaced: installation must be scoped to one declaration.
@pragma('maot:mutable')
String untouchedMutable() => 'UNTOUCHED';

// Not selected at all: must be unaffected and must have no descriptor.
String notMutable() => 'PLAIN';

// A declaration whose ABI differs, for the refusal arm.
@pragma('maot:mutable')
String wrongAbi(int a, int b) => 'WRONG-ABI';

const _lib = 'lib:package:m3app/fixture_m3.dart';
const _top = '$_lib::fn:work';
const _static = '$_lib::cls:StaticTarget::method:work';

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

Pointer<Uint8> _c(String s) {
  final u = s.codeUnits;
  final p = _malloc(u.length + 1);
  for (var i = 0; i < u.length; i++) {
    p[i] = u[i];
  }
  p[u.length] = 0;
  return p;
}

/// kind+version as one number: positive is AOT, -(version)-100 is PATCH_CODE.
String _v(String id) {
  final raw = _version(_c(id));
  if (raw == -1) return 'absent';
  return raw >= 0 ? 'AOT:v$raw' : 'PATCH_CODE:v${-(raw + 100)}';
}

int _pid = 0;

void _emit(String k, Object v) => print('$k=$v');

void main(List<String> args) {
  final ns = Platform.environment['MAOT_NAMESPACE'] ?? '';
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _pid = pid;
  _emit('process.pid', _pid);

  // ---- before any installation ----
  _emit('top.call.0', work());
  _emit('static.call.0', StaticTarget.work());
  _emit('untouched.call.0', untouchedMutable());
  _emit('plain.call.0', notMutable());
  _emit('top.version.0', _v(_top));
  _emit('static.version.0', _v(_static));
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));

  // ---- refusals, before any visible mutation ----
  _emit('refuse.unknown.id',
      _install(_c('$_lib::fn:doesNotExist'), _c('$_lib::fn:workNew'), 2,
          _c(ns)));
  _emit('refuse.wrong.namespace',
      _install(_c(_top), _c('$_lib::fn:workNew'), 2,
          _c('0000000000000000000000000000000000000000000000000000000000000000')));
  _emit('refuse.abi.mismatch',
      _install(_c(_top), _c('$_lib::fn:wrongAbi'), 2, _c(ns)));
  _emit('refuse.version.not.advancing',
      _install(_c(_top), _c('$_lib::fn:workNew'), 1, _c(ns)));
  // Nothing above may have changed anything.
  _emit('top.call.after_refusals', work());
  _emit('top.version.after_refusals', _v(_top));

  // ---- top-level arm: OLD -> NEW -> NEW2 ----
  _emit('install.top.v2', _install(_c(_top), _c('$_lib::fn:workNew'), 2, _c(ns)));
  _emit('top.call.1', work());
  _emit('top.call.1.repeat', work());
  _emit('top.version.1', _v(_top));
  _emit('static.call.after_top_install', StaticTarget.work());
  _emit('untouched.call.after_top_install', untouchedMutable());

  _emit('install.top.v3',
      _install(_c(_top), _c('$_lib::fn:workNew2'), 3, _c(ns)));
  _emit('top.call.2', work());
  _emit('top.version.2', _v(_top));

  // ---- static arm: independent of the top-level arm ----
  _emit('install.static.v2',
      _install(_c(_static), _c('$_lib::fn:staticNew'), 2, _c(ns)));
  _emit('static.call.1', StaticTarget.work());
  _emit('static.call.1.repeat', StaticTarget.work());
  _emit('static.version.1', _v(_static));

  _emit('install.static.v3',
      _install(_c(_static), _c('$_lib::fn:staticNew2'), 3, _c(ns)));
  _emit('static.call.2', StaticTarget.work());
  _emit('static.version.2', _v(_static));

  // ---- scope and identity, at the end ----
  _emit('untouched.call.final', untouchedMutable());
  _emit('plain.call.final', notMutable());
  _emit('top.call.final', work());
  _emit('process.pid.final', pid);
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_after.json'));
}

int get pid => Platform.environment.length >= 0 ? _realPid() : 0;

int _realPid() => _pidFn();

final _pidFn = _proc.lookupFunction<Int32 Function(), int Function()>('getpid');
