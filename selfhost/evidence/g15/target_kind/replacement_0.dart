import 'package:airgap_probe/main.dart';

@pragma('dyn-module:entry-point')
@pragma('vm:never-inline')
  String kindMember(RouteBThing self) => DateTime.now().millisecondsSinceEpoch >= 0
      ? 'NEW-MEMBER'
      : 'UNREACHABLE-MEMBER';
