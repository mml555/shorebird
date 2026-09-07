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

  int area(int w, {required int h}) => w * h;

  int get perimeter => sides * 2;
  set scale(int s) => _scaled = s;
  int get scaled => _scaled;
  int _scaled = 1;

  Shape.square() : sides = 4;
  factory Shape.unit() => Shape(1);

  int operator +(Shape other) => sides + other.sides;
}

class Box<T extends Shape> {
  final T value;
  Box(this.value);
  T unwrap() => value;
}

int topLevel(int x) => x + 1;

int _privateHelper(int x) => x * 2;

int usesPrivate(int x) => _privateHelper(x);

int usesOtherLibrary(int x) => helperAdd(x);
