import 'package:dynamic_modules/callsite_target.dart';

@pragma('dyn-module:entry-point')
String alpha() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'PATCHED-a' : 'X';
