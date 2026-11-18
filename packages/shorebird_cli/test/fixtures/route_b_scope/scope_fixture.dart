// A fixture for the class-scope tests. Every static of a class or extension
// below has a top-level (or imported) twin, so an unqualified use that
// the replacement library resolves among top-level names binds to the wrong
// one. `scope_fixture.json` is the real `enclosingScopeOf` output for each
// member, produced by `selfhost/engine/route_b/coverage/gen_scope_fixture.dart`
// (the command is in its header). Regenerate it when this file changes.
//
// cspell:words nullspread lineafter constmap
// ignore_for_file: type=lint, unused_element

double k = 1.5;
List<int> ls = [];
String s = 'top';
int Function(int) g = (x) => x;
int nn = -1;
int cc = -1;

mixin M {
  static int mk = 3;
  int viaMixin() => mk;
}

class _A with M {}

void _use() => _A();

class C<T> {
  static int k = 2;
  static List<int> ls = [1, 2];
  static const String s = 'static';
  static const int c = 7;
  static int? nn;
  static int cc = 5;
  static int g(int x) => x + 1;

  int f(int a) => a + k;
  static int st(int a) => a + k;
  static int spread() => [...ls].length;
  static Object setSpread() => {...ls};
  static int lineafter() {
    final a = [
      1, // one.
      k,
    ];
    return a.length;
  }

  static int argAfterComment() => g(
    // the base value.
    cc,
  );
  static Object constmap() => const {'a': 1, s: 2};
  static Object constmapFirst() => const {s: 1, 'a': 2};
  static Object constlist() => const [c, 2];
  static int nullAssign() => nn ??= 4;
  static Object tearoff() => [1].map(g).toList();
  static String interp() => 'v=$k ${k} $c';
  static int already(int a) => a + C.k;
  static int namedLabel() => h(k: 1);
  static int h({int k = 0}) => k;
  static int param(int k) => k;
  @Deprecated('use $c')
  static int annotated() => 1;
  static int compound() {
    k += 1;
    return k++;
  }

  T? generic(T? t) => t;
  Object closure(int a) => [1].map((e) => e + k + C.k).first + a;
}

extension X on int {
  static int k = 4;
  static int s() => k;
  int inst() => this + k;
  int get zz => k;
  set zs(int v) {
    k = v;
  }

  String interp() => '$k$this$k';
  int sibling() => inst() + zz + this.inst();
  int cmp(int a) => this > a ? 1 : 0;
  int get inClosure => [1].map((e) => e + inst()).length;
  Object leak() => this;
  Object Function() tear() => inst;
  int optional([int a = 1]) => a + this;
  int get implicit => isEven ? 1 : 0;
}

extension G<T> on List<T> {
  int get firstLen => length;
}

extension on String {
  int get unnamed => length;
}

class _P {}

extension PE on _P {
  int get pv => 1;
}

extension _PX on int {
  int get px => 1;
}

extension type ET(int v) {
  static int k = 6;
  static int s() => k;
  int get zz => k;
  set zs(int x) {
    k = x;
  }
}

void main() {}
