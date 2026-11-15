// The call-form inventory.
//
// ROUTE_B.md's design decision is to make ONE call form patchable, prove it end
// to end, and only then "inventory the call forms and expand on purpose". This
// is that inventory. It is a measuring instrument, not a feature: each case
// exercises a different AOT dispatch path, and the run reports which ones a
// patch can reach.
//
// Every target is vm:never-inline (otherwise the body is spliced into the
// caller and nothing can change it) and vm:entry-point (AOT drops library
// dictionaries, and the gate's attach native resolves targets by name). Both
// are harness scaffolding: a real linker works from the snapshot's tables.
//
// Every body routes its value through DateTime.now() rather than returning a
// literal. A literal is constant-folded by the type-flow analysis even under
// vm:never-inline -- the call still executes, its result is simply replaced at
// the call site -- and that made an earlier run of the kill gate report a
// working mechanism as OLD. See selfhost/engine/killgate/target.dart.
//
// cspell:words devirtualize devirtualized megamorphic
// ignore_for_file: implementation_imports, avoid_dynamic_calls
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

String _old(String tag) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-$tag' : 'X';

// --- 1. top-level static: the form step 1 already covers ---------------------
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String topLevelStatic() => _old('topLevelStatic');

class Holder {
  // --- 2. static method on a class -- also a static call, different owner ----
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  static String staticMethod() => _old('staticMethod');

  // --- 3. instance method, monomorphic ---------------------------------------
  // Only one receiver class ever reaches this site, so AOT can devirtualize it.
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  String monomorphic() => _old('monomorphic');

  // --- 4. instance getter ----------------------------------------------------
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  String get getter => _old('getter');
}

// --- 5/6. instance method, polymorphic ---------------------------------------
// Two implementations behind one call site. AOT emits either a cid-check chain
// (EmitTestAndCall) or a dispatch-table call, and those are DIFFERENT dispatch
// mechanisms with different patchability -- which is the point of having both.
abstract class Shape {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  String describe();
}

class Circle extends Shape {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String describe() => _old('Circle.describe');
}

class Square extends Shape {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String describe() => _old('Square.describe');
}

// --- 7. instance method, megamorphic -----------------------------------------
// Eight implementations behind ONE call site, which is the shape the framework
// gives every Widget.build and State.initState: too many receivers for a
// cid-check chain, so AOT emits a dispatch-table call or, when the selector has
// no table slot (--route_b_untabled_overrides), a switchable call that the
// runtime links on first use. Part3 is called through that site FIRST, so the
// site's very first link targets the patched function -- the path that would
// link monomorphic straight to the InterpretCall stub if nothing stopped it.
abstract class Part {
  String render();
}

class Part0 extends Part {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String render() => _old('Part0.render');
}

class Part1 extends Part {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String render() => _old('Part1.render');
}

class Part2 extends Part {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String render() => _old('Part2.render');
}

class Part3 extends Part {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String render() => _old('Part3.render');
}

class Part4 extends Part {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String render() => _old('Part4.render');
}

class Part5 extends Part {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String render() => _old('Part5.render');
}

class Part6 extends Part {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String render() => _old('Part6.render');
}

class Part7 extends Part {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  String render() => _old('Part7.render');
}

// The single call site every Part reaches.
@pragma('vm:never-inline')
String renderPart(Part part) => part.render();

// --- the same shape without vm:entry-point on the method ----------------------
// A real build() carries no pragma, and the pragma is not inert: TFA gives an
// entry point the stack calling convention because it can be called
// dynamically. An untabled method without it once took its receiver in a
// register that a switchable call never fills (NoSuchMethodError on an int
// receiver), and every Part case above passed regardless. Only the CLASS is an
// entry point here, so the attach native can still find it by name.
abstract class Tile {
  String paint();
}

@pragma('vm:entry-point')
class Tile0 extends Tile {
  @pragma('vm:never-inline')
  @override
  String paint() => _old('Tile0.paint');
}

@pragma('vm:entry-point')
class Tile1 extends Tile {
  @pragma('vm:never-inline')
  @override
  String paint() => _old('Tile1.paint');
}

