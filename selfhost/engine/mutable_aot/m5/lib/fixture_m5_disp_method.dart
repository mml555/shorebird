// MAOT-5 (#69) Task A -- dispatch matrix for the `method` subject.
//
// Four declarations, one per FINAL AOT ROUTE, measured by the lowering survey
// rather than assumed from syntax:
//
//   direct    -> pc-relative static call -> declaration trampoline -> cell
//   virtual   -> dispatch table          -> declaration trampoline -> cell
//   interface -> dispatch table          -> declaration trampoline -> cell
//   super     -> inline #67 cell indirection at the caller
//
// The forms need separate declarations because they are mutually exclusive on
// one class: a class with a subclass cannot receive an exact (direct) call,
// and one without a subclass cannot receive a virtual one.
//
// `Other` is the cross-wiring control -- a mutable declaration sharing the
// selector that must be untouched by any of the four installs.
import 'dart:ffi';
import 'dart:io' show Platform;

final int input = int.tryParse(Platform.environment['M5_INPUT'] ?? '') ?? 10;

abstract class Iface {
  String v(int x);
}

class Direct {
  @pragma('maot:mutable')
  String v(int x) => 'OLD:${x * 2}';
}
class DirectNew {
  @pragma('maot:mutable')
  String v(int x) => 'NEW:${x * 3}';
}
class DirectNew2 {
  @pragma('maot:mutable')
  String v(int x) => 'NEW2:${x + 7}';
}

class Virt {
  @pragma('maot:mutable')
  String v(int x) => 'OLD:${x * 2}';
}
class VirtSub extends Virt {
  @override
  String v(int x) => 'SUB:$x';
}
class VirtNew {
  @pragma('maot:mutable')
  String v(int x) => 'NEW:${x * 3}';
}
class VirtNew2 {
  @pragma('maot:mutable')
  String v(int x) => 'NEW2:${x + 7}';
}

class Ifc implements Iface {
  @pragma('maot:mutable')
  @override
  String v(int x) => 'OLD:${x * 2}';
}
class IfcOther implements Iface {
  @override
  String v(int x) => 'OTHER:$x';
}
class IfcNew {
  @pragma('maot:mutable')
  String v(int x) => 'NEW:${x * 3}';
}
class IfcNew2 {
  @pragma('maot:mutable')
  String v(int x) => 'NEW2:${x + 7}';
}

class SuperBase {
  @pragma('maot:mutable')
  String v(int x) => 'OLD:${x * 2}';
}
class SuperSub extends SuperBase {
  @pragma('vm:never-inline')
  String callSuper(int x) => super.v(x);
}
class SuperNew {
  @pragma('maot:mutable')
  String v(int x) => 'NEW:${x * 3}';
}
class SuperNew2 {
  @pragma('maot:mutable')
  String v(int x) => 'NEW2:${x + 7}';
}

// Cross-wiring control.
class Other {
  @pragma('maot:mutable')
  String v(int x) => 'OTHERDECL:${x * 5}';
}

@pragma('vm:never-inline')
String siteDirect(Direct d, int x) => d.v(x);
@pragma('vm:never-inline')
String siteVirtual(Virt v, int x) => v.v(x);
@pragma('vm:never-inline')
String siteIface(Iface i, int x) => i.v(x);
@pragma('vm:never-inline')
String siteSuper(SuperSub s, int x) => s.callSuper(x);
@pragma('vm:never-inline')
String siteOther(Other o, int x) => o.v(x);

@pragma('vm:never-inline')
Virt mkVirt(int i) => i == 0 ? Virt() : VirtSub();
@pragma('vm:never-inline')
Iface mkIface(int i) => i == 0 ? Ifc() : IfcOther();

const _lib = 'lib:package:m5dispmethod/fixture_m5_disp_method.dart';

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
  'cls:Direct::method:v',
  'cls:Virt::method:v',
  'cls:Ifc::method:v',
  'cls:SuperBase::method:v',
];

void main() {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('input', input);
  // Retain every replacement body.
  _emit('retain', [
    DirectNew().v(input), DirectNew2().v(input),
    VirtNew().v(input), VirtNew2().v(input),
    IfcNew().v(input), IfcNew2().v(input),
    SuperNew().v(input), SuperNew2().v(input),
  ].join('|'));

  // Warm every route, including the polymorphic ones.
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
        _stage(_decls[i], 'cls:${_forms[i]}New::method:v', 2));
  }
  _observe('v2');
  for (var i = 0; i < _decls.length; i++) {
    _emit('version.${_forms[i]}.v2', _ver(_decls[i]));
  }
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v2.json'));

  for (var i = 0; i < _decls.length; i++) {
    _emit('install.${_forms[i]}.v3',
        _stage(_decls[i], 'cls:${_forms[i]}New2::method:v', 3));
  }
  _observe('v3');
  for (var i = 0; i < _decls.length; i++) {
    _emit('version.${_forms[i]}.v3', _ver(_decls[i]));
  }
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v3.json'));
}
