// MAOT-5 (#69) Task A -- dispatch matrix for the `setter` subject.
//
// One declaration per FINAL AOT ROUTE, established by the lowering survey:
// direct -> static call, virtual/interface -> dispatch table, super -> inline
// #67 cell indirection. The forms need separate declarations because they are
// mutually exclusive on one class.
//
// `Other` is the cross-wiring control: a mutable declaration sharing the
// selector that must be untouched by any install.
import 'dart:ffi';
import 'dart:io' show Platform;

final int input = int.tryParse(Platform.environment['M5_INPUT'] ?? '') ?? 10;
String marker = '<unset>';

abstract class Iface {
  set v(int x);
}

class Direct { @pragma('maot:mutable') set v(int x) { marker = 'OLD:${x * 2}'; } }
class DirectNew { @pragma('maot:mutable') set v(int x) { marker = 'NEW:${x * 3}'; } }
class DirectNew2 { @pragma('maot:mutable') set v(int x) { marker = 'NEW2:${x * 7}'; } }

class Virt { @pragma('maot:mutable') set v(int x) { marker = 'OLD:${x * 2}'; } }
class VirtSub extends Virt { @override set v(int x) {{ marker = 'SUB'; }} }
class VirtNew { @pragma('maot:mutable') set v(int x) { marker = 'NEW:${x * 3}'; } }
class VirtNew2 { @pragma('maot:mutable') set v(int x) { marker = 'NEW2:${x * 7}'; } }

class Ifc implements Iface { @pragma('maot:mutable') @override set v(int x) { marker = 'OLD:${x * 2}'; } }
class IfcOther implements Iface { @override set v(int x) {{ marker = 'OTHER'; }} }
class IfcNew { @pragma('maot:mutable') set v(int x) { marker = 'NEW:${x * 3}'; } }
class IfcNew2 { @pragma('maot:mutable') set v(int x) { marker = 'NEW2:${x * 7}'; } }

class SuperBase { @pragma('maot:mutable') set v(int x) { marker = 'OLD:${x * 2}'; } }
class SuperSub extends SuperBase {
  @pragma('vm:never-inline')
  String callSuper(int x) {{ marker = '<unset>'; super.v = x; return marker; }}
}
class SuperNew { @pragma('maot:mutable') set v(int x) { marker = 'NEW:${x * 3}'; } }
class SuperNew2 { @pragma('maot:mutable') set v(int x) { marker = 'NEW2:${x * 7}'; } }

class Other { @pragma('maot:mutable') set v(int x) { marker = 'OTHERDECL:${x * 5}'; } }

@pragma('vm:never-inline')
String siteDirect(Direct d, int x) => (() {{ d.v = x; return marker; }})();
@pragma('vm:never-inline')
String siteVirtual(Virt d, int x) => (() {{ d.v = x; return marker; }})();
@pragma('vm:never-inline')
String siteIface(Iface d, int x) => (() {{ d.v = x; return marker; }})();
@pragma('vm:never-inline')
String siteSuper(SuperSub s, int x) => s.callSuper(x);
@pragma('vm:never-inline')
String siteOther(Other d, int x) => (() {{ d.v = x; return marker; }})();

@pragma('vm:never-inline')
Virt mkVirt(int i) => i == 0 ? Virt() : VirtSub();
@pragma('vm:never-inline')
Iface mkIface(int i) => i == 0 ? Ifc() : IfcOther();

const _lib = 'lib:package:m5dispsetter/fixture_m5_disp_setter.dart';

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
  for (var i = 0; i < u.length; i++) { p[i] = u[i]; }
  p[u.length] = 0;
  return p;
}

void _emit(String k, Object v) => print('$k=$v');
final _ns = Platform.environment['MAOT_NAMESPACE'] ?? '';
int _stage(String decl, String impl, int v) =>
    _install(_c('$_lib::$decl'), _c('$_lib::$impl'), v, _c(_ns));
int _ver(String decl) => _version(_c('$_lib::$decl'));

final _direct = Direct();
final _virt = mkVirt(0);
final _ifc = mkIface(0);
final _super = SuperSub();
final _other = Other();

void _observe(String stage) {
  _emit('direct.$stage', siteDirect(_direct, input));
  _emit('virtual.$stage', siteVirtual(_virt, input));
  _emit('iface.$stage', siteIface(_ifc, input));
  _emit('super.$stage', siteSuper(_super, input));
  _emit('other.$stage', siteOther(_other, input));
}

const _forms = ['Direct', 'Virt', 'Ifc', 'Super'];
const _decls = [
  'cls:Direct::set:v',
  'cls:Virt::set:v',
  'cls:Ifc::set:v',
  'cls:SuperBase::set:v',
];

void main() {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('input', input);
  _emit('retain', [(() { DirectNew().v = input; return marker; })(), (() { DirectNew2().v = input; return marker; })(), (() { VirtNew().v = input; return marker; })(), (() { VirtNew2().v = input; return marker; })(), (() { IfcNew().v = input; return marker; })(), (() { IfcNew2().v = input; return marker; })(), (() { SuperNew().v = input; return marker; })(), (() { SuperNew2().v = input; return marker; })()].join('|'));

  for (var i = 0; i < 50000; i++) {
    siteDirect(_direct, input);
    siteVirtual(mkVirt(i & 1), input);
    siteIface(mkIface(i & 1), input);
    siteSuper(_super, input);
    siteOther(_other, input);
  }
  _observe('0');
  for (var i = 0; i < _decls.length; i++) {
    _emit('version.${_forms[i]}.0', _ver(_decls[i]));
  }
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));

  for (var i = 0; i < _decls.length; i++) {
    _emit('install.${_forms[i]}.v2',
        _stage(_decls[i], 'cls:${_forms[i]}New::set:v', 2));
  }
  _observe('v2');
  for (var i = 0; i < _decls.length; i++) {
    _emit('version.${_forms[i]}.v2', _ver(_decls[i]));
  }
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v2.json'));

  for (var i = 0; i < _decls.length; i++) {
    _emit('install.${_forms[i]}.v3',
        _stage(_decls[i], 'cls:${_forms[i]}New2::set:v', 3));
  }
  _observe('v3');
  for (var i = 0; i < _decls.length; i++) {
    _emit('version.${_forms[i]}.v3', _ver(_decls[i]));
  }
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v3.json'));
}
