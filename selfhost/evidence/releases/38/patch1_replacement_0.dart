import 'package:airgap_probe/main.dart';

@pragma('dyn-module:entry-point')
@pragma('vm:never-inline')
  String two(RouteBThing self, String a, int b) => 'PARAM-$a-$b';
