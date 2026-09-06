// GC 1. The ONLY root of this patch object is an AOT object's field.
import 'package:dynamic_modules/g3_host.dart';

class PatchIface implements Iface {
  @override
  String tag() => 'PATCH-IFACE';
}

@pragma('dyn-module:entry-point')
Object? entry() {
  aotHolder.ref = PatchIface();
  return null;
}
