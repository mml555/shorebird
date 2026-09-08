import 'package:dynamic_modules/callsite_target.dart';

@pragma('dyn-module:entry-point')
int tearOffTarget() => DateTime.now().millisecondsSinceEpoch >= 0 ? 171 : 0;
