import 'package:airgap_probe/main.dart';

@pragma('dyn-module:entry-point')
@pragma('vm:never-inline')
  String value(RouteBThing self) => self.label;
