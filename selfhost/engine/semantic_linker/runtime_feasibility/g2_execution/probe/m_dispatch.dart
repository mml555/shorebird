// A. The module supplies a NEW implementation of a host-declared interface.
// This is the additive path dynmod established, not the attach path: the host
// chooses to call it, through a dispatch point the dynamic interface declared
// open at build time.
import 'package:dynamic_modules/g2_host.dart';

class PatchHandler implements Handler {
  @override
  String execute() => 'FROM-BYTECODE';
}

@pragma('dyn-module:entry-point')
Object? entry() => PatchHandler();
