// D-SUPER-2A synthetic shapes. Each is a distinct way for "the super target" to
// be ambiguous, and the mixin pair is the one dart2bytecode's own source warns
// about ("Re-resolve target due to partial mixin resolution").
//
// Every body is DateTime-routed so nothing constant-folds before the kernel is
// written, and every method is never-inline so TFA cannot dissolve the call site.

// ---- 1. direct superclass, zero args (the shape D-SUPER-1 proved) ----------
class D1Parent {
  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'D1P' : 'X';
}

class D1Child extends D1Parent {
  @pragma('vm:never-inline')
  @override
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'D1C' : 'X';

  @pragma('vm:never-inline')
  String go() => super.read();
}

// ---- 2. DEEP hierarchy: the nearest implementation is not the direct parent -
class DeepA {
  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'DEEP-A' : 'X';
}

class DeepB extends DeepA {}          // declares nothing

class DeepC extends DeepB {
  @pragma('vm:never-inline')
  @override
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'DEEP-C' : 'X';

  // `super.read()` here must select DeepA.read, reached THROUGH DeepB, which
  // declares no `read` at all.
  @pragma('vm:never-inline')
  String go() => super.read();
}

// ---- 3. MIXIN applied, mixin does NOT override ----------------------------
mixin QuietMixin {
  @pragma('vm:never-inline')
  String untouched() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'Q' : 'X';
}

class MixA {
  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'MIX-A' : 'X';
}

class MixQuiet extends MixA with QuietMixin {
  @pragma('vm:never-inline')
  @override
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'MIX-QUIET' : 'X';

  @pragma('vm:never-inline')
  String go() => super.read();
}

// ---- 4. MIXIN applied, mixin DOES override -------------------------------
// The interesting one. `super.read()` in MixLoud must select the MIXIN's
// override — reached through the synthetic mixin-application class — not MixB's.
mixin LoudMixin on MixB {
  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'MIXIN' : 'X';
}

class MixB {
  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'MIX-B' : 'X';
}

class MixLoud extends MixB with LoudMixin {
  @pragma('vm:never-inline')
  @override
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'MIX-LOUD' : 'X';

  @pragma('vm:never-inline')
  String go() => super.read();
}

// ---- 5. a `super` call INSIDE a mixin's own method ------------------------
mixin ChainMixin on MixB {
  @pragma('vm:never-inline')
  String chain() => 'CHAIN-${super.read()}';
}

class MixChain extends MixB with ChainMixin {}

// ---- 6. lifecycle shape: void, zero args, two levels ---------------------
class LifeParent {
  String log = '';
  @pragma('vm:never-inline')
  void begin() {
    log += 'P';
  }
}

class LifeChild extends LifeParent {
  @pragma('vm:never-inline')
  @override
  void begin() {
    super.begin();
    log += 'C';
  }
}

// ---- 7. private super target --------------------------------------------
class PrivParent {
  @pragma('vm:never-inline')
  String _hidden() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'PRIV-P' : 'X';
}

class PrivChild extends PrivParent {
  @pragma('vm:never-inline')
  @override
  String _hidden() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'PRIV-C' : 'X';

  @pragma('vm:never-inline')
  String go() => super._hidden();
}

// ---- 8. super GETTER and SETTER (refused in v1; measured anyway) ---------
class AccParent {
  String _slot = 'A-P';
  @pragma('vm:never-inline')
  String get slot => DateTime.now().millisecondsSinceEpoch >= 0 ? _slot : 'X';
  @pragma('vm:never-inline')
  set slot(String v) => _slot = 'set:$v';
}

class AccChild extends AccParent {
  @pragma('vm:never-inline')
  @override
  String get slot => DateTime.now().millisecondsSinceEpoch >= 0 ? 'A-C' : 'X';

  @pragma('vm:never-inline')
  String getGo() => super.slot;

  @pragma('vm:never-inline')
  String setGo() {
    super.slot = 'V';
    return super.slot;
  }
}

// ---- 9. super call WITH arguments (refused in v1; measured anyway) -------
class ArgParent {
  @pragma('vm:never-inline')
  String tag(String a, int b) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'ARG-P:$a:$b' : 'X';
}

class ArgChild extends ArgParent {
  @pragma('vm:never-inline')
  @override
  String tag(String a, int b) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'ARG-C' : 'X';

  @pragma('vm:never-inline')
  String go() => super.tag('a', 7);
}

void main() {
  final life = LifeChild()..begin();
  print([
    D1Child().go(),
    DeepC().go(),
    MixQuiet().go(),
    MixLoud().go(),
    MixChain().chain(),
    life.log,
    PrivChild().go(),
    AccChild().getGo(),
    AccChild().setGo(),
    ArgChild().go(),
  ].join(' | '));
}
