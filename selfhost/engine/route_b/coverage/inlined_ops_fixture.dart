// Fixture for inlined_ops_qualify.dart: one function per call-site shape, named
// `<expectation>__<what>`. `yes__` means dart2bytecode turns every operator site
// in the body into an opcode (analysis version 20 marks the reference
// `inlined`); `no__` means at least one site is a real interface call.
// Constant operands are avoided on purpose: `1 + 2` is folded before any
// compiler looks at it.
// ignore_for_file: unused_element, unnecessary_non_null_assertion, unused_local_variable
// cspell:words shl shr

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
Object? no__int_double_add(int a, double b) => a + b;
Object? no__double_int_add(double a, int b) => a + b;
Object? no__int_num_add(int a, num b) => a + b;
Object? no__nullable_int_add(int? a, int b) => a! + b;
Object? no__num_mul(num a, num b) => a * b;
Object? no__int_double_mul(int a, double b) => a * b;
Object? no__double_int_mul(double a, int b) => a * b;
Object? no__int_num_mul(int a, num b) => a * b;
Object? no__nullable_int_mul(int? a, int b) => a! * b;
Object? no__num_lt(num a, num b) => a < b;
Object? no__int_double_lt(int a, double b) => a < b;
Object? no__double_int_lt(double a, int b) => a < b;
Object? no__int_num_lt(int a, num b) => a < b;
Object? no__nullable_int_lt(int? a, int b) => a! < b;
Object? no__num_ge(num a, num b) => a >= b;
Object? no__int_double_ge(int a, double b) => a >= b;
Object? no__double_int_ge(double a, int b) => a >= b;
Object? no__int_num_ge(int a, num b) => a >= b;
Object? no__nullable_int_ge(int? a, int b) => a! >= b;
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
bool yes__explicit_dot_eq(int a, int b) => a.==(b);
bool no__equals(int a, int b) => a == b;
bool no__not_equals(int a, int b) => a != b;
void main() {}
