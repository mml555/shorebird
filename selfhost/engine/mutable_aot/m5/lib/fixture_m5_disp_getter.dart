// MAOT-5 (#69) Task A -- dispatch matrix for the `getter` subject.
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
  String get v;
}

class Direct { @pragma('maot:mutable') String get v => 'OLD:${input * 2}'; }
class DirectNew { @pragma('maot:mutable') String get v => 'NEW:${input * 3}'; }
class DirectNew2 { @pragma('maot:mutable') String get v => 'NEW2:${input * 7}'; }

class Virt { @pragma('maot:mutable') String get v => 'OLD:${input * 2}'; }
class VirtSub extends Virt { @override String get v => 'SUB'; }
class VirtNew { @pragma('maot:mutable') String get v => 'NEW:${input * 3}'; }
class VirtNew2 { @pragma('maot:mutable') String get v => 'NEW2:${input * 7}'; }

class Ifc implements Iface { @pragma('maot:mutable') @override String get v => 'OLD:${input * 2}'; }
class IfcOther implements Iface { @override String get v => 'OTHER'; }
class IfcNew { @pragma('maot:mutable') String get v => 'NEW:${input * 3}'; }
class IfcNew2 { @pragma('maot:mutable') String get v => 'NEW2:${input * 7}'; }

class SuperBase { @pragma('maot:mutable') String get v => 'OLD:${input * 2}'; }
class SuperSub extends SuperBase {
  @pragma('vm:never-inline')
  String callSuper() => super.v;
}
class SuperNew { @pragma('maot:mutable') String get v => 'NEW:${input * 3}'; }
class SuperNew2 { @pragma('maot:mutable') String get v => 'NEW2:${input * 7}'; }

class Other { @pragma('maot:mutable') String get v => 'OTHERDECL:${input * 5}'; }

@pragma('vm:never-inline')
String siteDirect(Direct d) => d.v;
@pragma('vm:never-inline')
String siteVirtual(Virt d) => d.v;
@pragma('vm:never-inline')
String siteIface(Iface d) => d.v;
@pragma('vm:never-inline')
String siteSuper(SuperSub s) => s.callSuper();
@pragma('vm:never-inline')
String siteOther(Other d) => d.v;

@pragma('vm:never-inline')
Virt mkVirt(int i) => i == 0 ? Virt() : VirtSub();
@pragma('vm:never-inline')
Iface mkIface(int i) => i == 0 ? Ifc() : IfcOther();

const _lib = 'lib:package:m5dispgetter/fixture_m5_disp_getter.dart';

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
  _emit('direct.$stage', siteDirect(_direct));
  _emit('virtual.$stage', siteVirtual(_virt));
  _emit('iface.$stage', siteIface(_ifc));
  _emit('super.$stage', siteSuper(_super));
  _emit('other.$stage', siteOther(_other));
}

const _forms = ['Direct', 'Virt', 'Ifc', 'Super'];
const _decls = [
  'cls:Direct::get:v',
  'cls:Virt::get:v',
  'cls:Ifc::get:v',
  'cls:SuperBase::get:v',
];

void main() {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('input', input);
  _emit('retain', [DirectNew().v, DirectNew2().v, VirtNew().v, VirtNew2().v, IfcNew().v, IfcNew2().v, SuperNew().v, SuperNew2().v].join('|'));

  for (var i = 0; i < 50000; i++) {
    siteDirect(_direct);
    siteVirtual(mkVirt(i & 1));
    siteIface(mkIface(i & 1));
    siteSuper(_super);
    siteOther(_other);
  }
  _observe('0');
  for (var i = 0; i < _decls.length; i++) {
    _emit('version.${_forms[i]}.0', _ver(_decls[i]));
  }
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));

  for (var i = 0; i < _decls.length; i++) {
    _emit('install.${_forms[i]}.v2',
        _stage(_decls[i], 'cls:${_forms[i]}New::get:v', 2));
  }
  _observe('v2');
  for (var i = 0; i < _decls.length; i++) {
    _emit('version.${_forms[i]}.v2', _ver(_decls[i]));
  }
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v2.json'));

  for (var i = 0; i < _decls.length; i++) {
    _emit('install.${_forms[i]}.v3',
        _stage(_decls[i], 'cls:${_forms[i]}New2::get:v', 3));
  }
  _observe('v3');
  for (var i = 0; i < _decls.length; i++) {
    _emit('version.${_forms[i]}.v3', _ver(_decls[i]));
  }
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v3.json'));
}
