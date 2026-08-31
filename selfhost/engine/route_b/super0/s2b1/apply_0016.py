#!/usr/bin/env python3
"""Apply the 0016 direct-super intrinsic: 0015 plus TARGET FINGERPRINT AGREEMENT.

0015 is UNSOUND AS DESIGNED and stays that way. 0016 supersedes it and adds the
check 0015 never had: the target this compiler resolves LOCALLY must be the same
declaration the analyzer authorized, compared as source provenance.

The two sides are independent — the expected tuple comes from the analyzer
reading the PATCHED AOT kernel, the observed one from this compiler resolving in
the kernel it compiles against — and 2A.2 measured that provenance survives that
boundary. Without it, a compiler reading the right body could still resolve a
different semantic target than the one the producer's release-evidence gate
admitted.

Kept as a script rather than a `.patch` because the generator moves between
engine revisions and a context diff would rot; the anchors here are the two
lines the injection actually depends on, and a missing anchor is a hard error
rather than a fuzzy match.
"""
import io, sys

CALL_ANCHOR = """    Arguments args = node.arguments;
    final target = node.target;
"""

CALL_HOOK = """    // Route B (selfhost) 0015: the direct-super intrinsic.
    if (_shorebirdDirectSuper(target)) {
      _genShorebirdDirectSuper(node, args);
      return;
    }
"""

MEMBERS_ANCHOR = "  bool _isPragma(Constant annotation) =>"

