import 'package:airgap_probe/main.dart';

@pragma('dyn-module:entry-point')
String foldConst() => 1 == 2 ? 'UNREACHABLE-CONST-PATCH' : 'NEW-CONST';
