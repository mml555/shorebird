import 'package:dynamic_modules/alloc_host.dart';

/// A patch-defined type with the same shape as the AOT Cell, so the two
/// bytecode modes differ only in WHICH type is allocated.
class PatchCell {
  final int v;
  Object? link;
  PatchCell(this.v);
}

@pragma('dyn-module:entry-point')
Object? entry() {
  allocBytecodeAotType = (int n, int seed) {
    var acc = 0;
    for (var i = 0; i < n; i++) {
      final c = makeCell(seed + i);
      keep(i, c);
      acc ^= c.v;
    }
    return acc;
  };
  allocBytecodePatchType = (int n, int seed) {
    var acc = 0;
    for (var i = 0; i < n; i++) {
      final c = PatchCell(seed + i);
      keep(i, c);
      acc ^= c.v;
    }
    return acc;
  };
  return null;
}
