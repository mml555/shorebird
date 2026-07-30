import 'dart:io';
import 'dart:typed_data';

/// Bind the VM's dynamic-module loader directly, the same way
/// dart:_internal's patch does, since user code cannot import dart:_internal.
@pragma("vm:external-name", "Internal_loadDynamicModule")
external Object? _loadDynamicModule(Uint8List bytes);

class Greeter {
  String greet() => 'ORIGINAL';
}

final Greeter existing = Greeter();

void main(List<String> args) {
  print('A. existing.greet()            = ${existing.greet()}');
  if (args.isEmpty) return;
  final bytes = File(args[0]).readAsBytesSync();
  final result = _loadDynamicModule(Uint8List.fromList(bytes));
  print('B. module entry returned       = $result');
  print('C. existing.greet() after load = ${existing.greet()}');
  if (result is Greeter) print('D. result.greet()              = ${result.greet()}');
}
