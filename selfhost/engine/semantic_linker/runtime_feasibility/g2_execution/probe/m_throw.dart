// D1. A patch-DEFINED exception type propagates OUT of bytecode and is caught by
// AOT. The first version of this test caught it inside the module and returned a
// String marker -- so nothing ever crossed the boundary, and the host's check
// "a patch-defined throwable reached AOT" was satisfied by a String. It now
// throws uncaught, and the AOT side does the catching.
class ModuleException implements Exception {
  final String detail;
  ModuleException(this.detail);
  @override
  String toString() => 'ModuleException($detail)';
}

@pragma('vm:never-inline')
Never raise() => throw ModuleException('from-module');

@pragma('dyn-module:entry-point')
Object? entry() => raise();
