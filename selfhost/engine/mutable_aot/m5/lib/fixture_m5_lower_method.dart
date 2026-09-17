// MAOT-5 (#69) Task A -- LOWERING SURVEY for the `method` subject.
//
// This fixture does not replace anything. It exists to measure what each
// SOURCE form actually lowers to in final AOT code, before any cell of the
// dispatch matrix is claimed.
//
// The matrix must describe final AOT routing, not source syntax. A virtual or
// interface construct that the compiler devirtualises is NOT a `direct` cell;
// it is a virtual/interface source form with a direct final route, and
// recording it as two cells would double-count one mechanism.
//
// Each dispatch form needs its own declaration because the forms are mutually
// exclusive on one class: a class with a subclass cannot be the receiver of an
// exact (direct) call, and a class with no subclass cannot be the receiver of
// a virtual one.
import 'dart:io' show Platform;

final int input = int.tryParse(Platform.environment['M5_INPUT'] ?? '') ?? 10;

abstract class Iface {
  String v(int x);
}

// DIRECT: no subclasses, exact receiver type at the site.
class Direct {
  @pragma('maot:mutable')
  String v(int x) => 'OLD-DIRECT:${x * 2}';
}

// VIRTUAL: a subclass exists, so the site cannot be exact.
class Virt {
  @pragma('maot:mutable')
  String v(int x) => 'OLD-VIRT:${x * 2}';
}

class VirtSub extends Virt {
  @override
  String v(int x) => 'SUB:$x';
}

// INTERFACE: the site's static type is the interface.
class Ifc implements Iface {
  @pragma('maot:mutable')
  @override
  String v(int x) => 'OLD-IFC:${x * 2}';
}

class IfcOther implements Iface {
  @override
  String v(int x) => 'OTHER:$x';
}

// SUPER: statically selected, already classified as super/static-cell.
class SuperBase {
  @pragma('maot:mutable')
  String v(int x) => 'OLD-SUPER:${x * 2}';
}

class SuperSub extends SuperBase {
  @pragma('vm:never-inline')
  String callSuper(int x) => super.v(x);
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
Virt mkVirt(int i) => i == 0 ? Virt() : VirtSub();

@pragma('vm:never-inline')
Iface mkIface(int i) => i == 0 ? Ifc() : IfcOther();

void main() {
  print(siteDirect(Direct(), input));
  for (var i = 0; i < 2; i++) {
    print(siteVirtual(mkVirt(i), input));
    print(siteIface(mkIface(i), input));
  }
  print(siteSuper(SuperSub(), input));
}
