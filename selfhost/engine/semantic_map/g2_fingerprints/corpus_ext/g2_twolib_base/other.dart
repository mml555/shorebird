library corpus.other;

import 'app.dart';

/// A SECOND class also called Box, in a different library, with its own bound.
/// If the owner-ABI table is keyed by bare class name these two overwrite each
/// other and a member gets the wrong owner contract.
class Box<T extends Shape> {
  final T value;
  Box(this.value);
  T unwrap() => value;
}

int useOtherBox(Shape s) => 1;