MEMBERS = r"""  // ---- Route B (selfhost) 0015 -------------------------------------------
  //
  // Recognised by PRAGMA, not by a magic identifier: a spelling carries no
  // authority and the producer's chosen name must not be the contract.
  bool _shorebirdDirectSuper(Member member) {
    for (final annotation in member.annotations) {
      if (annotation is! ConstantExpression) continue;
      final constant = annotation.constant;
      if (constant is! InstanceConstant ||
          constant.classNode != coreTypes.pragmaClass) {
        continue;
      }
      for (final value in constant.fieldValues.values) {
        if (value is StringConstant &&
            value.value == 'shorebird:direct-super') {
          return true;
        }
      }
    }
    return false;
  }

  Never _superRefusal(String why) =>
      throw 'Route B direct-super intrinsic refused: $why';

  // THE INDEPENDENT BACKSTOP. The intrinsic carries ORIGIN/SITE identity, never
  // an argument count: a count would be the producer asserting its own
  // correctness for this compiler to check against itself. Everything below is
  // established from THIS kernel -- which holds the original, unspecialised
  // body, so the site's real argument count is here and not in the AOT kernel,
  // where TFA has been measured to erase it.
  //
  // No virtual fallback on any path.
  void _genShorebirdDirectSuper(StaticInvocation node, Arguments args) {
    if (args.positional.length != 11 ||
        args.named.isNotEmpty ||
        args.types.isNotEmpty) {
      _superRefusal('malformed intrinsic call');
    }
    String literal(int i) {
      final e = args.positional[i];
      if (e is! StringLiteral) _superRefusal('argument $i is not a literal');
      return e.value;
    }

    final originLibrary = literal(1);
    final originClassName = literal(2);
    final originMemberName = literal(3);
    // ORIGIN MEMBER KIND, and it is load-bearing rather than decorative: a class
    // may hold a method, a getter and a setter of one name, so class + name is
    // not an identity. The analyzer carries it (analysis version 10) and this is
    // the safety-critical consumer, so it resolves on BOTH and has no
    // first-member-with-that-name fallback.
    //
    // The wire value is Kernel's `ProcedureKind.name`, so it is capitalised:
    // `Method`, `Getter`, `Setter`, `Operator`, `Factory`. Consumed exactly as
    // spelled rather than normalised.
    final originMemberKind = literal(4);
    final offsetExpr = args.positional[5];
    if (offsetExpr is! IntLiteral) {
      _superRefusal('site offset is not a literal');
    }
    final siteOffset = offsetExpr.value;
    final memberName = literal(6);
    // 0016: the target the ANALYZER authorized, as source provenance. No
    // canonical owner (AOT mixin deduplication renames it) and no arity (TFA
    // rewrites it).
    final expectedFileUri = literal(7);
    final expectedOffsetExpr = args.positional[8];
    if (expectedOffsetExpr is! IntLiteral) {
      _superRefusal('expected target offset is not a literal');
    }
    final expectedFileOffset = expectedOffsetExpr.value;
    final expectedName = literal(9);
    final expectedKind = literal(10);

    // 1. Only inside a dyn-module replacement entry point: anywhere else there
    //    is no "the receiver", so the arg0 rule would mean nothing.
    //
    //    Asked of the ENCLOSING MEMBER's own pragma rather than compared against
    //    `dynModuleEntryPoint`. That field is populated on the DECLARATION path,
    //    which does not necessarily run before a body is generated -- the first
    //    version of this check compared against it and refused every arm,
    //    including the two that should have passed. The pragma is the property
    //    actually wanted and it does not depend on emission order.
    final enclosing = enclosingMember;
    if (enclosing == null ||
        pragmaParser
            .parsedPragmas<ParsedDynModuleEntryPointPragma>(
                enclosing.annotations)
            .isEmpty) {
      _superRefusal('used outside the dynamic-module entry point');
    }

    // 2. The receiver must be EXACTLY positional parameter 0 of the ENTRY POINT
    //    ITSELF. `isUnchecked` below asks the runtime not to verify it; what
    //    justifies that is the replacement ABI -- the original call site invoked
    //    the method being replaced, so argument 0 is that method's own receiver.
    //    An arbitrary expression has no such provenance even with a compatible
    //    type, and neither does a closure's parameter that merely sits in
    //    position 0 of some inner function.
    final fn = enclosingFunction;
    if (fn == null || fn != enclosing.function) {
      _superRefusal('not directly in the entry point body');
    }
    if (fn.positionalParameters.isEmpty) {
      _superRefusal('entry point takes no receiver parameter');
    }
    final receiver = args.positional[0];
    if (receiver is! VariableGet ||
        receiver.variable != fn.positionalParameters.first) {
      _superRefusal('receiver is not parameter 0 of the entry point');
    }

    // 3. Rediscover the ORIGINAL site in this kernel.
    Library? lib;
    for (final l in allLibraries) {
      if (l.importUri.toString() == originLibrary) {
        lib = l;
        break;
      }
    }
    if (lib == null) _superRefusal('origin library not in the import kernel');
    Class? cls;
    for (final c in lib.classes) {
      if (c.name == originClassName) {
        cls = c;
        break;
      }
    }
    if (cls == null) _superRefusal('origin class not in the import kernel');
    Procedure? origin;
    for (final p in cls.procedures) {
      if (p.name.text == originMemberName && p.kind.name == originMemberKind) {
        origin = p;
        break;
      }
    }
    if (origin == null) {
      _superRefusal('no $originMemberKind named $originMemberName in '
          '$originClassName in the import kernel');
    }

    final finder = ShorebirdSuperSiteAt(siteOffset);
    origin.function.accept(finder);
    final site = finder.found;
    if (site == null) {
      _superRefusal('no super invocation at offset $siteOffset in '
          '$originClassName.$originMemberName');
    }
    // Two sites sharing an offset would make the offset not an identity.
    if (finder.count != 1) {
      _superRefusal('${finder.count} super invocations share offset $siteOffset');
    }
    if (site.name.text != memberName) {
      _superRefusal('site at $siteOffset invokes ${site.name.text}, '
          'not $memberName');
    }

    // 4. INDEPENDENT shape check, from the unspecialised body.
    final siteArgs = site.arguments;
    if (siteArgs.positional.isNotEmpty ||
        siteArgs.named.isNotEmpty ||
        siteArgs.types.isNotEmpty) {
      _superRefusal('super.$memberName takes arguments '
          '(${siteArgs.positional.length} positional, '
          '${siteArgs.named.length} named, ${siteArgs.types.length} type)');
    }

    // 5. Resolve locally, with this kernel's own hierarchy.
    final superclass = cls.superclass;
    if (superclass == null) _superRefusal('origin class has no superclass');
    final resolved = hierarchy.getDispatchTarget(
      superclass,
      Name(memberName, memberName.startsWith('_') ? lib : null),
    );
    if (resolved is! Procedure) {
      _superRefusal('no dispatch target for $memberName above $originClassName');
    }

    // 0016 -- TARGET FINGERPRINT AGREEMENT. The check 0015 never had.
    //
    // Resolving *some* target with the right member name is not enough: the
    // producer's release-evidence gate admitted one specific declaration, and
    // this compiler must have arrived at that same declaration independently.
    // Compared as source provenance, which is the only identity that survives
    // the AOT/no-AOT boundary and mixin deduplication (2A / 2A.2).
    final observed = <Object>[
      resolved.fileUri.toString(),
      resolved.fileOffset,
      resolved.name.text,
      resolved.kind.name,
    ].join('|');
    final expected = <Object>[
      expectedFileUri,
      expectedFileOffset,
      expectedName,
      expectedKind,
    ].join('|');
    if (observed != expected) {
      _superRefusal('the locally resolved super target does not match the one '
          'the analysis authorized\n      expected $expected\n      observed '
          '$observed');
    }

    // HARNESS DIAGNOSTIC. What was rediscovered and what was selected, so a probe
    // can observe the intermediate steps instead of inferring them from the
    // final value. Throwaway, like the rest of 0015.
    print('ROUTE_B_SUPER: rediscovered site=$siteOffset member=$memberName '
        'in $originClassName.$originMemberName');
    print('ROUTE_B_SUPER: selected '
        '${resolved.fileUri}|${resolved.fileOffset}|${resolved.name.text}'
        '|${resolved.kind.name} owner=${resolved.enclosingClass?.name}');
    print('ROUTE_B_SUPER: emitting receiver-taking direct call');

    final noArgs = Arguments(const <Expression>[])..parent = node;
    _genArguments(receiver, noArgs);
    _genDirectCallWithArgs(resolved, noArgs,
        hasReceiver: true, isUnchecked: true, node: node);
  }
  // ---- end Route B 0015 --------------------------------------------------

"""

