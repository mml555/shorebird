// measure_private_reach.dart -- how much of real Dart can Route B's ABI reach?
//
// WHY THIS EXISTS
//
// PARITY.md's §3 rests on a number: only a few percent of real instance methods
// are free of app-private involvement, so the rung ladder widens a surface
// INSIDE a small slice. That number arrived from two regexes over declaration
// sites, agreeing with each other. Agreement between two regexes is not a
// measurement, and an unreproducible number in a goal document decays into
// folklore -- so this reproduces it from KERNEL, using the same notion of a
// receiver access that the shipping analyzer uses.
//
// WHAT IT COUNTS
//
// Candidates are the shape Route B's entry-point contract can address at all:
// an instance method (not static, not a constructor), no positional or named
// parameters of its own -- because the single allowed entry-point parameter is
// already the receiver -- and not generic. Everything else is out of scope by
// the contract rather than by privacy, and is reported separately so the two
// limits are never conflated.
//
// Each candidate lands in exactly one band:
//
//   addressable      no app-private involvement anywhere. Route B can patch it.
//   privateClass     the ENCLOSING CLASS is private (`_MyHomePageState`).
//   privateRef       the BODY names an app-private member, class or top-level.
//   both             both of the above.
//
// THE NUMBER THAT MATTERS MOST is not any of those four. It is `acceptedThenFails`:
// candidates the shipping analyzer ACCEPTS -- no unsupported reason -- but whose
// private enclosing class the producer then emits verbatim as a parameter type,
// so the patch dies in dart2bytecode. That is a bug's blast radius, not a gap's
// size, and it is the one figure that should be zero.
//
// WHY NOT IMPORT analyze_coverage.dart
//
// It is one of the compiler cell's seven manifest files: importing it would put
// this tool's edits inside the cell's identity, and reading it would tempt
// someone to "fix" the measurement by changing the thing being measured. The
// privacy test here is deliberately simple and stated in one place (`_isPrivate`)
// so a reader can check it against Dart's own rule: a name beginning with `_` is
// private to its declaring LIBRARY.
//
// USAGE
//
//   dart measure_private_reach.dart <component.dill> [--package <filter>]...
//
// `--package` restricts counting to libraries whose URI contains the filter,
// which is how you separate framework code from SDK code. Repeatable. With none,
// every non-`dart:` library is counted.
//
// Output is a table plus a JSON blob, so it can be eyeballed or diffed.

import 'dart:convert';
import 'dart:io';

import 'package:kernel/kernel.dart';

/// Dart privacy is library-scoped, and the spelling is the whole rule: an
/// identifier beginning with `_` is private to the library that declares it.
/// A synthetic replacement library is a DIFFERENT library, so it cannot name
/// one however it is spelled -- `_x`, `this._x` and `self._x` fail alike.
bool _isPrivate(String name) => name.startsWith('_');

/// Every app-private name a body would have to resolve, whatever the syntax.
///
/// Deliberately broader than the receiver-only accesses the analyzer reports:
/// the question here is not "can this be lowered" but "does this body name
/// anything a foreign library cannot see". A private top-level function and a
/// private class constructor are as unreachable as a private field.
class _PrivateNames extends RecursiveVisitor {
  final names = <String>{};

  void _note(String name) {
    if (_isPrivate(name)) names.add(name);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    _note(node.name.text);
    super.visitInstanceGet(node);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    _note(node.name.text);
    super.visitInstanceSet(node);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    _note(node.name.text);
    super.visitInstanceInvocation(node);
  }

  @override
  void visitInstanceTearOff(InstanceTearOff node) {
    _note(node.name.text);
    super.visitInstanceTearOff(node);
  }

  @override
  void visitDynamicGet(DynamicGet node) {
    _note(node.name.text);
    super.visitDynamicGet(node);
  }

  @override
  void visitDynamicSet(DynamicSet node) {
    _note(node.name.text);
    super.visitDynamicSet(node);
  }

  @override
  void visitDynamicInvocation(DynamicInvocation node) {
    _note(node.name.text);
    super.visitDynamicInvocation(node);
  }

  @override
  void visitStaticGet(StaticGet node) {
    _note(node.target.name.text);
    super.visitStaticGet(node);
  }

  @override
  void visitStaticSet(StaticSet node) {
    _note(node.target.name.text);
    super.visitStaticSet(node);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    _note(node.target.name.text);
    // A private CLASS is as unreachable as a private member, and a factory
    // reaches one without ever naming a private member.
    final enclosing = node.target.enclosingClass;
    if (enclosing != null) _note(enclosing.name);
    super.visitStaticInvocation(node);
  }

