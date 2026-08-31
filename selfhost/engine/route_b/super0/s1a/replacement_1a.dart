// D-SUPER-1A replacement. An ordinary StaticInvocation of an app top-level
// function -- the existing route to `_genDirectCall`. Nothing exotic: if this
// cannot bind, a receiver-taking direct call certainly cannot, and bucket B is
// dead before it is tested.
import 'package:dynamic_modules/target_1a.dart';

@pragma('dyn-module:entry-point')
String greet() => releaseTopLevel('PROBE');
