
import 'dart:io';
import 'package:shorebird_cli/src/route_b_sdk_kept.dart';
void main(List<String> args) {
  for (final p in args) {
    final kept = RouteBSnapshotKept.fromProfileJson(
        File(p).readAsStringSync());
    final why = kept.problemFor(
      declaredLibrary: 'dart:async', declaredClass: 'Future',
      measured: const [], selector: 'then', excludeClasses: const {'_Future'});
    print('$p\n  await on Future: ${why ?? 'OK, every allocated Future subtype has then'}');
    for (final s in ['catchError', 'whenComplete', 'timeout']) {
      print('  $s: ${kept.problemFor(declaredLibrary: 'dart:async', declaredClass: 'Future', measured: const [], selector: s, excludeClasses: const {'_Future'}) ?? 'OK'}');
    }
  }
}
