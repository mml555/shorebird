// Case: an instance member whose body reads and writes a field in one token,
// `_count += 1`, the shape of a setState counter. One receiver prefix rewrites
// both the read and the write, so it is carried like any instance member.
class Counter {
  int _count = 0;

  @pragma('vm:never-inline')
  int bump() => _count += 10;
}

void main() => print(Counter().bump());