  @override
  void visitStaticTearOff(StaticTearOff node) {
    _note(node.target.name.text);
    super.visitStaticTearOff(node);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    _note(node.target.enclosingClass.name);
    _note(node.target.name.text);
    super.visitConstructorInvocation(node);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    _note(node.name.text);
    super.visitSuperPropertyGet(node);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    _note(node.name.text);
    super.visitSuperPropertySet(node);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    _note(node.name.text);
    super.visitSuperMethodInvocation(node);
  }
}

/// The entry-point contract's own limits, kept separate from privacy so the two
/// are never blamed for each other. Mirrors `_lowering`'s parameter and generic
/// checks in analyze_coverage.dart -- transcribed, not imported, on purpose.
///
/// The distinction between these reasons is the whole point of reporting them
/// separately: `declares its own parameters` is a *widenable ABI limit* with a
/// known fix shape, `is abstract` is not a patch target at all, and privacy is a
/// different problem from both. Collapsing them into one "unsupported" number is
/// what makes a measurement point at the wrong next goal.
String? _outOfContract(Procedure p) {
  final f = p.function;
  if (f.body == null) return 'abstract';
  if (f.positionalParameters.isNotEmpty || f.namedParameters.isNotEmpty) {
    return 'ownParameters';
  }
  if (f.typeParameters.isNotEmpty) return 'generic';
  return null;
}

