// MAOT-5 (#69) virtual-routing fixture.
//
// The question this program exists to answer is narrow: does a REAL AOT
// instance call reach the declaration's trampoline, and therefore its cell?
//
// m4's Shape has a single implementor, so TFA proves the receiver type and
// devirtualizes the call into a static one. That is #68 scaffolding and it
// says nothing about virtual dispatch. Here there are two implementors and
// the receiver is chosen from the environment, so neither CHA nor TFA can
// pin it and the call must stay a genuine instance call.
import 'dart:ffi';
import 'dart:io' show Platform;

abstract class Iface {
  String v();
  // A second member so the class is not degenerate and the selector table
  // has more than one row to distinguish.
  int weight();
}

class Alpha implements Iface {
  @pragma('maot:mutable')
  @override
  String v() => 'OLD-ALPHA';
  @override
  int weight() => 1;
}

class Beta implements Iface {
  @override
  String v() => 'BETA';
  @override
  int weight() => 2;
}

// The replacement lives on the same class with the same shape: a top-level
// function cannot replace an instance method, because the ABI descriptor
// differs in memberKind and receiver, and #66 refuses it.
class AlphaNew {
  @pragma('maot:mutable')
  String v() => 'NEW-ALPHA';
}

class AlphaNew2 {
  @pragma('maot:mutable')
  String v() => 'NEW2-ALPHA';
}

// Not inlined and not const-foldable: the receiver identity has to survive to
// the call site as a real value.
@pragma('vm:never-inline')
Iface pick(String which) => which == 'b' ? Beta() : Alpha();

const _lib = 'lib:package:m5app/fixture_m5.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _swap = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>(
    'Dart_MaotDiagnosticCellSwap');
final _ident = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotTrampolineIdentityForTesting');
final _dump = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotDumpForTesting');
final _stateCount = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotObservedStateCount');

Pointer<Uint8> _c(String s) {
  final u = s.codeUnits;
  final p = _malloc(u.length + 1);
  for (var i = 0; i < u.length; i++) {
    p[i] = u[i];
  }
  p[u.length] = 0;
  return p;
}

void _emit(String k, Object v) => print('$k=$v');

// One call site, two receiver classes. Written as a helper so BOTH calls are
// literally the same site: two separate `x.v()` expressions would be two
// sites, and the second would start Unlinked instead of hitting the state the
// first one left behind.
// ONE call site, reused. Three separate `x.v()` expressions are three
// separate sites, each of which starts Unlinked and misses once -- so reading
// through them measures fresh sites, not the warmed state under test. That
// error made a no-cache-mutation check report false for a reason that had
// nothing to do with cache mutation.
@pragma('vm:never-inline')
String _oneSite(dynamic x) => x.v();

@pragma('vm:never-inline')
String _callSame(dynamic first, dynamic second) {
  var r = '';
  for (var i = 0; i < 4000; i++) {
    r = (i < 2000 ? first : second).v();
  }
  return r;
}

int _swapCell(String target, String impl) =>
    _swap(_c('$_lib::$target'), _c('$_lib::$impl'));

