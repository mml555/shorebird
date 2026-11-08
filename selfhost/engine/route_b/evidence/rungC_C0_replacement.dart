import 'package:airgap_probe/main.dart';

/// C0: the receiver is DECLARED and deliberately IGNORED. Only the calling
/// convention can make this fail.
@pragma('dyn-module:entry-point')
String value(RouteBThing self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-C0' : 'X';
