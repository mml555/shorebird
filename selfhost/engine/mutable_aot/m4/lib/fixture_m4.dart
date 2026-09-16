// The #68 optimizer-stress fixture. It is the #67 program plus the adversarial
// variants #68 names, so the same mechanism is exercised under optimization
// pressure rather than a second mechanism being introduced.
import 'dart:ffi';
import 'dart:io' show Platform;

// ---- 1. tiny always-inline candidate ------------------------------------
// Small enough that the inliner would take it without the mutable rule, and
// marked prefer-inline so the rule has to win over an explicit request.
@pragma('vm:prefer-inline')
@pragma('maot:mutable')
String tiny() => 'OLD-TINY';

// ---- 2. constant-return callee ------------------------------------------
@pragma('maot:mutable')
String constantish() => 'OLD-CONST';

// ---- 3. recognized/intrinsic, and STATIC -------------------------------
// The hole the instance-dispatch blocker does not cover. A recognized or
// intrinsified declaration can have its body replaced by inline code at the
// call site, and no dispatch cell mediates that. It is not an instance-member
// problem: dart:core's `identical` and several top-level Developer and FFI
// functions are recognized and static.
//
// Two separate facts, only one of which is a proof:
//   * no SDK declaration can be selected -- collectSelected skips dart:
//     libraries, and the gate asserts the shipped selected set has no dart:
//     id. That is mechanical, and it is checked.
//   * a USER declaration can carry vm:recognized and also maot:mutable, and
//     nothing used to stop it. This declaration IS that case, and H16
//     requires the precompiler to refuse it.
@pragma('vm:recognized', 'other')
@pragma('maot:mutable')
String recognizedish() => 'OLD-RECOGNIZED';

// ---- 4. unreachable at release, called only by the patch ----------------
@pragma('maot:mutable')
String releaseUnreachable() => 'OLD-UNREACHED';

// ---- 5. devirtualization scaffolding ------------------------------------
// One concrete implementor and one instantiation site, so TFA can prove the
// receiver type and turn the instance call into a static call. This is
// OPTIMIZER scaffolding: it says nothing about virtual dispatch, which #69
// owns. It says that when the optimizer removes a virtual call, what replaces
// it still goes through the slot.
abstract class Shape {
  String describe();
}

class OnlyShape implements Shape {
  @pragma('maot:mutable')
  @override
  String describe() => 'OLD-DEVIRT';

  // The replacement lives on the same class and has the same shape. A
  // top-level function cannot replace an instance method: the ABI descriptor
  // differs in memberKind and receiver, and #66 refuses it. The first version
  // of this fixture tried exactly that and was correctly refused.
  @pragma('maot:mutable')
  String describeReplacement() => 'NEW-DEVIRT';
}

@pragma('vm:never-inline')
Shape makeShape() => OnlyShape();

// ---- 6/7/8. several callees, mixed mutability, nested chain -------------
@pragma('maot:mutable')
String chainA() => 'OLD-A${chainB()}';
@pragma('maot:mutable')
String chainB() => '-OLD-B${chainC()}';
String chainC() => '-PLAIN-C';          // immutable callee of a mutable caller

@pragma('vm:never-inline')
String immutableCaller() => '${tiny()}/${constantish()}';  // inverse direction

// ---- replacements -------------------------------------------------------
@pragma('maot:mutable')
String tinyNew() => 'NEW-TINY';
@pragma('maot:mutable')
String constantishNew() => 'NEW-CONST';
@pragma('maot:mutable')
String unreachableNew() => 'NEW-UNREACHED';

@pragma('maot:mutable')
String recognizedishNew() => 'NEW-RECOGNIZED';
@pragma('maot:mutable')
String chainANew() => 'NEW-A';

@pragma('vm:never-inline')
String plainControl() => 'CTL';

// ---- 9. the transitive constant-propagation shape (#68 regression) ------
//
// The dangerous shape, made load-bearing. `folded` returns a constant, so its
// constant enters the analysis summary of `foldedCaller`, which is NOT
// mutable and returns that value verbatim. Every caller of `foldedCaller`
// then folds the release answer at a call site whose target is the
// intermediary -- which neither the front-end suppression nor the VM backstop
// examines, because both key on the immediate target.
//
// Measured before this arm existed: install reported success, the cell held
// the replacement, the replacement body ran, and the caller still printed the
// release constant.
//
// The arm does not require a particular implementation. It requires that the
// program never claim success while the release constant survives -- either
// the replacement is observed, or StageReplacement refuses.
@pragma('maot:mutable')
String folded() => 'OLD-FOLDED';

@pragma('maot:mutable')
String foldedNew() => 'NEW-FOLDED';

@pragma('vm:never-inline')
String foldedCaller() => folded();

@pragma('vm:never-inline')
int benchMutable(int iters) {
  var n = 0;
  final w = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    n += tiny().length;
  }
  w.stop();
  return w.elapsedMicroseconds + (n < 0 ? 1 : 0);
}

@pragma('vm:never-inline')
int benchControl(int iters) {
  var n = 0;
  final w = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    n += plainControl().length;
  }
  w.stop();
  return w.elapsedMicroseconds + (n < 0 ? 1 : 0);
}

