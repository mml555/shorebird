import 'package:airgap_probe/main.dart';

/// C1: the receiver is USED. A public member, resolved through arg0.
@pragma('dyn-module:entry-point')
String value(RouteBThing self) => self.label;
