// GC 2. The ONLY root of this AOT object is a patch object's field. The probe
// closure lets the host re-enter bytecode AFTER the collection, so survival is
// checked from the patch side rather than inferred from the host's own copy.
import 'package:dynamic_modules/g3_host.dart';

class PatchHolder {
  final Tracked aotRef;
  PatchHolder(this.aotRef);
}

@pragma('dyn-module:entry-point')
Object? entry() {
  final holder = PatchHolder(makeTracked(42));
  aotHolder.ref = holder;          // the patch object itself is rooted
  patchProbe = () => holder.aotRef; // ... and only IT roots the AOT object
  return null;
}
