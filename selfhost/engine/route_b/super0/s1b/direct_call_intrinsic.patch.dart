// The throwaway dart2bytecode change, kept as a readable record of exactly what
// was added for the experiment. Applied by run_1b.sh into
// pkg/dart2bytecode/lib/bytecode_generator.dart's visitStaticInvocation and
// removed again from a checksummed backup by a trap.
//
//     // D-SUPER-1B THROWAWAY EXPERIMENT -- not a product feature.
//     if (target.name.text == 'shorebirdDirectCall') {
//       final libUri = (args.positional[1] as StringLiteral).value;
//       final clsName = (args.positional[2] as StringLiteral).value;
//       final memberName = (args.positional[3] as StringLiteral).value;
//       final lib = component.libraries
//           .firstWhere((l) => l.importUri.toString() == libUri);
//       final cls = lib.classes.firstWhere((c) => c.name == clsName);
//       final exact = cls.procedures.firstWhere((p) => p.name.text == memberName);
//       final noArgs = Arguments(const [])..parent = node;
//       _genArguments(args.positional[0], noArgs);
//       _genDirectCallWithArgs(exact, noArgs,
//           hasReceiver: true, isUnchecked: true, node: node);
//       return;
//     }
//
// Two things it deliberately does NOT do: resolve through the class hierarchy
// (the point is EXACT target selection, so `firstWhere` on the named class is
// correct and a miss must throw), and fall back to a virtual call if anything
// is missing (a fallback would turn a failed experiment into a plausible pass).
