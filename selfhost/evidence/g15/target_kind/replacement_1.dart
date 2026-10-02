import 'package:airgap_probe/main.dart';

@pragma('dyn-module:entry-point')
@pragma('vm:never-inline')
String kindTopLevel() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'NEW-TOP'
    : 'UNREACHABLE-TOP';
