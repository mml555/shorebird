#!/usr/bin/env python3
"""Apply (or revert) the 0015 direct-super intrinsic to dart2bytecode source.

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
    if (args.positional.length != 7 ||
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
    print('0015 applied')


if __name__ == '__main__':
    main()
