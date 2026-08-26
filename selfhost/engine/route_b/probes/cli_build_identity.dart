// Copyright (c) 2026, the Shorebird self-host fork.
//
// cli_build_identity.dart -- what the PRODUCT's own build-configuration
// comparison says about two invocations.
//
// Nothing here reimplements the comparison. It constructs `RouteBBuildConfig`
// exactly as `ios_releaser` does and asks `agreesWith`, so the answer printed
// is the answer the product would reach. Used by the P5 matrix to separate
// "G4.1 already refuses this" from "this slips through".
//
//   cli_build_identity.dart '<argsA>' '<argsB>' [flavorA] [flavorB]
//
// args are space-separated build arguments as a user would pass them.
//
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'package:shorebird_cli/src/route_b_build_config.dart';

void main(List<String> args) {
  final a = _config(args[0], args.length > 2 ? args[2] : null);
  final b = _config(args[1], args.length > 3 ? args[3] : null);
  print('A canonical  : ${a.canonicalForm}');
  print('B canonical  : ${b.canonicalForm}');
  print('A fingerprint: ${a.fingerprint}');
  print('B fingerprint: ${b.fingerprint}');
  print('agree        : ${a.agreesWith(b)}');
  if (!a.agreesWith(b)) {
    print('difference   :');
    for (final line in a.describeDifference(b).split('\n')) {
      if (line.trim().isNotEmpty) print('  $line');
    }
  }
}

RouteBBuildConfig _config(String argString, String? flavor) {
  final args = argString.trim().isEmpty ? <String>[] : argString.split(' ');
  final config = RouteBBuildConfig.fromBuildArgs(args, flavor: flavor);
  if (config == null) {
    // Null means the effective configuration could not be established -- which
    // is a fact worth printing, not one to paper over with a default.
    print('UNFINGERPRINTABLE: $argString');
    throw StateError('build configuration could not be established');
  }
  return config;
}
