// Fixture for inlined_ops_qualify.dart: one function per call-site shape, named
// `<expectation>__<what>`. `yes__` means dart2bytecode turns every operator site
// in the body into an opcode (analysis version 20 marks the reference
// `inlined`); `no__` means at least one site is a real interface call.
// (`a! + b` is `yes__`: the null check gives the operand type `int`.)
// Constant operands are avoided on purpose: `1 + 2` is folded before any
// compiler looks at it.
// ignore_for_file: unused_element, unnecessary_non_null_assertion, unused_local_variable
// cspell:words shl shr

import 'dart:math' show Point;

// BEGIN-FUNCTIONS (the qualification also copies these into `class F`, so each
// shape is checked as a static function and as an instance method the producer
// lowers to a static taking `self`)
Object? yes__int_add(int a, int b) => a + b;
Object? yes__int_sub(int a, int b) => a - b;
Object? yes__int_mul(int a, int b) => a * b;
Object? yes__int_tdiv(int a, int b) => a ~/ b;
Object? yes__int_mod(int a, int b) => a % b;
Object? yes__int_and(int a, int b) => a & b;
Object? yes__int_or(int a, int b) => a | b;
Object? yes__int_xor(int a, int b) => a ^ b;
Object? yes__int_shl(int a, int b) => a << b;
Object? yes__int_shr(int a, int b) => a >> b;
Object? yes__int_gt(int a, int b) => a > b;
Object? yes__int_lt(int a, int b) => a < b;
Object? yes__int_ge(int a, int b) => a >= b;
Object? yes__int_le(int a, int b) => a <= b;
Object? yes__double_add(double a, double b) => a + b;
Object? yes__double_sub(double a, double b) => a - b;
Object? yes__double_mul(double a, double b) => a * b;
Object? yes__double_div(double a, double b) => a / b;
Object? yes__double_gt(double a, double b) => a > b;
Object? yes__double_lt(double a, double b) => a < b;
Object? yes__double_ge(double a, double b) => a >= b;
Object? yes__double_le(double a, double b) => a <= b;
Object? yes__int_neg(int a) => -a;
Object? yes__double_neg(double a) => -a;
Object? no__num_add(num a, num b) => a + b;
// State machines: the analyzer reads the kernel before the async/sync*
// lowering, the compiler after it, and the static type of an operand can differ.
Future<Object?> yes__async_await(Future<int> f, int b) async => await f + b;
Stream<int> yes__asyncstar(int a, int b) async* { yield a + b; }
Iterable<int> yes__syncstar(int a, int b) sync* { yield a + b; }
Future<Object?> yes__await_for(Stream<int> s, int b) async { var t = 0; await for (final x in s) { t = t + x; } return t + b; }
Future<Object?> yes__async_closure(Future<int> f, int b) async { final v = await f; return () => v + b; }
Future<Object?> no__async_num(Future<num> f, int b) async => await f + b;
Object? no__int_double_add(int a, double b) => a + b;
Object? no__double_int_add(double a, int b) => a + b;
Object? no__int_num_add(int a, num b) => a + b;
Object? yes__null_check_int_add(int? a, int b) => a! + b;
Object? no__num_mul(num a, num b) => a * b;
Object? no__int_double_mul(int a, double b) => a * b;
Object? no__double_int_mul(double a, int b) => a * b;
Object? no__int_num_mul(int a, num b) => a * b;
Object? yes__null_check_int_mul(int? a, int b) => a! * b;
Object? no__num_lt(num a, num b) => a < b;
Object? no__int_double_lt(int a, double b) => a < b;
Object? no__double_int_lt(double a, int b) => a < b;
Object? no__int_num_lt(int a, num b) => a < b;
Object? yes__null_check_int_lt(int? a, int b) => a! < b;
Object? no__num_ge(num a, num b) => a >= b;
Object? no__int_double_ge(int a, double b) => a >= b;
Object? no__double_int_ge(double a, int b) => a >= b;
Object? no__int_num_ge(int a, num b) => a >= b;
Object? yes__null_check_int_ge(int? a, int b) => a! >= b;
Object? no__int_mod_double(int a, double b) => a % b;
Object? no__int_tdiv_double(int a, double b) => a ~/ b;
Object? no__num_neg(num a) => -a;
Object? no__dynamic_add(dynamic a, dynamic b) => a + b;
Object? no__int_gtgtgt(int a, int b) => a >>> b;
Object? no__num_tdiv(num a, num b) => a ~/ b;
Object? no__int_div(int a, int b) => a / b;
Object? no__double_tdiv(double a, double b) => a ~/ b;
Object? no__double_mod(double a, double b) => a % b;
T no__generic_bound_add<T extends int>(T a, T b) => (a + b) as T;
bool no__generic_bound_lt<T extends int>(T a, T b) => a < b;
int yes__promoted(num a, int b) { if (a is int) { return a + b; } return b; }
int yes__compound(int a, int b) { var x = a; x += b; return x; }
int yes__increment(int a) { var i = a; i++; return i; }
double yes__double_compound(double a, double b) { var x = a; x *= b; return x; }
int yes__nullable_promoted(int? a, int b) { if (a != null) { return a + b; } return b; }
int yes__bang(int? a, int b) => a! + b;
int yes__two_sites(int a, int b, int c) => a + b + c;
num no__mixed_sites(int a, int b, num c) => a + b + c;
num no__mixed_sites_reversed(num c, int a, int b) => c + a + b;
bool yes__loop(int n) { var s = 0; for (var i = 0; i < n; i++) { s += i; } return s > n; }
num no__in_closure(int a, num b) { num g() => a + b; return g(); }
int yes__in_closure(int a, int b) { int g() => a * b; return g(); }
bool no__equals(int a, int b) => a == b;
bool no__not_equals(int a, int b) => a != b;
// END-FUNCTIONS

