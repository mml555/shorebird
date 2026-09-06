// The generic case the ruling singled out: the TYPE ARGUMENT itself is
// patch-defined and crosses into AOT generic code and back.
//
// echo<Base>(p) from the host side only proves the VALUE survives. Here the
// module instantiates the AOT generic at PatchChild -- a type that did not
// exist when the host was compiled -- so the reified type argument has to cross
// the boundary too.
import 'package:dynamic_modules/g3_host.dart';

class PatchChild extends Base {
  @override
  String execute() => 'PATCH:${super.execute()}';
}

@pragma('dyn-module:entry-point')
Object? entry() {
  final p = PatchChild();
  final back = echo<PatchChild>(p);
  return <Object?>[back, identical(back, p), '${back.runtimeType}', back is PatchChild];
}
