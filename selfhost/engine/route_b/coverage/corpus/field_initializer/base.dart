// Case: the only edit is a top-level field's initializer. A patch replaces
// method bodies, and the initializer runs from the release, so the edit cannot
// be carried. Before analysis version 14 only procedures were compared, and
// this read as unchanged: alone it was refused as inert, and alongside other
// edits it was dropped while they shipped.
final routeBStart = DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

void main() => print(routeBStart);
