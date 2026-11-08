// C. Shared heap, BOTH directions of retention.
//
// The host side can see "AOT retains a patch object" by holding PatchPayload.
// The reverse -- patch code retaining an AOT object -- is only visible from the
// module, because the host cannot statically name a patch-defined type. So the
// module verifies it and reports, and the host asserts on the report.
import 'package:dynamic_modules/g2_host.dart';

class PatchPayload {
  final String tag = 'patch-object';
  final Box aotRef;
  PatchPayload(this.aotRef);
}

@pragma('dyn-module:entry-point')
Object? entry() {
  final b = getSharedBox();
  b.v = 99;
  final payload = PatchPayload(b);
  b.held = payload;

  // Patch code retaining an AOT object, checked by identity rather than by
  // equality, from the side that can see both.
  final patchRetainsAot = identical(payload.aotRef, getSharedBox());

  return <Object?>[b, patchRetainsAot];
}
