import 'package:dynamic_modules/host.dart';

class PatchTarget extends Target {
  @override
  String work() => 'PATCH-TARGET';
}

@pragma('dyn-module:entry-point')
Object? entry() => PatchTarget();