void main(List<String> args) {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  // From the environment so nothing can constant-fold the receiver class.
  final which = Platform.environment['M5_RECEIVER'] ?? 'a';
  final Iface obj = pick(which);

  // Retain the replacement bodies. The ruling permits this explicitly: the
  // diagnostic swap points the cell at a replacement's PINNED BODY Code, so
  // that body has to exist. Calling them once is the least magical way to
  // keep them; nothing else in the experiment uses these values.
  _emit('retain.v2', AlphaNew().v());
  _emit('retain.v3', AlphaNew2().v());

  // Does the declaration carry a trampoline, and is it the Function's
  // current code? 1 = yes, 2 = present but Function points elsewhere,
  // 0 = no trampoline.
  _emit('tramp.identity', _ident(_c('$_lib::cls:Alpha::method:v')));

  // ---- cold, before any swap ----
  _emit('virt.0', obj.v());

  // ---- warm the instance call site so it reaches a linked dispatch state --
  var last = '';
  const warm = 200000;
  for (var i = 0; i < warm; i++) {
    last = obj.v();
  }
  _emit('virt.warm', last);

  // ---- ROUTING DIAGNOSTIC: swap the cell directly ----
  // This is not installation. It bypasses StageReplacement and every escape
  // check, on purpose, to ask whether the warmed instance call reaches this
  // declaration's cell at all.
  _emit('swap.1', _swapCell('cls:Alpha::method:v', 'cls:AlphaNew::method:v'));
  _emit('virt.1', obj.v());

  // the SAME warmed site, not a fresh one
  for (var i = 0; i < warm; i++) {
    last = obj.v();
  }
  _emit('virt.warm.1', last);

  _emit('swap.2', _swapCell('cls:Alpha::method:v', 'cls:AlphaNew2::method:v'));
  _emit('virt.2', obj.v());
  for (var i = 0; i < warm; i++) {
    last = obj.v();
  }
  _emit('virt.warm.2', last);

  // ---- the DYNAMIC axis, deliberately separate ----
  // An interface call on a statically-known interface compiles to
  // DispatchTableCallInstr: a direct indexed branch with no miss handler, so
  // it never enters the switchable-call machinery at all. A `dynamic`
  // receiver does, which is why #69 requires separate evidence for the two
  // and why they cannot be inferred from each other.
  final dynamic dyn = obj;
  _emit('dyn.0', dyn.v());
  var dlast = '';
  for (var i = 0; i < warm; i++) {
    dlast = dyn.v();
  }
  _emit('dyn.warm', dlast);
  _emit('swap.3', _swapCell('cls:Alpha::method:v', 'cls:AlphaNew::method:v'));
  _emit('dyn.1', dyn.v());
  for (var i = 0; i < warm; i++) {
    dlast = dyn.v();
  }
  _emit('dyn.warm.1', dlast);

  // ---- force transitions past the first linked state ----
  // After a site links monomorphically, a same-cid receiver never misses
  // again, so later states are reached SILENTLY and cannot be observed from
  // the miss handler. Alternating the receiver class forces the monomorphic
  // check to fail and the site to transition onward.
  final dynamic dynA = pick('a');
  final dynamic dynB = pick('b');
  var alt = '';
  for (var i = 0; i < warm; i++) {
    alt = (i.isEven ? dynA : dynB).v();
  }
  _emit('alt.last', alt);
  _emit('swap.4', _swapCell('cls:Alpha::method:v', 'cls:AlphaNew2::method:v'));
  var alt2 = '';
  for (var i = 0; i < warm; i++) {
    alt2 = (i.isEven ? dynA : dynB).v();
  }
  _emit('alt.afterSwap.even', dynA.v());
  _emit('alt.afterSwap.odd', dynB.v());

  // ---- a monomorphic miss whose TARGET is the mutable declaration ----
  // Order matters. If a site links to Alpha first, the later Beta call is the
  // one that misses monomorphically, and Beta.v is not mutable so nothing is
  // recorded. Linking to BETA first and then calling Alpha puts the mutable
  // declaration on the monomorphic-miss path, where its stored target can be
  // compared against the trampoline.
  final dynamic monoSite = pick('b');
  var m = '';
  for (var i = 0; i < 2000; i++) {
    m = monoSite.v();
  }
  _emit('mono.beta', m);
  final dynamic monoAlpha = pick('a');
  // the SAME call site, now with an Alpha receiver
  _emit('mono.alpha', _callSame(monoSite, monoAlpha));

  // ---- per-state OLD -> NEW -> NEW2, with no cache mutation ----
  //
  // The instrument: a cached dispatch target that a replacement invalidated
  // would MISS again, and a miss records another observation. So a swap that
  // changes what the call returns WITHOUT increasing the count proves the
  // cached target was never touched and the state resolved through the cell.
  //
  // Each sub-experiment drives one site into one state, then swaps twice
  // without letting the site fall out of that state.
  void perState(String label, String stateClass, dynamic site) {
    // NEVER swap the cell to a declaration that carries a trampoline. Alpha's
    // CurrentCode IS its trampoline, so `Alpha -> Alpha` sets
    // cell.implCode = trampoline and the trampoline branches to itself. That
    // hangs the process -- which is also incidental confirmation that the
    // trampoline -> cell -> implCode path is the live one.
    // Warm the ONE site first so it is in a linked state before any swap.
    for (var i = 0; i < 5000; i++) {
      _oneSite(site);
    }
    _swapCell('cls:Alpha::method:v', 'cls:AlphaNew::method:v');
    final c0 = _stateCount(_c(stateClass));
    _emit('$label.old', _oneSite(site));
    final c1 = _stateCount(_c(stateClass));
    _swapCell('cls:Alpha::method:v', 'cls:AlphaNew2::method:v');
    _emit('$label.new', _oneSite(site));
    final c2 = _stateCount(_c(stateClass));
    _swapCell('cls:Alpha::method:v', 'cls:AlphaNew::method:v');
    _emit('$label.new2', _oneSite(site));
    final c3 = _stateCount(_c(stateClass));
    _emit('$label.counts', '$c0/$c1/$c2/$c3');
    _emit('$label.noCacheMutation', c1 == c2 && c2 == c3);
  }

  // UnlinkedCall -> linked: a site called once is already past Unlinked, so
  // the swaps below exercise whatever state it settled into without
  // re-missing.
  final dynamic siteA = pick('a');
  for (var i = 0; i < 5000; i++) {
    siteA.v();
  }
  perState('st.linked', 'instance-dispatch/UnlinkedCall-observed', siteA);

  // Monomorphic reached via Beta-first ordering, then Alpha on the same site.
  perState('st.mono', 'instance-dispatch/monomorphic-observed', monoAlpha);

  // Beta must be untouched throughout: it shares the selector but is a
  // different declaration, so a shared-cell defect would move it too.
  _emit('beta.v', pick('b').v());

  if (dumpDir.isNotEmpty) {
    _dump(_c('$dumpDir/registry_after.json'));
  }
}
