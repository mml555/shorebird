#!/usr/bin/env python3
"""Apply 0017: the DUAL-KERNEL direct-super intrinsic.

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
import io, os, sys

CALL_ANCHOR = """    Arguments args = node.arguments;
    final target = node.target;
"""

CALL_HOOK = """    // Route B (selfhost) 0015: the direct-super intrinsic.
    if (_shorebirdDirectSuper(target)) {
      _genShorebirdDirectSuper(node, args);
      return;
    }
"""

VERIFIER_GLOBALS = r'''
// ---- Route B (selfhost) 0017: the patched VERIFICATION component -----------
//
// A file-level global rather than a constructor parameter, because this is an
// experimental patch series applied by a script and threading a new required
// argument through every construction site would be a larger edit than the
// feature. A product version belongs in the constructor.
//
// NEVER merged into `allLibraries`. This component is read to verify what the
// PATCH says; nothing in it may be named by emitted bytecode.
String? shorebirdPatchedVerificationDill;
String? shorebirdPlatformDillForVerification;

ast.Component? _shorebirdVerifyComponent;
ClassHierarchy? _shorebirdVerifyHierarchy;

void _shorebirdLoadVerifier() {
  if (_shorebirdVerifyComponent != null) return;
  final path = shorebirdPatchedVerificationDill;
  if (path == null) {
    throw 'Route B direct-super intrinsic refused: no '
        '--patched-verification-dill was supplied, so the patched body cannot '
        'be verified';
  }
  final component = ast.Component();
  // The platform first: a --no-aot --no-link-platform kernel has no dart:core
  // and ClassHierarchy cannot be built without it.
  final platform = shorebirdPlatformDillForVerification;
  if (platform != null) {
    BinaryBuilder(File(platform).readAsBytesSync()).readComponent(component);
  }
  BinaryBuilder(File(path).readAsBytesSync()).readComponent(component);
  _shorebirdVerifyComponent = component;
  _shorebirdVerifyHierarchy =
      ClassHierarchy(component, CoreTypes(component));
}
'''

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

    // ---- 3. VERIFICATION UNIVERSE: the PATCHED body -----------------------
    //
    // Site identity is used HERE and only here. The release side below is found
    // structurally, never by offset.
    _shorebirdLoadVerifier();
    final verifyComponent = _shorebirdVerifyComponent!;
    final verifyHierarchy = _shorebirdVerifyHierarchy!;

    Library? vLib;
    for (final l in verifyComponent.libraries) {
      if (l.importUri.toString() == originLibrary) {
        vLib = l;
        break;
      }
    }
    if (vLib == null) {
      _superRefusal('origin library not in the patched verification kernel');
    }
    Class? vCls;
    for (final c in vLib.classes) {
      if (c.name == originClassName) {
        vCls = c;
        break;
      }
    }
    if (vCls == null) {
      _superRefusal('origin class not in the patched verification kernel');
    }
    Procedure? vOrigin;
    for (final p in vCls.procedures) {
      if (p.name.text == originMemberName && p.kind.name == originMemberKind) {
        vOrigin = p;
        break;
      }
    }
    if (vOrigin == null) {
      _superRefusal('no $originMemberKind named $originMemberName in '
          '$originClassName in the patched verification kernel');
    }

    final finder = ShorebirdSuperSiteAt(siteOffset);
    vOrigin.function.accept(finder);
    final site = finder.found;
    if (site == null) {
      _superRefusal('no super invocation at offset $siteOffset in '
          '$originClassName.$originMemberName (patched kernel)');
    }
    if (finder.count != 1) {
      _superRefusal('${finder.count} super invocations share offset $siteOffset');
    }
    if (site.name.text != memberName) {
      _superRefusal('site at $siteOffset invokes ${site.name.text}, '
          'not $memberName');
    }
    // The shape check, read from the PATCHED body -- the only body that is the
    // one being lowered. TFA rewrites arguments away in the AOT kernel and the
    // release body is a different source version entirely.
    final siteArgs = site.arguments;
    if (siteArgs.positional.isNotEmpty ||
        siteArgs.named.isNotEmpty ||
        siteArgs.types.isNotEmpty) {
      _superRefusal('super.$memberName takes arguments '
          '(${siteArgs.positional.length} positional, '
          '${siteArgs.named.length} named, ${siteArgs.types.length} type)');
    }

    final vSuper = vCls.superclass;
    if (vSuper == null) {
      _superRefusal('origin class has no superclass in the patched kernel');
    }
    final vResolved = verifyHierarchy.getDispatchTarget(
      vSuper,
      Name(memberName, memberName.startsWith('_') ? vLib : null),
    );
    if (vResolved is! Procedure) {
      _superRefusal('no dispatch target for $memberName above $originClassName '
          'in the patched kernel');
    }

    final expected = <Object>[
      expectedFileUri,
      expectedFileOffset,
      expectedName,
      expectedKind,
    ].join('|');
    String print4(Procedure m) => <Object>[
      m.fileUri.toString(),
      m.fileOffset,
      m.name.text,
      m.kind.name,
    ].join('|');
    final patchedFingerprint = print4(vResolved);
    if (patchedFingerprint != expected) {
      _superRefusal('the PATCHED kernel resolves a different super target than '
          'the analysis authorized\n      expected $expected\n      patched  '
          '$patchedFingerprint');
    }

    // ---- 4. BINDING UNIVERSE: the RELEASE import kernel -------------------
    //
    // STRUCTURAL, never by offset: origin class + super member through the
    // release hierarchy. Requiring a release super call at the patched site's
    // offset is the cross-version dependency 2B.1c-SITE exists to kill.
    Library? rLib;
    for (final l in allLibraries) {
      if (l.importUri.toString() == originLibrary) {
        rLib = l;
        break;
      }
    }
    if (rLib == null) _superRefusal('origin library not in the release kernel');
    Class? rCls;
    for (final c in rLib.classes) {
      if (c.name == originClassName) {
        rCls = c;
        break;
      }
    }
    if (rCls == null) _superRefusal('origin class not in the release kernel');
    final rSuper = rCls.superclass;
    if (rSuper == null) {
      _superRefusal('origin class has no superclass in the release kernel');
    }
    final resolved = hierarchy.getDispatchTarget(
      rSuper,
      Name(memberName, memberName.startsWith('_') ? rLib : null),
    );
    if (resolved is! Procedure) {
      _superRefusal('no dispatch target for $memberName above $originClassName '
          'in the release kernel');
    }
    final releaseFingerprint = print4(resolved);
    if (releaseFingerprint != expected) {
      // Verification success must not authorize an unrelated release Procedure.
      _superRefusal('the RELEASE kernel resolves a different super target than '
          'the analysis authorized\n      expected $expected\n      release  '
          '$releaseFingerprint');
    }

    // HARNESS DIAGNOSTIC. What was rediscovered and what was selected, so a probe
    // can observe the intermediate steps instead of inferring them from the
    // final value. Throwaway, like the rest of 0015.
    print('ROUTE_B_SUPER: rediscovered site=$siteOffset member=$memberName '
        'in $originClassName.$originMemberName');
    print('ROUTE_B_SUPER: patched verifier agrees  $patchedFingerprint');
    print('ROUTE_B_SUPER: release binder  agrees  $releaseFingerprint');
    print('ROUTE_B_SUPER: binding to RELEASE procedure owner='
        '${resolved.enclosingClass?.name}');
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


IMPORTS = (
    "import 'dart:io' show File;\n\n"
    "import 'package:kernel/binary/ast_from_binary.dart' show BinaryBuilder;\n"
)
IMPORTS_ANCHOR = "import 'package:vm/transformations/pragma.dart';"

DRIVER_OPTION = (
    "\n  // Route B (selfhost) 0017. VERIFICATION ONLY: never merged into the\n"
    "  // binding universe. --import-dill stays the shipped program the\n"
    "  // replacement binds against.\n"
    "  ..addOption(\n"
    "    'patched-verification-dill',\n"
    "    help: 'Path to a --no-aot kernel of the PATCHED sources, used only '\n"
    "        'to verify direct-super sites',\n"
    "  )"
)


def patch_driver(path):
    s = io.open(path, encoding='utf-8').read()
    if 'patched-verification-dill' in s:
        print('  driver already patched')
        return
    anchor = "  ..addOption('depfile', help: 'Path to output Ninja depfile')"
    if s.count(anchor) != 1:
        raise SystemExit('driver option anchor not unique (%d)' % s.count(anchor))
    s = s.replace(anchor, anchor + DRIVER_OPTION, 1)
    # Set where `options` is IN SCOPE. `generateBytecode` is called from a
    # different function that receives explicit parameters, so the obvious
    # insertion point does not compile.
    seat = "  final String? platformKernel = options['platform'];"
    if s.count(seat) != 1:
        raise SystemExit('option seat not unique (%d)' % s.count(seat))
    s = s.replace(seat, seat + "\n"
                  "  bg.shorebirdPatchedVerificationDill =\n"
                  "      options['patched-verification-dill'];\n"
                  "  bg.shorebirdPlatformDillForVerification = platformKernel;",
                  1)
    s = s.replace("import 'bytecode_generator.dart' show generateBytecode;",
                  "import 'bytecode_generator.dart' show generateBytecode;\n"
                  "import 'bytecode_generator.dart' as bg;", 1)
    io.open(path, 'w', encoding='utf-8').write(s)
    print('  driver patched')


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
    s = s + VERIFIER_GLOBALS
    s = s + CLASS_TAIL
    if s.count(IMPORTS_ANCHOR) != 1:
        raise SystemExit('import anchor not unique -- refusing to patch blindly')
    s = s.replace(IMPORTS_ANCHOR, IMPORTS + IMPORTS_ANCHOR, 1)
    io.open(path, 'w', encoding='utf-8').write(s)
    patch_driver(os.path.join(os.path.dirname(path), 'dart2bytecode.dart'))
    print('0017 applied')


if __name__ == '__main__':
    main()