/// A mixin application the front end synthesized, e.g.
/// `_AppBarTheme&InheritedTheme&Diagnosticable`. Its name is private only
/// because the CFE composed it from a private constituent, and no developer ever
/// patches one -- counting them as "blocked by a private class" would inflate
/// the privacy bands with methods nobody would ever target.
bool _isSyntheticMixinApplication(Class cls) => cls.name.contains('&');

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: measure_private_reach.dart <component.dill> [--package <filter>]...',
    );
    exit(2);
  }

  final dill = args.first;
  final filters = <String>[];
  // Classify privacy over EVERY concrete method, not only the in-contract ones.
  // Without this the "if we fixed both limits" figure is a projection that
  // assumes the privacy distribution is the same among parameter-declaring
  // methods -- and a projection is exactly what this tool exists to replace.
  var allConcrete = false;
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--all-concrete') {
      allConcrete = true;
    } else if (args[i] == '--package') {
      if (i + 1 >= args.length) {
        stderr.writeln('--package needs a value');
        exit(2);
      }
      filters.add(args[++i]);
    } else {
      stderr.writeln('unknown argument: ${args[i]}');
      exit(2);
    }
  }

  final component = loadComponentFromBinary(dill);

  var addressable = 0;
  var privateClass = 0;
  var privateRef = 0;
  var both = 0;
  var acceptedThenFails = 0;
  var syntheticMixin = 0;
  final outOfContract = <String, int>{
    'abstract': 0,
    'ownParameters': 0,
    'generic': 0,
  };

  final examples = <String, List<String>>{
    'addressable': [],
    'privateClass': [],
    'privateRef': [],
    'both': [],
  };

  for (final library in component.libraries) {
    final uri = library.importUri.toString();
    if (uri.startsWith('dart:')) continue;
    if (filters.isNotEmpty && !filters.any(uri.contains)) continue;

    for (final cls in library.classes) {
      if (_isSyntheticMixinApplication(cls)) {
        syntheticMixin += cls.procedures
            .where((p) => !p.isStatic && p.kind == ProcedureKind.Method)
            .length;
        continue;
      }

      for (final p in cls.procedures) {
        if (p.isStatic) continue;
        if (p.kind != ProcedureKind.Method) continue;

        final contract = _outOfContract(p);
        final inContract = contract == null;
        if (contract != null) {
          outOfContract[contract] = outOfContract[contract]! + 1;
          // `abstract` has no body to classify, and is not a patch target under
          // any future ABI, so it stays out of the privacy count either way.
          if (!allConcrete || contract == 'abstract') continue;
        }

        final visitor = _PrivateNames();
        p.function.accept(visitor);

        final classIsPrivate = _isPrivate(cls.name);
        final bodyNamesPrivate = visitor.names.isNotEmpty;
        final where = '$uri :: ${cls.name}.${p.name.text}';

        if (classIsPrivate && bodyNamesPrivate) {
          both++;
          if (examples['both']!.length < 5) examples['both']!.add(where);
        } else if (classIsPrivate) {
          privateClass++;
          if (examples['privateClass']!.length < 5) {
            examples['privateClass']!.add(where);
          }
          // The analyzer reports no unsupported reason for this method -- the
          // body is clean -- so the CLI accepts it and the producer then emits
          // `_Foo self` into a library that cannot name `_Foo`.
          //
          // Only IN-CONTRACT methods can reach that failure: one with its own
          // parameters is refused earlier, for a different and honest reason. So
          // this counter must not follow --all-concrete, or the bug's blast
          // radius gets inflated by methods the analyzer never accepted.
          if (inContract) acceptedThenFails++;
        } else if (bodyNamesPrivate) {
          privateRef++;
          if (examples['privateRef']!.length < 5) {
            examples['privateRef']!.add(where);
          }
        } else {
          addressable++;
          if (examples['addressable']!.length < 5) {
            examples['addressable']!.add(where);
          }
        }
      }
    }
  }

  final classified = addressable + privateClass + privateRef + both;
  final concrete = allConcrete
      ? classified
      : classified + outOfContract['ownParameters']! + outOfContract['generic']!;
  final candidates = allConcrete
      ? concrete - outOfContract['ownParameters']! - outOfContract['generic']!
      : classified;
  final all = concrete + outOfContract['abstract']!;

  String of(int n, int d) =>
      d == 0 ? '   n/a' : '${(n * 100 / d).toStringAsFixed(1).padLeft(5)} %';

  stdout.writeln('Route B addressable surface, measured from kernel');
  stdout.writeln('  component : $dill');
  stdout.writeln(
    '  libraries : ${filters.isEmpty ? "all non-dart:" : filters.join(", ")}',
  );
  stdout.writeln('');
  stdout.writeln('THE DENOMINATOR, because which one you pick changes the story');
  stdout.writeln('  instance methods, all           : $all');
  stdout.writeln(
    '    abstract / external           : ${outOfContract['abstract']}'
    '   (not patch targets at all)',
  );
  stdout.writeln('  with a body ("concrete")        : $concrete');
  stdout.writeln('  in-contract candidates          : $candidates');
  stdout.writeln(
    '  synthetic mixin applications    : $syntheticMixin'
    '   (excluded: `A&B&C`, nobody patches one)',
  );
  stdout.writeln('');
  stdout.writeln('THE ABI LIMIT — bigger than privacy, and widenable');
  stdout.writeln(
    '  declares its own parameters     ${of(outOfContract['ownParameters']!, concrete)}'
    '  ${outOfContract['ownParameters']}',
  );
  stdout.writeln(
    '  generic                         ${of(outOfContract['generic']!, concrete)}'
    '  ${outOfContract['generic']}',
  );
  stdout.writeln('');
  stdout.writeln(
    'THE PRIVACY LIMIT — share of '
    '${allConcrete ? "ALL ${classified} concrete methods" : "in-contract candidates"}',
  );
  stdout.writeln('  addressable            ${of(addressable, classified)}  $addressable');
  stdout.writeln('  private class only     ${of(privateClass, classified)}  $privateClass');
  stdout.writeln('  private reference only ${of(privateRef, classified)}  $privateRef');
  stdout.writeln('  both                   ${of(both, classified)}  $both');
  stdout.writeln('');
  stdout.writeln('THE BOTTOM LINE');
  if (allConcrete) {
    stdout.writeln(
      '  privacy-clean regardless of the parameter ABI: '
      '${of(addressable, classified)}  ($addressable / $classified)',
    );
    stdout.writeln(
      '  -> this is the ceiling a FULL parameter-ABI widening would reach '
      'while privacy stays unsolved.',
    );
  } else {
    stdout.writeln(
      '  patchable today, of every concrete instance method: '
      '${of(addressable, concrete)}  ($addressable / $concrete)',
    );
    stdout.writeln(
      '  -> and ${of(candidates, concrete)} is the ceiling a FULL privacy fix '
      'would reach while the one-parameter ABI stands.',
    );
  }
  stdout.writeln('');
  stdout.writeln(
    '  ACCEPTED THEN FAILS    ${of(acceptedThenFails, candidates)}  $acceptedThenFails'
    '   <-- analyzer accepts, producer emits a private type, dart2bytecode dies',
  );
  stdout.writeln('     (should be zero; see PARITY.md §3 "two');
  stdout.writeln('      accepted-then-failed holes")');
  stdout.writeln('');
  for (final band in examples.keys) {
    if (examples[band]!.isEmpty) continue;
    stdout.writeln('  e.g. $band:');
    for (final e in examples[band]!) {
      stdout.writeln('    $e');
    }
  }
  stdout.writeln('');
  stdout.writeln('JSON ${jsonEncode({
        'all': all,
        'concrete': concrete,
        'candidates': candidates,
        'syntheticMixin': syntheticMixin,
        'outOfContract': outOfContract,
        'addressable': addressable,
        'privateClass': privateClass,
        'privateRef': privateRef,
        'both': both,
        'acceptedThenFails': acceptedThenFails,
      })}');
}
