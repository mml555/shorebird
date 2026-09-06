// D2. AOT throws, bytecode catches -- through a host `finally`, and the module
// then keeps working. "Repeated use after exceptions" is the last clause: a
// boundary that survives one throw but is corrupted afterwards would pass a
// weaker test.
import 'package:dynamic_modules/g2_host.dart';

@pragma('dyn-module:entry-point')
Object? entry() {
  var caught = 'NONE';
  try {
    hostThrows();
  } on Object catch (e) {
    caught = 'MODULE-CAUGHT:$e';
  }

  var fin = 'NONE';
  try {
    hostThrowsWithFinally();
  } on Object catch (_) {
    fin = hostFinallyMark;
  }

  // The boundary must still work after two unwindings.
  final again = multiply(seedA(), 16);
  return '$caught|FINALLY:$fin|AGAIN:$again';
}