// `super.` is rewritten by the producer to `$routeBSuper(...) as dynamic`
// (route_b_producer.dart, `_lower`), so an operand derived from one is dynamic
// in the compiled slice whatever it is in the patched kernel. The producer
// refuses a super getter and a super read it cannot lower (expected, marked in
// qualify); a super METHOD call it lowers.
@pragma('vm:entry-point')
class A {
  @pragma('vm:entry-point')
  int get no__super_n => 1;
  @pragma('vm:entry-point')
  int no__super_m() => 2;
  @pragma('vm:entry-point')
  int get no__super_unused => 3;
}

@pragma('vm:entry-point')
class B extends A {
  @override
  @pragma('vm:entry-point')
  int get no__super_n => super.no__super_n + 1;
  @override
  @pragma('vm:entry-point')
  int no__super_m() => (1 + super.no__super_m()) as int;
  @pragma('vm:entry-point')
  int no__super_local() { var x = super.no__super_n; return x + 1; }
  @pragma('vm:entry-point')
  int conservative__super_other_site(int a, int b) { var y = super.no__super_unused; return a + b; }
  @pragma('vm:entry-point')
  int yes__sibling_without_super(int a, int b) => a + b;
}

// An override may OMIT a parameter or return type: Dart takes it from the member
// it overrides. The producer lowers a member to a top-level function, which
// overrides nothing, so it writes the inferred type in (`@override f(a)` over
// `f(int a)` becomes `f(Self self, int a)`); a type it cannot name in the
// replacement library refuses the target (`refused__`).
@pragma('vm:entry-point')
class UA {
  int k = 1;
  @pragma('vm:entry-point')
  Object? yes__untyped_f(int a) => a + 1;
  @pragma('vm:entry-point')
  Object? yes__untyped_g(int a, double d) => a * 2 > 1 ? d * 2.0 : d - d;
  @pragma('vm:entry-point')
  Object? yes__untyped_nullable(int? a) => a! + 1;
  @pragma('vm:entry-point')
  Object? yes__untyped_list(List<int> xs) => xs.length + 1;
  @pragma('vm:entry-point')
  Object? no__untyped_num(num a) => a + 1;
  @pragma('vm:entry-point')
  num yes__untyped_ret(int a) => a - 1;
  @pragma('vm:entry-point')
  int get yes__untyped_getter => k + k;
  @pragma('vm:entry-point')
  Object? refused__untyped_foreign(Point<int> p) => p.x + 1;
}

@pragma('vm:entry-point')
class UB extends UA {
  @override
  @pragma('vm:entry-point')
  Object? yes__untyped_f(a) => a + 1;
  @override
  @pragma('vm:entry-point')
  Object? yes__untyped_g(a, d) => a * 2 > 1 ? d * 2.0 : d - d;
  @override
  @pragma('vm:entry-point')
  Object? yes__untyped_nullable(a) => a! + 1;
  @override
  @pragma('vm:entry-point')
  Object? yes__untyped_list(xs) => xs.length + 1;
  @override
  @pragma('vm:entry-point')
  Object? no__untyped_num(a) => a + 1;
  @override
  yes__untyped_ret(a) => a - 1;
  @override
  @pragma('vm:entry-point')
  get yes__untyped_getter => k + k;
  @override
  @pragma('vm:entry-point')
  Object? refused__untyped_foreign(p) => p.x + 1;
}

// A class type parameter in the receiver: the receiver is written as the raw
// class (`Gen self`), so `T` is its bound there.
@pragma('vm:entry-point')
class Gen<T extends num> {
  Gen(this.t);
  T t;
  int n = 1;
  @pragma('vm:entry-point')
  int yes__gen_int(int a) => a + n;
  @pragma('vm:entry-point')
  num no__gen_t() => t + 1;
}

@pragma('vm:entry-point')
class Box<T> {
  List<T> xs = [];
  @pragma('vm:entry-point')
  int yes__box_len() => xs.length + 1;
}

// A private receiver class is written by name (`_Priv self`) and resolved with
// `--resolve-private-names-in-library`. Only its PUBLIC members are used: the
// fixture tool has no capability manifest, which a private member needs.
@pragma('vm:entry-point')
class _Priv {
  int n = 1;
  @pragma('vm:entry-point')
  int yes__priv_n() => n + n;
  @pragma('vm:entry-point')
  int yes__priv_param(int a) => a + n;
  @pragma('vm:entry-point')
  int no__priv_num(num a) => (a + n).toInt();
}

void main() {
  F();
  B();
  UB();
  Gen<int>(1);
  Box<int>();
  _Priv();
}
