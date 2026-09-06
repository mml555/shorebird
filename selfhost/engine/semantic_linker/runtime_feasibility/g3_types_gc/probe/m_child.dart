// A patch class EXTENDING an AOT base, whose override calls super into AOT.
// The concatenated 'PATCH:AOT-BASE' is corroboration; the proof is the mode
// transition the host asserts (PatchChild.execute INTERPRETED, Base.execute AOT).
import 'package:dynamic_modules/g3_host.dart';

class PatchChild extends Base {
  @override
  String execute() => 'PATCH:${super.execute()}';
}

@pragma('dyn-module:entry-point')
Object? entry() => PatchChild();
