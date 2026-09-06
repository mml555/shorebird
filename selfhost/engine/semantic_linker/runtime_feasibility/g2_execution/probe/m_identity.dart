// C. Shared heap. Takes the host's own object, mutates it, hands the host a
// patch-defined object to retain, and returns the SAME reference -- so the host
// can assert identical(), not equality.
import 'package:dynamic_modules/g2_host.dart';

class PatchPayload {
  final String tag = 'patch-object';
}

@pragma('dyn-module:entry-point')
Object? entry() {
  final b = getSharedBox();
  b.v = 99;
  b.held = PatchPayload();
  return b;
}
