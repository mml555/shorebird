// Case: two initializers with side effects swap places. The constructor runs
// them in order, the release keeps its own order, and nothing else changed.
// Both fields are read, so no tree shaking is involved; with one of them
// unread, its initializer survives as a nameless local in the same place, and
// the order is still compared.
int routeBLog(String s) {
  print(s);
  return s.length;
}

class Pair {
  Pair() : second = routeBLog('two'), first = routeBLog('OLD');
  final int first;
  final int second;

  @pragma('vm:never-inline')
  int value() => first + second;
}

void main() => print(Pair().value());
