// SL1-G6A host: the smallest program that can exercise every negative category.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show loadDynamicModule;
import 'dart:io';
import 'dart:typed_data';

class Base {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  String execute() => 'AOT-BASE';
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String dispatch(Base b) => b.execute();

/// Retained ONLY by the dynamic interface -- deliberately no vm:entry-point.
/// With the pragma present, withdrawing `callable` changed nothing and the
/// missing_retained_import negative passed while measuring nothing.
@pragma('vm:never-inline')
String retained() => 'RETAINED';

/// Deliberately NOT listed in any dynamic interface and never called from the
/// host: the tree-shaken target a module must fail to resolve.
@pragma('vm:never-inline')
String shakenAway() => 'SHAKEN';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('POSITIVE: host runs, dispatch=${dispatch(Base())}');
    return;
  }
  final bytes = Uint8List.fromList(File(args[0]).readAsBytesSync());
  final r = await loadDynamicModule(bytes: bytes);
  print('LOADED: $r');
  if (r is Base) print('DISPATCH: ${dispatch(r)}');
}
