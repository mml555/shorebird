// Case: an instance member on a class with no subclasses. A precompiler CAN
// devirtualize this, so it is reachable in practice -- but whether it does is a
// per-call-site decision that is NOT in this kernel.
class Greeter {
  @pragma('vm:never-inline')
  String value() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW' : 'X';
}

void main() => print(Greeter().value());
