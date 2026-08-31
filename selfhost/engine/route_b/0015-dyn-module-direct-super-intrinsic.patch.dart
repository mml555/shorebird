// Route B (selfhost) 0015 -- the direct-super intrinsic, and its INDEPENDENT
// backstop. Kept as readable Dart beside the patch series so the reasoning is
// reviewable without applying anything; `super0/s2b1/apply_0015.sh` injects it.
//
// WHY THE INTRINSIC CARRIES SITE IDENTITY AND NOT AN ARGUMENT COUNT.
//
// A field like `sourceArgs: 0` would be the producer asserting its own
// correctness, and the compiler checking that assertion against itself. If the
// producer has a bug that turns `super.tag('a', 7)` into an argument-free
// intrinsic, it will also write 0 into that field. So the intrinsic instead
// carries enough ORIGIN/SITE identity for this compiler to rediscover the
// original `SuperMethodInvocation` in its own import kernel and establish the
// shape itself.
//
// THE THREE AUTHORITIES, and why the import kernel is the right one here:
//
//   AOT kernel     a genuine super site exists in the shipped release, and what
//                  it retained. NEVER consulted for invocation shape: TFA
//                  specialises callees, and `super.tag('a', 7)` reads as ZERO
//                  arguments there (measured, `super0/s2b0/`).
//   patch source   what the developer wrote. The producer's admission gate and
//                  the useful error message.
//   import kernel  what this compiler is compiling against. It holds the
//                  ORIGINAL, unspecialised body of the method being replaced --
//                  so the original super site is present, with its real
//                  argument count -- and its hierarchy decides what `super`
//                  means locally (D-SUPER-2A.2).
//
// NO TRANSFORMED IDENTITY CROSSES THE BOUNDARY: no AOT canonical target, no
// AOT arity, no `dart:mixin_deduplication` class name. Only stable origin and
// site information. The target is re-derived here, every time.
//
// NO VIRTUAL FALLBACK anywhere. Every failure throws, because a fallback would
// convert a broken lowering into a plausible one -- which is exactly what
// `(self as Parent).value()` did in D-SUPER-0 (it compiled, ran, and returned
// the override).

/*
  // ---- injected into visitStaticInvocation, after `args`/`target` ----------
  if (_shorebirdDirectSuper(target)) {
    _genShorebirdDirectSuper(node, args);
    return;
  }
*/

/*
  // ---- injected as members of BytecodeGenerator ----------------------------

  /// Recognised by PRAGMA, not by a magic identifier: a spelling carries no
  /// authority, and the producer's chosen name must not be the contract.
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

  void _genShorebirdDirectSuper(StaticInvocation node, Arguments args) {
    // (receiver, originLibrary, originClass, originMethod, siteOffset, member)
    if (args.positional.length != 6 ||
        args.named.isNotEmpty ||
        args.types.isNotEmpty) {
      _superRefusal('malformed intrinsic call');
    }
    String literal(int i) {
      final e = args.positional[i];
      if (e is! StringLiteral) _superRefusal('argument $i is not a literal');
      return (e as StringLiteral).value;
    }

    final originLibrary = literal(1);
    final originClassName = literal(2);
    final originMethodName = literal(3);
    final offsetExpr = args.positional[4];
    if (offsetExpr is! IntLiteral) _superRefusal('site offset is not a literal');
    final siteOffset = (offsetExpr as IntLiteral).value;
    final memberName = literal(5);

    // 1. Only inside a dyn-module replacement entry point. Anywhere else there
    //    is no "the receiver", so the arg0 rule below would mean nothing.
    final enclosing = enclosingMember;
    if (enclosing == null || enclosing != dynModuleEntryPoint) {
      _superRefusal('used outside the dynamic-module entry point');
    }

    // 2. The receiver must be EXACTLY positional parameter 0 of that entry
    //    point. `isUnchecked: true` below asks the runtime not to verify the
    //    receiver, and what justifies that is the replacement ABI: the original
    //    call site invoked the method being replaced, so argument 0 is that
    //    method's own receiver. An arbitrary expression -- even one with a
    //    compatible static type -- has no such provenance.
    final fn = enclosingFunction;
    final receiver = args.positional[0];
    if (fn == null || fn.positionalParameters.isEmpty) {
      _superRefusal('entry point takes no receiver parameter');
    }
    if (receiver is! VariableGet ||
        (receiver as VariableGet).variable != fn!.positionalParameters.first) {
      _superRefusal('receiver is not parameter 0 of the entry point');
    }

    // 3. Rediscover the ORIGINAL site in THIS kernel. Everything after this is
    //    established from the import kernel, independently of anything the
    //    producer believed.
    final lib = allLibraries.firstWhere(
      (l) => l.importUri.toString() == originLibrary,
      orElse: () => _superRefusal('origin library not in the import kernel'),
    );
    final cls = lib.classes.firstWhere(
      (c) => c.name == originClassName,
      orElse: () => _superRefusal('origin class not in the import kernel'),
    );
    final origin = cls.procedures.firstWhere(
      (p) => p.name.text == originMethodName,
      orElse: () => _superRefusal('origin method not in the import kernel'),
    );

    final finder = _SuperSiteAt(siteOffset);
    origin.function.accept(finder);
    final site = finder.found;
    // 4/5. There must be exactly one, and it must be a SuperMethodInvocation.
    if (site == null) {
      _superRefusal('no super invocation at offset $siteOffset in '
          '$originClassName.$originMethodName');
    }
    if (finder.count != 1) {
      _superRefusal('${finder.count} super invocations share offset '
          '$siteOffset');
    }
    // 6. and it must be the member the producer named.
    if (site!.name.text != memberName) {
      _superRefusal('site at $siteOffset invokes ${site!.name.text}, '
          'not $memberName');
    }
    // 7. INDEPENDENT shape check. The import kernel holds the original,
    //    unspecialised body, so this is the source's own argument count -- not
    //    the AOT kernel's, and not a number the producer supplied.
    final siteArgs = site!.arguments;
    if (siteArgs.positional.isNotEmpty ||
        siteArgs.named.isNotEmpty ||
        siteArgs.types.isNotEmpty) {
      _superRefusal('super.$memberName takes arguments '
          '(${siteArgs.positional.length} positional, '
          '${siteArgs.named.length} named, ${siteArgs.types.length} type)');
    }

    // 8. Resolve locally, with this kernel's own hierarchy -- the same
    //    machinery ordinary super compilation uses. Nothing about the AOT
    //    kernel's mixin-application names participates.
    final superclass = cls.superclass;
    if (superclass == null) _superRefusal('origin class has no superclass');
    final resolved = hierarchy.getDispatchTarget(
      superclass!,
      Name(memberName, memberName.startsWith('_') ? lib : null),
    );
    if (resolved is! Procedure) {
      _superRefusal('no dispatch target for $memberName above $originClassName');
    }

    // 9. The existing receiver-taking direct call.
    final noArgs = Arguments(const <Expression>[])..parent = node;
    _genArguments(receiver, noArgs);
    _genDirectCallWithArgs(
      resolved as Procedure,
      noArgs,
      hasReceiver: true,
      isUnchecked: true,
      node: node,
    );
  }
*/

/*
  // ---- injected as a top-level class --------------------------------------

  /// The super invocation at one exact file offset, and how many share it.
  ///
  /// The count matters: if two sites collide the offset is not an identity, and
  /// picking either would be a guess.
  class _SuperSiteAt extends RecursiveVisitor {
    _SuperSiteAt(this.offset);
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
*/
