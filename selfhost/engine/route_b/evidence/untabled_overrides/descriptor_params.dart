// Untabled selectors whose implementations need an arguments descriptor
// (optional / named / generic parameters) must still resolve at runtime.
abstract class Part {
  String render({int n = 0});
  String gen<T>(T v);
  String pos([int n = 1]);
}
class P0 extends Part {
  @pragma('vm:never-inline') @override String render({int n = 0}) => 'P0r$n';
  @pragma('vm:never-inline') @override String gen<T>(T v) => 'P0g$v';
  @pragma('vm:never-inline') @override String pos([int n = 1]) => 'P0p$n';
}
class P1 extends Part {
  @pragma('vm:never-inline') @override String render({int n = 0}) => 'P1r$n';
  @pragma('vm:never-inline') @override String gen<T>(T v) => 'P1g$v';
  @pragma('vm:never-inline') @override String pos([int n = 1]) => 'P1p$n';
}
class P2 extends Part {
  @pragma('vm:never-inline') @override String render({int n = 0}) => 'P2r$n';
  @pragma('vm:never-inline') @override String gen<T>(T v) => 'P2g$v';
  @pragma('vm:never-inline') @override String pos([int n = 1]) => 'P2p$n';
}
class P3 extends Part {
  @pragma('vm:never-inline') @override String render({int n = 0}) => 'P3r$n';
  @pragma('vm:never-inline') @override String gen<T>(T v) => 'P3g$v';
  @pragma('vm:never-inline') @override String pos([int n = 1]) => 'P3p$n';
}
class P4 extends Part {
  @pragma('vm:never-inline') @override String render({int n = 0}) => 'P4r$n';
  @pragma('vm:never-inline') @override String gen<T>(T v) => 'P4g$v';
  @pragma('vm:never-inline') @override String pos([int n = 1]) => 'P4p$n';
}
class P5 extends Part {
  @pragma('vm:never-inline') @override String render({int n = 0}) => 'P5r$n';
  @pragma('vm:never-inline') @override String gen<T>(T v) => 'P5g$v';
  @pragma('vm:never-inline') @override String pos([int n = 1]) => 'P5p$n';
}
class P6 extends Part {
  @pragma('vm:never-inline') @override String render({int n = 0}) => 'P6r$n';
  @pragma('vm:never-inline') @override String gen<T>(T v) => 'P6g$v';
  @pragma('vm:never-inline') @override String pos([int n = 1]) => 'P6p$n';
}
class P7 extends Part {
  @pragma('vm:never-inline') @override String render({int n = 0}) => 'P7r$n';
  @pragma('vm:never-inline') @override String gen<T>(T v) => 'P7g$v';
  @pragma('vm:never-inline') @override String pos([int n = 1]) => 'P7p$n';
}
@pragma('vm:never-inline') String callRender(Part p) => p.render(n: 2);
@pragma('vm:never-inline') String callRender0(Part p) => p.render();
@pragma('vm:never-inline') String callGen(Part p) => p.gen<int>(3);
@pragma('vm:never-inline') String callPos(Part p) => p.pos();
void main() {
  final parts = <Part>[P0(), P1(), P2(), P3(), P4(), P5(), P6(), P7()];
  final out = StringBuffer();
  for (var r = 0; r < 3; r++) {
    for (final p in parts) {
      out.write('${callRender(p)} ${callRender0(p)} ${callGen(p)} ${callPos(p)}|');
    }
  }
  print(out.toString().substring(0, 120));
  print('OK ${out.length}');
}
