// E2 -- mark the ACTUAL synthetic mixin-application Procedure as an entry point,
// in the release Kernel, after the frontend and before gen_snapshot.
//
// E1 put `@pragma('vm:entry-point')` on the mixin's own `close` and the release
// still aborted: the pragma does not propagate to the clone
// (`_Leaf&Base&Ticker.close`) that `getDispatchTarget` actually selects. This
// asks whether marking the clone itself is enough -- which would be the cheap
// lever, against E3's synthetic root.
//
// The pragma constant is not synthesised. It is LIFTED from a procedure that
// already carries one, so the annotation is byte-identical to a real
// `vm:entry-point` rather than a hand-built lookalike.
//
// Throwaway release-side transform. ignore_for_file: avoid_print
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/binary/ast_to_binary.dart';
import 'package:vm/metadata/closure_id.dart';
import 'package:vm/metadata/direct_call.dart';
import 'package:vm/metadata/inferred_type.dart';
import 'package:vm/metadata/loading_units.dart';
import 'package:vm/metadata/obfuscation_prohibitions.dart';
import 'package:vm/metadata/procedure_attributes.dart';
import 'package:vm/metadata/table_selector.dart';
import 'package:vm/metadata/unboxing_info.dart';
import 'package:vm/metadata/unreachable.dart';

void main(List<String> args) {
  final path = args[0];
  final classSubstring = args[1];
  final memberName = args[2];

  final component = Component();
  // EVERY metadata repository must be registered BEFORE reading, or the
  // round-trip silently drops what it did not know how to read. The first
  // version of this transform registered none, and gen_snapshot then died with
  // "Missing table selector metadata! Probably gen_kernel was run in non-AOT
  // mode or without TFA" -- a message that blames the frontend for damage this
  // tool did. Losing AOT metadata is not an acceptable side effect of adding an
  // annotation.
  for (final repository in <MetadataRepository<Object?>>[
    ClosureIdMetadataRepository(),
    DirectCallMetadataRepository(),
    InferredTypeMetadataRepository(),
    InferredArgTypeMetadataRepository(),
    InferredReturnTypeMetadataRepository(),
    LoadingUnitsMetadataRepository(),
    ObfuscationProhibitionsMetadataRepository(),
    ProcedureAttributesMetadataRepository(),
    TableSelectorMetadataRepository(),
    UnboxingInfoMetadataRepository(),
    UnreachableNodeMetadataRepository(),
  ]) {
    component.addMetadataRepository(repository);
  }
  BinaryBuilder(File(path).readAsBytesSync()).readComponent(component);

  Expression? donor;
  for (final lib in component.libraries) {
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        donor ??= _entryPointAnnotation(p);
      }
    }
    for (final p in lib.procedures) {
      donor ??= _entryPointAnnotation(p);
    }
  }
  if (donor == null) {
    stderr.writeln('E2: no vm:entry-point annotation to lift');
    exit(2);
  }

  var marked = 0;
  for (final lib in component.libraries) {
    for (final cls in lib.classes) {
      if (!cls.name.contains(classSubstring)) continue;
      for (final p in cls.procedures) {
        if (p.name.text != memberName) continue;
        p.addAnnotation(donor);
        marked++;
        print('E2: marked ${cls.name}.${p.name.text}');
      }
    }
  }
  if (marked == 0) {
    stderr.writeln('E2: nothing matched $classSubstring.$memberName -- the '
        'transform must not silently do nothing');
    exit(2);
  }

  final sink = File(path).openWrite();
  BinaryPrinter(sink).writeComponentFile(component);
  sink.close();
}

Expression? _entryPointAnnotation(Procedure p) {
  for (final a in p.annotations) {
    if (a is! ConstantExpression) continue;
    final c = a.constant;
    if (c is! InstanceConstant) continue;
    for (final v in c.fieldValues.values) {
      if (v is StringConstant && v.value == 'vm:entry-point') {
        return ConstantExpression(c, a.type);
      }
    }
  }
  return null;
}
