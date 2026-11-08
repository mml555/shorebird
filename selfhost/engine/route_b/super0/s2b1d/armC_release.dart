// 2B.1d arm B -- the mixin lifecycle shape. LOAD-BEARING: this is where AOT and
// no-AOT identities diverged in 2A, and where the product demand actually is.
//
// Release and patch share library URI, class hierarchy, mixin ordering, method
// signatures and retention. Only `target`'s body differs.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

class Base {
  String state = 'UNSET';
  @pragma('vm:never-inline')
  String close() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'BASE:$state' : 'X';
}

mixin Ticker on Base {
  @pragma('vm:never-inline')
  String close() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'TICKER:$state' : 'X';
}

class Leaf extends Base with Ticker {
  @pragma('vm:never-inline')
  @override
  String close() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'LEAF:$state' : 'X';

  // NO super site anywhere in the release body. `close()` here is a VIRTUAL
  // call: it keeps the member retained without giving the release any super
  // invocation an offset could have been looked up in. Under the old
  // release-body design there is literally nothing to rediscover, so a patch
  // that INTRODUCES a super call could never be lowered.
  @pragma('vm:never-inline')
  String target() => DateTime.now().millisecondsSinceEpoch >= 0
      ? 'OLD'
      : close();
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String go(Leaf self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

void main(List<String> args) {
  final leaf = Leaf()..state = 'APP-STATE';
  print('unpatched super     : ${leaf.target()}');
  print('virtual             : ${leaf.close()}');
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
