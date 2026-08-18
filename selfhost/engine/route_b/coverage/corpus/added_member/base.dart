// Case: the bug this tool's own test caught -- it detected the addition and
// shipped anyway. Note the helper must be CALLED: an unreferenced addition is
// tree-shaken by --aot and never reaches the kernel, so the first version of
// this test detected nothing and read as "additions are fine".
@pragma('vm:never-inline')
String alpha() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-a' : 'X';

void main() => print(alpha());
