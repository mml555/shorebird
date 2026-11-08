// The positive path. Every negative is this module with exactly one thing wrong,
// so a failure is attributable to the mutation rather than to the harness.
import 'package:dynamic_modules/n_host.dart';

class PatchChild extends Base {
  @override
  String execute() => 'PATCH-CHILD';
}

@pragma('dyn-module:entry-point')
Object? entry() {
  retained();
  return PatchChild();
}
