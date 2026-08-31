// D-SUPER-2B.0 permanent control. ONE specimen that carries all three facts at
// once, which is what makes the source-of-truth choice load-bearing rather than
// documentary:
//
//   SOURCE        super.tag('a', 7)      two arguments
//   IMPORT KERNEL tag(String a, int b)   two parameters, call site passes two
//   AOT KERNEL    tag()                  ZERO, arguments frozen into the callee
//
// Measured in D-SUPER-2A.2: TFA specialises a callee for its call sites. So the
// AOT kernel cannot answer "what did the developer write", and an admission gate
// that asks it will admit a super call with arguments.
class ArgParent {
  @pragma('vm:never-inline')
  String tag(String a, int b) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'ARG-P:$a:$b' : 'X';
}

class ArgChild extends ArgParent {
  @pragma('vm:never-inline')
  @override
  String tag(String a, int b) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'ARG-C' : 'X';

  // THE SITE. Two source arguments; zero in the AOT kernel.
  @pragma('vm:never-inline')
  String target() => super.tag('a', 7);
}

// The shape v1 DOES intend to support, for contrast in the same specimen.
class ZeroParent {
  @pragma('vm:never-inline')
  String plain() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'ZERO-P' : 'X';
}

class ZeroChild extends ZeroParent {
  @pragma('vm:never-inline')
  @override
  String plain() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'ZERO-C' : 'X';

  @pragma('vm:never-inline')
  String target() => super.plain();
}

void main() => print('${ArgChild().target()} | ${ZeroChild().target()}');
