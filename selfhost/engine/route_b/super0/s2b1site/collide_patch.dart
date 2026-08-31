// 2B.1c-SITE, the DANGEROUS direction. Release and patch are byte-aligned at the
// super site on purpose:
//
//   release  super.close(   )      zero arguments
//   patch    super.close('x')      one argument
//
// `(   )` and `('x')` are both five characters, so `close` sits at the SAME file
// offset in both source versions and the member name matches too. Every guard in
// 0015 other than the argument check therefore passes, and the argument check is
// reading the RELEASE body.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

class Base {
  String log = 'UNSET';
  @pragma('vm:never-inline')
  String close([String? x]) => DateTime.now().millisecondsSinceEpoch >= 0
      ? 'BASE:${x ?? 'NONE'}:$log'
      : 'X';
}

class Leaf extends Base {
  @pragma('vm:never-inline')
  @override
  String close([String? x]) => DateTime.now().millisecondsSinceEpoch >= 0
      ? 'LEAF:${x ?? 'NONE'}:$log'
      : 'X';

  @pragma('vm:never-inline')
  String original() => super.close('x');
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String go(Leaf self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

void main(List<String> args) {
  final leaf = Leaf()..log = 'APP';
  print('release super call  : ${leaf.original()}');
  print('virtual             : ${leaf.close('v')}');
  if (args.isEmpty) {
    print('usage: target <replacement.bytecode> [uri]');
    exitCode = 2;
    return;
  }
  final ok = attachBytecodeToFunction(
    Uint8List.fromList(File(args[0]).readAsBytesSync()),
    args.length > 1 ? args[1] : 'file:///gate/target.dart',
    'go',
  );
  print('attach              : $ok');
  print('patched             : ${go(leaf)}');
}
