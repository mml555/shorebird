// D0.1 hygiene control. Two classes both carry `label`, so a MIS-BINDING
// COMPILES -- a case where the wrong binding failed to resolve would prove
// nothing about the dangerous direction.
//
// RETENTION IS EXPLICIT AND IDENTICAL ON BOTH SIDES. The first attempt at
// these controls was refused by the analyzer for "member(s) are new" -- the
// `--aot` prepass had tree-shaken `Shadow.label` and `Other.label` out of the
// base, because the base body never called them, so they arrived in the
// patched kernel looking like ADDED members. That refusal says nothing about
// `self` and would have passed for a real result. `keepAlive` holds both
// labels live from a dead branch in BOTH kernels, so the target method is the
// only member that differs.
//
// Every value is routed through DateTime so nothing constant-folds.
class Other {
  @pragma('vm:never-inline')
  String get label =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'WRONG-OTHER' : 'X';
}

class Shadow {
  static final Other other = Other();

  /// A legitimate member named `self`. Case J patches a body that reads it, so
  /// the repair has to keep the AUTHOR's `self` meaning this member while the
  /// generated receiver takes another name.
  @pragma('vm:never-inline')
  Other get self => other;

  @pragma('vm:never-inline')
  String get label =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'RIGHT-RECEIVER' : 'X';

  @pragma('vm:never-inline')
  static String keepAlive() => DateTime.now().millisecondsSinceEpoch < 0
      ? Shadow().label + Shadow.other.label + Shadow().self.label
      : 'k';

  @pragma('vm:never-inline')
  String value() {
    final f = () {
      final self = Shadow.other;
      return self.label.isEmpty ? 'X' : label;
    };
    return f();
  }
}

void main() =>
    print(Shadow.keepAlive().isEmpty ? 'X' : Shadow().value());
