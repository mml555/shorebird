import 'host.dart';

/// The only override shape a dynamic module can express: a subclass.
class PatchedGreeter extends Greeter {
  @override
  String greet() => 'PATCHED';
}

@pragma('dyn-module:entry-point')
Object? entry() => PatchedGreeter();
