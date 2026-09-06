// B. bytecode -> AOT. The operands come from host functions rather than
// literals, so `multiply(5, 8)` cannot be folded to 40 inside the module and
// pass without the AOT call ever happening.
import 'package:dynamic_modules/g2_host.dart';

@pragma('dyn-module:entry-point')
Object? entry() => multiply(seedA(), seedB());
