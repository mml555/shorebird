// GC 3. An AOT -> patch -> AOT cycle with no external strong root.
//
// Built inside a never-inline function so its locals die with the frame, and
// observed through AOT-created weak references -- the collector's own signal.
// Nothing here is rooted in aotHolder or patchProbe on purpose.
import 'package:dynamic_modules/g3_host.dart';

class CycleNode {
  Object? aot;
  Object? other;
  CycleNode(this.aot);
}

@pragma('vm:never-inline')
List<Object?> build() {
  final h = Holder();               // AOT object
  final node = CycleNode(h);        // patch object -> AOT
  h.ref = node;                     // AOT -> patch   (a real cycle)
  node.other = makeTracked(7);      // ... and a second AOT object hanging off it
  return <Object?>[weakOf(node), weakOf(h)];
}

@pragma('dyn-module:entry-point')
Object? entry() => build();