CLASS_TAIL = r"""

/// Route B (selfhost) 0015: the super invocation at one exact file offset.
///
/// [count] matters: if two sites share an offset it is not an identity, and
/// picking either would be a guess.
class ShorebirdSuperSiteAt extends RecursiveVisitor {
  ShorebirdSuperSiteAt(this.offset);
  final int offset;
  SuperMethodInvocation? found;
  int count = 0;

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    if (node.fileOffset == offset) {
      found ??= node;
      count++;
    }
    node.visitChildren(this);
  }
}
"""


def main():
    path = sys.argv[1]
    s = io.open(path, encoding='utf-8').read()
    if '_shorebirdDirectSuper' in s:
        print('already applied')
        return
    for anchor in (CALL_ANCHOR, MEMBERS_ANCHOR):
        if s.count(anchor) != 1:
            raise SystemExit(
                'anchor not unique (%d) -- refusing to patch blindly: %r'
                % (s.count(anchor), anchor[:48]))
    s = s.replace(CALL_ANCHOR, CALL_ANCHOR + CALL_HOOK, 1)
    s = s.replace(MEMBERS_ANCHOR, MEMBERS + MEMBERS_ANCHOR, 1)
    s = s + CLASS_TAIL
    io.open(path, 'w', encoding='utf-8').write(s)
    print('0016 applied')


if __name__ == '__main__':
    main()
