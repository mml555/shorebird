// Canonical text for a Kernel type. Structural, carries nullability and type
// arguments, and contains no source position.
//
// ignore_for_file: implementation_imports
import 'package:kernel/ast.dart';
import 'package:kernel/src/printer.dart' show defaultAstTextStrategy;

String typeText(DartType? t) =>
    t == null ? '<null>' : t.toText(defaultAstTextStrategy);
