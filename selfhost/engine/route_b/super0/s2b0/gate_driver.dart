// Runs the SHIPPING source gate — `routeBSuperCallArgs` from shorebird_cli — so
// the harness measures the product's own decision rather than a restatement of
// it.
//
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:shorebird_cli/src/route_b_super_source.dart';

void main(List<String> args) {
  final source = File(args[0]).readAsStringSync();
  final offset = int.parse(args[1]);
  final member = args[2];
  print(routeBSuperCallArgs(source: source, offset: offset, member: member).name);
}
