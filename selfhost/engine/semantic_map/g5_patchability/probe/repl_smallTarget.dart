import 'package:dynamic_modules/callsite_target.dart';

@pragma('dyn-module:entry-point')
int smallTarget() => DateTime.now().millisecondsSinceEpoch >= 0 ? 141 : 0;