const _lib = 'lib:package:m4app/fixture_m4.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _install = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>, Int64, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>, int,
        Pointer<Uint8>)>('Dart_MaotInstallForTesting');
final _version = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotCurrentVersionForTesting');
final _dump = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotDumpForTesting');
final _pidFn = _proc.lookupFunction<Int32 Function(), int Function()>('getpid');

Pointer<Uint8> _c(String s) {
  final u = s.codeUnits;
  final p = _malloc(u.length + 1);
  for (var i = 0; i < u.length; i++) {
    p[i] = u[i];
  }
  p[u.length] = 0;
  return p;
}

String _v(String id) {
  final raw = _version(_c(id));
  if (raw == -1) return 'absent';
  return raw >= 0 ? 'AOT:v$raw' : 'PATCH_CODE:v${-(raw + 100)}';
}

void _emit(String k, Object v) => print('$k=$v');

int _install3(String target, String impl, int version, String ns) =>
    _install(_c('$_lib::$target'), _c('$_lib::$impl'), version, _c(ns));

void main(List<String> args) {
  final ns = Platform.environment['MAOT_NAMESPACE'] ?? '';
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('process.pid', _pidFn());

  final shape = makeShape();

  // ---- cold, before installation ----
  _emit('tiny.0', tiny());
  _emit('constantish.0', constantish());
  _emit('devirt.0', shape.describe());
  _emit('chain.0', chainA());
  _emit('immutableCaller.0', immutableCaller());
  _emit('unreachable.version.0', _v('$_lib::fn:releaseUnreachable'));
  _emit('recognizedish.0', recognizedish());
  _emit('folded.0', foldedCaller());
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));

  // ---- install across every variant ----
  _emit('install.tiny', _install3('fn:tiny', 'fn:tinyNew', 2, ns));
  // CROSS-WIRING (#69). Read BOTH immediately after patching only A. If two
  // declarations' trampolines were bound to the same cell -- which is exactly
  // what happened while every trampoline deduplicated into one -- then
  // patching A would move B as well, and installing both before re-reading
  // either would hide it completely.
  _emit('xwire.A.afterPatchA', tiny());
  _emit('xwire.B.afterPatchA', constantish());
  _emit('install.constantish',
      _install3('fn:constantish', 'fn:constantishNew', 2, ns));
  _emit('install.devirt',
      _install3('cls:OnlyShape::method:describe',
          'cls:OnlyShape::method:describeReplacement', 2, ns));
  _emit('install.chainA', _install3('fn:chainA', 'fn:chainANew', 2, ns));
  // 4. a declaration the release never calls is still addressable.
  _emit('install.unreachable',
      _install3('fn:releaseUnreachable', 'fn:unreachableNew', 2, ns));
  // Must be REFUSED: the declaration is FORBIDDEN at seeding because it is
  // recognized, so installation has to fail closed rather than produce a
  // caller holding compiler-substituted code.
  _emit('install.recognizedish',
      _install3('fn:recognizedish', 'fn:recognizedishNew', 2, ns));
  // Either this is refused, or `folded.1` shows NEW-FOLDED. Success plus the
  // release constant is the one outcome the arm forbids.
  _emit('install.folded', _install3('fn:folded', 'fn:foldedNew', 2, ns));

  // ---- cold, after installation ----
  _emit('tiny.1', tiny());
  _emit('constantish.1', constantish());
  _emit('xwire.A.afterPatchB', tiny());
  _emit('xwire.B.afterPatchB', constantish());
  _emit('devirt.1', shape.describe());
  _emit('chain.1', chainA());
  _emit('immutableCaller.1', immutableCaller());
  _emit('unreachable.version.1', _v('$_lib::fn:releaseUnreachable'));
  _emit('recognizedish.1', recognizedish());
  _emit('folded.1', foldedCaller());

  // ---- 3. hot: the same precompiled sites after many iterations ----
  const hot = 200000;
  var lastTiny = '', lastDevirt = '', lastChain = '';
  for (var i = 0; i < hot; i++) {
    lastTiny = tiny();
    lastDevirt = shape.describe();
    lastChain = chainA();
  }
  _emit('hot.iterations', hot);
  _emit('hot.tiny', lastTiny);
  _emit('hot.devirt', lastDevirt);
  _emit('hot.chain', lastChain);

  // ---- 9. a second replacement moves the version again ----
  _emit('install.tiny.v3', _install3('fn:tiny', 'fn:constantishNew', 3, ns));
  _emit('tiny.2', tiny());
  _emit('tiny.version.2', _v('$_lib::fn:tiny'));

  // ---- call-cost accounting ----
  // Same method as #67: total elapsed microseconds reported, three samples,
  // the gate takes the minimum and divides. The control is a non-selected
  // function marked never-inline, because an inlined control is not a call.
  const iters = 2000000;
  benchMutable(iters ~/ 10);
  benchControl(iters ~/ 10);
  _emit('bench.iterations', iters);
  for (var rep = 0; rep < 3; rep++) {
    _emit('bench.mutable.us.$rep', benchMutable(iters));
    _emit('bench.control.us.$rep', benchControl(iters));
  }

  _emit('process.pid.final', _pidFn());
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_after.json'));
}
