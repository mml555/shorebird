// SEMANTIC-MAP-1 adversarial corpus — the BASE program.
//
// Deliberately small and deliberately boring. Every mutant under ../mutants/ is
// this program with exactly ONE dimension changed, so a classification
// disagreement is attributable to that dimension and to nothing else.
library corpus.app;

import 'helper.dart';

class Shape {
  final int sides;
  Shape(this.sides);

  int area(int w, int h) => w * h;

  int get perimeter => sides * 2;
  set scale(int s) => _scaled = s;
  int get scaled => _scaled;
  int _scaled = 1;

  Shape.square() : sides = 4;
  factory Shape.unit() => Shape(1);

  int operator +(Shape other) => sides + other.sides;
}

class Box<S extends Shape> {
  final S value;
  Box(this.value);
  S unwrap() => value;
}

int topLevel(int x) => x + 1;

int _privateHelper(int x) => x * 2;

int usesPrivate(int x) => _privateHelper(x);

int usesOtherLibrary(int x) => helperAdd(x);

/// Entry point. The corpus is compiled as a release program, so it needs one;
/// it references every declaration so nothing is tree-shaken before the map can
/// see it.
void main() {
  final s = Shape(3);
  print(s.area(2, 4));
  print(s.perimeter);
  s.scale = 2;
  print(s.scaled);
  print(Shape.square().sides);
  print(Shape.unit().sides);
  print(s + Shape(1));
  print(Box<Shape>(s).unwrap().sides);
  print(topLevel(1));
  print(usesPrivate(2));
  print(usesOtherLibrary(3));
  print(helperUsesPrivate(4));
}
