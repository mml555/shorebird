// D1. A patch-DEFINED exception type crosses into AOT. The module catches it
// itself first to prove the type is real on the bytecode side, then rethrows a
// marker the host can assert on without needing the type at compile time.
import 'package:dynamic_modules/g2_host.dart';

class ModuleException implements Exception {
  @override
  String toString() => 'ModuleException';
}

@pragma('dyn-module:entry-point')
Object? entry() {
  try {
    throw ModuleException();
  } on Object catch (e) {
    return 'CAUGHT:$e';
  }
}
