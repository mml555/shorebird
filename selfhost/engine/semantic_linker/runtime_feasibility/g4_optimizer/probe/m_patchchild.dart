import 'package:dynamic_modules/g4_host.dart';

class PatchChild extends Base {
  @override
  String execute() => 'PATCH-CHILD';
}

@pragma('dyn-module:entry-point')
Object? entry() => PatchChild();
