// Part 2B specimen, HARNESS HALF. Holds `dart:_internal` so the patchable
// library does not have to.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

import 'package:dynamic_modules/target.dart';

void main(List<String> args) {
  final leaf = Leaf()..state = 'APP-STATE';
  print('unpatched            : ${leaf.target()}');
  print('virtual              : ${leaf.close()}');
  if (args.isEmpty) {
    print('usage: harness <replacement.bytecode> [libraryUri]');
    exitCode = 2;
    return;
  }
  final ok = attachBytecodeToFunction(
    Uint8List.fromList(File(args[0]).readAsBytesSync()),
    args.length > 1 ? args[1] : 'package:dynamic_modules/target.dart',
    'Leaf.target',
  );
  print('attach               : $ok');
  print('patched              : ${leaf.target()}');
}
