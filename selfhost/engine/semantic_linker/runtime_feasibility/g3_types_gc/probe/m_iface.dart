// A patch class implementing an AOT-declared interface.
import 'package:dynamic_modules/g3_host.dart';

class PatchIface implements Iface {
  @override
  String tag() => 'PATCH-IFACE';
}

@pragma('dyn-module:entry-point')
Object? entry() => PatchIface();
