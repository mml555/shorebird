// r2 — app-symbol binding: the replacement calls back into the host program.
// Resolves at load time only if the host's hostSuffix() is findable by name
// (bytecode_reader.cc Resolver::ResolveFunction).
import 'package:dynamic_modules/target_binding.dart' show hostSuffix;

@pragma('dyn-module:entry-point')
String greet() => 'NEW-${hostSuffix()}';
