// R2 iOS/Android production replacement smoke.
//
// Runs the same sequence the host gate runs, through production
// StageReplacement, on a real device:
//
//     OLD  ->  install V2  ->  NEW  ->  install V3  ->  NEW2
//
// plus one fail-closed negative control: an implementation whose calling
// convention differs must be REFUSED, not silently installed.
//
// Everything is printed with a stable prefix so it can be recovered from the
// device log. Nothing here uses Dart_MaotDiagnosticCellSwap; the whole point
// is that the production transaction is what moves the cell.
import 'dart:ffi';
import 'dart:io' show Directory, File, FileMode, Platform;

import 'package:flutter/material.dart';

class Hot {
  @pragma('maot:mutable')
  @pragma('vm:never-inline')
  String v(int x) => 'OLD:${x * 2}';
}

class HotNew {
  @pragma('maot:mutable')
  @pragma('vm:never-inline')
  String v(int x) => 'NEW:${x * 3}';
}

class HotNew2 {
  @pragma('maot:mutable')
  @pragma('vm:never-inline')
  String v(int x) => 'NEW2:${x + 7}';
}

// The negative control. Same selector, different arity, so the calling
// convention descriptor differs and StageReplacement must refuse.
class BadArity {
  @pragma('maot:mutable')
  @pragma('vm:never-inline')
  String v(int x, int y) => 'BAD:${x + y}';
}

// Cross-wiring control: must be untouched by every install.
class Other {
  @pragma('maot:mutable')
  @pragma('vm:never-inline')
  String v(int x) => 'OTHER:${x * 5}';
}

@pragma('vm:never-inline')
String siteHot(Hot h, int x) => h.v(x);
@pragma('vm:never-inline')
String siteOther(Other o, int x) => o.v(x);

const _lib = 'lib:package:maot_smoke/main.dart';
const _decl = 'cls:Hot::method:v';

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
final _tramp = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotTrampolineIdentityForTesting');

Pointer<Uint8> _c(String s) {
  final u = s.codeUnits;
  final p = _malloc(u.length + 1);
  for (var i = 0; i < u.length; i++) {
    p[i] = u[i];
  }
  p[u.length] = 0;
  return p;
}

final _out = <String>[];

// There is no console on a device: print() does not reach lldb or the syslog
// from a Flutter release build. So the trace is APPENDED to a file from the
// very first statement, and every step is flushed immediately. If the run dies
// part way -- for instance because an FFI lookup fails, which is a lazy final
// and therefore throws at first use -- the file still says how far it got.
String _tracePath = '';
void _initTrace() {
  for (final d in <String>[
    Platform.environment['HOME'] ?? '',
    () {
      try {
        return Directory.systemTemp.parent.path;
      } catch (_) {
        return '';
      }
    }(),
  ]) {
    if (d.isEmpty) continue;
    // Library/Caches first: --download has already been observed to retrieve
    // flutter_callback_cache.json from there, so it is proven readable.
    for (final sub in <String>['/Library/Caches', '/Documents', '/tmp', '']) {
      try {
        final f = File('$d$sub/maot_r2.txt');
        f.writeAsStringSync('MAOTR2 tracefile=$d$sub\n');
        _tracePath = f.path;
        return;
      } catch (_) {}
    }
  }
  try {
    final f = File('${Directory.systemTemp.path}/maot_r2.txt');
    f.writeAsStringSync('MAOTR2 tracefile=systemTemp\n');
    _tracePath = f.path;
  } catch (_) {}
}

void _emit(String k, Object v) {
  final line = 'MAOTR2 $k=$v';
  _out.add(line);
  if (_tracePath.isNotEmpty) {
    try {
      File(_tracePath).writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }
  // ignore: avoid_print
  print(line);
}

// The namespace the snapshot was built with. On a device there is no
// environment to read it from, and StageReplacement's namespace check exists
// precisely to refuse an install that does not name it, so it is compiled in.
const _nsConst =
    'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e';
final _envNs = Platform.environment['MAOT_NAMESPACE'] ?? '';
final _ns = _envNs.isNotEmpty ? _envNs : _nsConst;
int _stage(String impl, int v) =>
    _install(_c('$_lib::$_decl'), _c('$_lib::$impl'), v, _c(_ns));

String runSmoke() {
  _out.clear();
  _initTrace();
  _emit('trace.started', 1);
  _emit('ffi.process', 1);
  try {
    _emit('ffi.malloc', _malloc.hashCode != 0);
    _emit('ffi.install', _install.hashCode != 0);
    _emit('ffi.version', _version.hashCode != 0);
    _emit('ffi.dump', _dump.hashCode != 0);
    _emit('ffi.tramp', _tramp.hashCode != 0);
  } catch (e) {
    _emit('ffi.lookup.FAILED', e);
    rethrow;
  }
  final h = Hot();
  final o = Other();
  _emit('platform', Platform.operatingSystem);
  _emit('version', Platform.operatingSystemVersion);
  _emit('namespace.len', _ns.length);

  // Keep every replacement body reachable.
  _emit('retain',
      '${HotNew().v(1)}|${HotNew2().v(1)}|${BadArity().v(1, 2)}');

  for (var i = 0; i < 20000; i++) {
    siteHot(h, 10);
    siteOther(o, 10);
  }

  // On a device there is no console to read, so the report and the registry
  // dumps are written into the app container and pulled off afterwards.
  //
  // Platform.environment['HOME'] is EMPTY in a Flutter app on iOS, which is
  // why the first attempt wrote nothing at all. Directory.systemTemp is the
  // container's tmp/, and Documents/ is its sibling -- that is the directory
  // `ios-deploy --download=/Documents` retrieves.
  final dumpDir = _tracePath.isEmpty
      ? ''
      : _tracePath.substring(0, _tracePath.lastIndexOf('/'));
  void snap(String stage) {
    _emit('hot.$stage', siteHot(h, 10));
    _emit('other.$stage', siteOther(o, 10));
    _emit('version.$stage', _version(_c('$_lib::$_decl')));
    _emit('trampoline.$stage', _tramp(_c('$_lib::$_decl')));
    if (dumpDir.isNotEmpty) {
      _dump(_c('$dumpDir/registry_$stage.json'));
    }
  }

  snap('before');

  // Negative control FIRST, so a later success cannot be confused with it.
  _emit('negative.badarity.install', _stage('cls:BadArity::method:v', 2));
  _emit('negative.hot.after', siteHot(h, 10));
  _emit('negative.version.after', _version(_c('$_lib::$_decl')));

  _emit('install.v2', _stage('cls:HotNew::method:v', 2));
  snap('v2');
  _emit('install.v3', _stage('cls:HotNew2::method:v', 3));
  snap('v3');
  _emit('done', 1);
  return _out.join('\n');
}

String _report = '<not run>';

void main() {
  // Run BEFORE runApp. On the device the app was being killed with SIGKILL
  // before a first frame, so anything done inside build() never happened.
  // Doing the work here means the trace file is complete even if no UI is
  // ever shown.
  try {
    _report = runSmoke();
  } catch (e, st) {
    _report = 'error=$e\n$st';
    if (_tracePath.isNotEmpty) {
      try {
        File(_tracePath)
            .writeAsStringSync('MAOTR2 fatal=$e\n', mode: FileMode.append);
      } catch (_) {}
    }
  }
  runApp(const SmokeApp());
}

class SmokeApp extends StatelessWidget {
  const SmokeApp({super.key});
  @override
  Widget build(BuildContext context) {
    final report = _report;
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(report, style: const TextStyle(fontSize: 11)),
          ),
        ),
      ),
    );
  }
}
