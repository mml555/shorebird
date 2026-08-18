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
