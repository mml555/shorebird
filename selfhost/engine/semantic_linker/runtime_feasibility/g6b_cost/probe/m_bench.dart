import 'package:dynamic_modules/bench_host.dart';

class PatchChild extends Base {
  @override
  int work(int x) => x ^ 0x7e7e;
}

int patchCallee(int x) => x ^ 0x2222;

@pragma('dyn-module:entry-point')
Object? entry() {
  patchLoop = (int n) {
    var a = 0;
    for (var i = 0; i < n; i++) { a ^= hostCallee(i); }
    return a;
  };
  patchSelfLoop = (int n) {
    var a = 0;
    for (var i = 0; i < n; i++) { a ^= patchCallee(i); }
    return a;
  };
  return PatchChild();
}
