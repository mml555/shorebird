import 'package:airgap_probe/main.dart';

@pragma('dyn-module:entry-point')
@pragma('vm:never-inline')
  String paramValue(RouteBThing self, String who) => 'PARAM-$who';
