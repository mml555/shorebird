import 'package:dynamic_modules/g4_host_solo.dart';

class PatchChild extends Base {
  @override
  String execute() => 'PATCH-CHILD';
}

@pragma('dyn-module:entry-point')
Object? entry() => PatchChild();
