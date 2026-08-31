// The intrinsic carries ONLY a source-level site description: the origin class
// and the member name. No transported target identity, and in particular
// nothing from `dart:mixin_deduplication` — which is the whole point.
import 'package:dynamic_modules/target_2a2.dart';

String shorebirdSuperCall(Object receiver, String library, String originClass,
        String member) =>
    throw StateError('Route B compiler intrinsic was not lowered');

@pragma('dyn-module:entry-point')
String deepGo(DeepC self) => shorebirdSuperCall(
      self,
      'package:dynamic_modules/target_2a2.dart',
      'DeepC',
      'read',
    );