@pragma('vm:entry-point')
class Tile2 extends Tile {
  @pragma('vm:never-inline')
  @override
  String paint() => _old('Tile2.paint');
}

@pragma('vm:entry-point')
class Tile3 extends Tile {
  @pragma('vm:never-inline')
  @override
  String paint() => _old('Tile3.paint');
}

@pragma('vm:entry-point')
class Tile4 extends Tile {
  @pragma('vm:never-inline')
  @override
  String paint() => _old('Tile4.paint');
}

@pragma('vm:entry-point')
class Tile5 extends Tile {
  @pragma('vm:never-inline')
  @override
  String paint() => _old('Tile5.paint');
}

@pragma('vm:entry-point')
class Tile6 extends Tile {
  @pragma('vm:never-inline')
  @override
  String paint() => _old('Tile6.paint');
}

@pragma('vm:entry-point')
class Tile7 extends Tile {
  @pragma('vm:never-inline')
  @override
  String paint() => _old('Tile7.paint');
}

@pragma('vm:never-inline')
String paintTile(Tile tile) => tile.paint();

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: inventory <bytecode> <libraryUri> <target>');
    exitCode = 2;
    return;
  }
  final bytes = File(args[0]).readAsBytesSync();
  final libraryUri = args[1];
  final targetName = args[2];

  final ok = attachBytecodeToFunction(
    Uint8List.fromList(bytes),
    libraryUri,
    targetName,
  );
  stdout.writeln('attach[$targetName]: $ok');

  final holder = Holder();
  // Both subclasses are constructed so neither call site can be devirtualized
  // away by the precompiler noticing only one implementation exists.
  final shapes = <Shape>[Circle(), Square()];

  // One line per form. The runner greps these, so the prefix is a contract.
  _report('topLevelStatic', topLevelStatic());
  _report('staticMethod', Holder.staticMethod());
  _report('monomorphic', holder.monomorphic());
  _report('getter', holder.getter);
  _report('polymorphic-first', shapes[0].describe());
  _report('polymorphic-second', shapes[1].describe());

  // Same method, reached dynamically. This is NOT redundant with the two lines
  // above: a statically-typed polymorphic call is specialized into a
  // dispatch-table call, which loads a raw entry point out of a data table and
  // never touches the Function. A dynamic call cannot be, so it goes through
  // the megamorphic/switchable path -- whose stub loads FUNCTION_REG and
  // branches through Function.entry_point_ on its own. If those two lines
  // disagree, that difference IS the finding.
  _report('dynamic-instance', (shapes[0] as dynamic).describe() as String);

  final parts = <Part>[
    Part0(), Part1(), Part2(), Part3(), Part4(), Part5(), Part6(), Part7(), //
  ];
  _report('megamorphic-first', renderPart(parts[3]));
  // Drive the site through every receiver so it ends up megamorphic, then ask
  // again: the patched target must still be reached and the others must not.
  for (var round = 0; round < 3; round++) {
    for (final part in parts) {
      renderPart(part);
    }
  }
  _report('megamorphic-late', renderPart(parts[3]));
  _report('megamorphic-other', renderPart(parts[5]));

  final tiles = <Tile>[
    Tile0(), Tile1(), Tile2(), Tile3(), Tile4(), Tile5(), Tile6(), Tile7(), //
  ];
  _report('noentry-first', paintTile(tiles[3]));
  for (var round = 0; round < 3; round++) {
    for (final tile in tiles) {
      paintTile(tile);
    }
  }
  _report('noentry-late', paintTile(tiles[3]));
  _report('noentry-other', paintTile(tiles[5]));

  // Tear-off and dynamic shapes, for continuity with the kill gate.
  final String Function() torn = topLevelStatic;
  _report('tear-off', torn());
  _report('dynamic', (topLevelStatic as dynamic)() as String);
}

void _report(String form, String value) {
  // "not OLD-" rather than "== NEW": the replacement body's return value is
  // supplied by whoever runs this, and pinning one literal is what made the
  // kill gate misreport a working mechanism.
  final patched = !value.startsWith('OLD-');
  stdout.writeln('FORM $form: ${patched ? "PATCHED" : "original"} ($value)');
}
