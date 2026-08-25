// Enumerate the members of PRIVATE classes in an app's own libraries, split into
// constructors and everything else.
//
// WHY THIS EXISTS. `gen_dynamic_interface.dart` emits a bare `class:` item for
// each private class, and the dynamic interface DEFINES that as "this class and
// its PUBLIC MEMBERS are callable" -- upstream's `_Annotator.visitClass` calls
// `_visitPublicMembers(node.constructors)`, so construction comes along with it
// (measured: `probes/p1_dead_allocatability.sh` C1). Separating the two
// authorities means naming members individually, which means knowing which of a
// private class's members are CONSTRUCTORS. That is a kernel question, and
// guessing from the name is wrong: `_mk` could be a method or a constructor.
//
//   dart dump_private_members.dart <app.dill> <library-uri-prefix>
//
// Prints one line per member:
//
//   <library>|<class>|ctor|<name>       (name is empty for the unnamed one)
//   <library>|<class>|member|<name>
//
// ignore_for_file: implementation_imports
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dump_private_members.dart <app.dill> <uri-prefix>');
    exit(2);
  }
  final component = Component();
  BinaryBuilder(File(args[0]).readAsBytesSync()).readComponent(component);
  final prefix = args[1];

  for (final library in component.libraries) {
    final uri = library.importUri.toString();
    if (!uri.startsWith(prefix)) continue;
    for (final cls in library.classes) {
      if (!cls.name.startsWith('_')) continue;
      for (final c in cls.constructors) {
        stdout.writeln('$uri|${cls.name}|ctor|${c.name.text}');
      }
      // A factory (and a redirecting factory) is a Procedure, not a Constructor,
      // and it is a construction edge all the same -- C4/C5 showed a patch can
      // reach both. Classified as `ctor` so a policy that withholds construction
      // withholds these too, rather than leaking them through the member list.
      for (final p in cls.procedures) {
        if (p.isFactory) {
          stdout.writeln('$uri|${cls.name}|ctor|${p.name.text}');
        } else {
          stdout.writeln('$uri|${cls.name}|member|${_vmName(p)}');
        }
      }
      for (final f in cls.fields) {
        // A FIELD IS NAMED BARE. `library_index.dart` indexes a Field under
        // `member.name.text` and applies the accessor prefixes only to a
        // Procedure, and naming the field covers both directions. Same rule
        // `gen_dynamic_interface.dart` already documents.
        stdout.writeln('$uri|${cls.name}|member|${f.name.text}');
      }
    }
  }
}

/// The name the VM indexes a procedure under.
///
/// Accessors are disambiguated as `get:`/`set:`, and the dynamic interface is
/// matched against THOSE names. Emitting the bare name got a real Flutter app
/// rejected outright:
///
///   A member with disambiguated name '_assetsPatch' was not found in class
///   '_ProbeBodyState' ... Did you mean 'get:_assetsPatch' or 'set:_assetsPatch'?
///
/// The toy fixture has no private accessors, so this appeared only once the
/// measurement moved to a real app -- the same lesson, in the same words, that
/// `gen_dynamic_interface.dart` already carries.
String _vmName(Procedure p) => switch (p.kind) {
  ProcedureKind.Getter => 'get:${p.name.text}',
  ProcedureKind.Setter => 'set:${p.name.text}',
  _ => p.name.text,
};
