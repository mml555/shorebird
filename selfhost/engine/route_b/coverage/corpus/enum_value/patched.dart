// Case: an enum value's constructor argument edited. Enum values are
// constants, and a constant prints inline in every body that uses it, so the
// body reading it reads as changed and is patched; the new value reaches the
// device through that body. This pins today's printing: if constants stopped
// printing inline, this edit would read as unchanged and run the old value.
enum Level {
  low(5),
  high(2);

  const Level(this.weight);
  final int weight;
}

@pragma('vm:never-inline')
int weightAt(int i) => Level.values[i].weight;

void main() => print(weightAt(int.parse('0')));
