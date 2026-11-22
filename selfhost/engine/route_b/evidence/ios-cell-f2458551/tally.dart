/// A local pure-Dart dependency, the stand-in for a package the app depends on.
library;

String tallyLabel(int n) {
  final parts = <String>[];
  for (var i = 0; i < n; i++) {
    parts.add('|');
  }
  return 'K1 $n ${parts.join()}';
}
