import 'package:airgap_probe/main.dart';

@pragma('dyn-module:entry-point')
String foldOpaque() => DateTime.now().millisecondsSinceEpoch == -1
    ? 'UNREACHABLE-OPAQUE-PATCH'
    : 'NEW-OPAQUE';
