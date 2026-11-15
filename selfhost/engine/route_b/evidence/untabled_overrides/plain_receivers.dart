abstract class Part { String plain(); String one(int n); }
class P0 extends Part { @pragma('vm:never-inline') @override String plain() => 'P0'; @pragma('vm:never-inline') @override String one(int n) => 'P0o$n'; }
class P1 extends Part { @pragma('vm:never-inline') @override String plain() => 'P1'; @pragma('vm:never-inline') @override String one(int n) => 'P1o$n'; }
class P2 extends Part { @pragma('vm:never-inline') @override String plain() => 'P2'; @pragma('vm:never-inline') @override String one(int n) => 'P2o$n'; }
class P3 extends Part { @pragma('vm:never-inline') @override String plain() => 'P3'; @pragma('vm:never-inline') @override String one(int n) => 'P3o$n'; }
class P4 extends Part { @pragma('vm:never-inline') @override String plain() => 'P4'; @pragma('vm:never-inline') @override String one(int n) => 'P4o$n'; }
class P5 extends Part { @pragma('vm:never-inline') @override String plain() => 'P5'; @pragma('vm:never-inline') @override String one(int n) => 'P5o$n'; }
class P6 extends Part { @pragma('vm:never-inline') @override String plain() => 'P6'; @pragma('vm:never-inline') @override String one(int n) => 'P6o$n'; }
class P7 extends Part { @pragma('vm:never-inline') @override String plain() => 'P7'; @pragma('vm:never-inline') @override String one(int n) => 'P7o$n'; }
@pragma('vm:never-inline') String callPlain(Part p) => p.plain();
@pragma('vm:never-inline') String callOne(Part p, int n) => p.one(n);
void main(List<String> args) {
  final parts = <Part>[P0(), P1(), P2(), P3(), P4(), P5(), P6(), P7()];
  final out = StringBuffer();
  for (var r = 0; r < 3; r++) { for (final p in parts) { out.write('${callPlain(p)} ${callOne(p, args.length + r)}|'); } }
  print(out.toString().substring(0, 60)); print('OK ${out.length}');
}
