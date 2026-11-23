// Tests for the analysis version 22 lowering of an extension's instance
// members (`extensionLoweringOf`). Compiles `fixture` with the host Dart, then
// reads the kernel back.
//
//   SRC=$HOME/shorebird-engine/flutter/engine/src
//   HOST_DART=$SRC/out/host_release_arm64/dart-sdk/bin/dart \
//   $SRC/out/host_release_arm64_ddm/dart-sdk/bin/dart \
//     --packages=$SRC/flutter/third_party/dart/.dart_tool/package_config.json \
//     selfhost/engine/route_b/coverage/extension_receiver_test.dart
// cspell:words
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

import 'analyze_coverage.dart';

var _failures = 0;

void check(bool ok, String what) {
  if (!ok) {
    _failures++;
    stderr.writeln('FAIL: $what');
  } else {
    stdout.writeln('ok: $what');
  }
}

const _source = '''
extension Stars on int {
  static const glyph = '*';
  String get stars => glyph * this;
  String get hashes => '#' * this;
  String get wrapped => '\$glyph\$this\$glyph';
  String twice(String s) => stars + s + this.stars + other(s);
  String other(String s) => s;
  bool get big => this > 10 && isEven;
  Object leak() => this;
  Object casc() => this..other('');
  Object Function() tear() => other2;
  String other2() => '';
  int optional([int a = 1]) => a;
  set put(int v) {}
  int operator +(int o) => 1;
}
extension G<T> on List<T> {
  int get n => length;
}
extension on String {
  int get u => length;
}
class _P {}
extension PE on _P {
  int get pv => 1;
}
extension _PX on int {
  int get px => 1;
}
extension type ET(int v) {
  int get zz => v;
}
class Plain {
  int get v => 1;
}
void main() {}
''';

Map<String, Object?>? _lowering(Component c, String name) {
  for (final lib in c.libraries) {
    if (!lib.importUri.toString().endsWith('app.dart')) continue;
    for (final p in lib.procedures) {
      if (p.name.text == name ||
          (name.startsWith('_extension#') &&
              p.name.text.endsWith(name.substring(name.indexOf('|')))))
        return extensionLoweringOf(p);
    }
  }
  return null;
}

List<String> _unsupported(Map<String, Object?>? l) =>
    (l!['unsupported'] as List).cast<String>();

List<(String, String)> _accesses(Map<String, Object?>? l) => [
  for (final a in (l!['accesses'] as List).cast<Map>())
    ('${a['kind']}', '${a['member']}'),
];

void main() {
  final host = Platform.environment['HOST_DART'];
  if (host == null) {
    stderr.writeln('set HOST_DART to the host dart, see the header');
    exit(2);
  }
  final dir = Directory.systemTemp.createTempSync('ext_receiver_test');
  try {
    File('${dir.path}/app.dart').writeAsStringSync(_source);
    final r = Process.runSync(host, [
      'compile',
      'kernel',
      '${dir.path}/app.dart',
      '-o',
      '${dir.path}/app.dill',
    ]);
    if (r.exitCode != 0) {
      stderr.writeln(r.stderr);
      exit(2);
    }
    final c = Component();
    BinaryBuilder(
      File('${dir.path}/app.dill').readAsBytesSync(),
    ).readComponent(c);

    check(analysisVersion == 24, 'analysis version is 24');

    final getter = _lowering(c, 'Stars|get#stars');
    check(getter != null, 'a getter lowers');
    check(_unsupported(getter).isEmpty, 'a getter has nothing unsupported');
    check(getter!['extension'] == 'Stars', 'the extension is named');
    check(getter['receiverType'] == 'int', 'the receiver type is int');
    check(
      _accesses(getter).length == 1 &&
          _accesses(getter).single == ('receiver', 'this'),
      'the getter reports one receiver read',
    );
    check(
      getter['nameOffset'] == _source.indexOf('stars =>'),
      'the name offset is the getter name',
    );

    final interp = _lowering(c, 'Stars|get#wrapped');
    final at = (interp!['accesses'] as List).cast<Map>().single['offset'];
    check(
      _source.substring((at as int) - 1).startsWith('\$this'),
      'a `\$this` interpolation is reported at `this`, after the dollar',
    );

    final method = _lowering(c, 'Stars|twice');
    check(
      _accesses(method).toString() ==
          [
            ('extensionGet', 'stars'),
            ('extensionGet', 'stars'),
            ('extensionInvoke', 'other'),
          ].toString(),
      'sibling members are reported as extension calls: ${_accesses(method)}',
    );
    check(
      (method!['signatureTypes'] as Map)['params'].toString() == '[String]',
      'the receiver is not a signature parameter',
    );

    final big = _lowering(c, 'Stars|get#big');
    check(
      _accesses(big).toString() ==
          [('receiver', 'this'), ('get', 'isEven')].toString(),
      'an implicit receiver member is an ordinary get: ${_accesses(big)}',
    );

    check(
      _unsupported(_lowering(c, 'Stars|leak')).isEmpty,
      'passing `this` along is expressible',
    );
    check(
      _unsupported(
        _lowering(c, 'Stars|tear'),
      ).any((u) => u.contains('tears off')),
      'a tear-off of a sibling is refused',
    );
    check(
      _unsupported(
        _lowering(c, 'Stars|optional'),
      ).any((u) => u.contains('optional')),
      'an optional parameter is refused',
    );
    check(
      _unsupported(
        _lowering(c, 'Stars|set#put'),
      ).any((u) => u.contains('only a getter or a method')),
      'a setter is refused',
    );
    check(
      _unsupported(
        _lowering(c, 'Stars|+'),
      ).any((u) => u.contains('only a getter or a method')),
      'an operator is refused',
    );
    check(
      _unsupported(
        _lowering(c, 'G|get#n'),
      ).any((u) => u.contains('generic extension `G`')),
      'a generic extension is refused',
    );
    check(
      _unsupported(
        _lowering(c, '_extension#|get#u'),
      ).any((u) => u.contains('unnamed extension')),
      'an unnamed extension is refused',
    );
    check(
      _unsupported(
        _lowering(c, 'PE|get#pv'),
      ).any((u) => u.contains('receiver type `_P`')),
      'a private on-type is refused',
    );
    check(
      _unsupported(
        _lowering(c, '_PX|get#px'),
      ).any((u) => u.contains('private extension')),
      'a private extension is refused',
    );
    check(
      _lowering(c, 'ET|get#zz') == null,
      'an extension type member is not an extension lowering',
    );
    check(
      _lowering(c, 'Stars|get#stars') != null && _lowering(c, 'main') == null,
      'a plain function is not',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
  if (_failures > 0) {
    stderr.writeln('$_failures failure(s)');
    exit(1);
  }
}
