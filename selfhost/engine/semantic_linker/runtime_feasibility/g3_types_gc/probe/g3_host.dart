// SL1-G3 host: patch-defined classes inside Dart's type system, and inside its
// garbage-collected object graph.
//
// G3 deliberately does NOT repeat G2. It assumes bidirectional execution and
// exact identity are established, and asks the next question: does that stay
// correct when a patch class is a real participant -- implemented, extended,
// stored in typed collections, passed through a bounded generic, and traced by
// the collector from both sides?
//
// ignore_for_file: implementation_imports
import 'dart:_internal'
    show
        loadDynamicModule,
        functionExecutionMode,
        collectAllGarbageForTesting;
import 'dart:io';
import 'dart:typed_data';

const int kUnsupported = -1, kNotFound = 0, kAot = 1, kInterpreted = 2, kNoCode = 3;
String modeName(int m) => switch (m) {
      kUnsupported => 'UNSUPPORTED',
      kNotFound => 'NOT_FOUND',
      kAot => 'AOT',
      kInterpreted => 'INTERPRETED',
      kNoCode => 'NO_CODE',
      _ => 'UNKNOWN($m)',
    };

int _failures = 0;
void expectMode(String label, String lib, String target, int want) {
  final got = functionExecutionMode(lib, target);
  final ok = got == want;
  if (!ok) _failures++;
  print('MODE ${ok ? "ok  " : "FAIL"} $label: $target -> ${modeName(got)} (want ${modeName(want)})');
}
void expect(String label, bool cond, [String? detail]) {
  if (!cond) _failures++;
  print('CHECK ${cond ? "ok  " : "FAIL"} $label${detail == null ? "" : ": $detail"}');
}

// ------------------------------------------------------------- type surface
abstract class Iface {
  String tag();
}

class Base {
  int n = 0;
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  String execute() => 'AOT-BASE';
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  String inherited() => 'INHERITED';
}

/// AOT-side operations on Base. Each is never-inline so the call is real; none
/// is monomorphic-by-construction on purpose -- deliberately adversarial call
/// shapes are #41's subject, not this gate's.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String dispatchBase(Base b) => b.execute();

@pragma('vm:never-inline')
@pragma('vm:entry-point')
Base castToBase(Object o) => o as Base;

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String dispatchIface(Iface i) => i.tag();

/// The bounded generic the ruling singled out: the type ARGUMENT itself has to
/// survive the boundary, not merely the value.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
T echo<T extends Base>(T value) => value;

final List<Base> aotList = <Base>[];
final Map<String, Base> aotMap = <String, Base>{};

@pragma('vm:never-inline')
@pragma('vm:entry-point')
void addToList(Base b) => aotList.add(b);

@pragma('vm:never-inline')
@pragma('vm:entry-point')
void putInMap(String k, Base b) => aotMap[k] = b;

// --------------------------------------------------------------- GC surface
class Holder {
  Object? ref;
}

final Holder aotHolder = Holder();

/// A plain AOT object with observable state, for the patch-roots-AOT case.
class Tracked {
  int v;
  Tracked(this.v);
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  int read() => v;
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
Tracked makeTracked(int v) => Tracked(v);

/// AOT-created weak observation. The collector's own signal, not an inference
/// from RSS, allocation counts, or failure to find something.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
WeakReference<Object> weakOf(Object o) => WeakReference<Object>(o);

/// A bytecode closure the module installs so later checks can run FROM the
/// patch side after a collection.
Object? Function()? patchProbe;

/// Full GC. Run more than once because a young object may need more than one
/// cycle to be reachable-tested in the old generation; the count actually used
/// is reported so a reader is not left guessing.
@pragma('vm:never-inline')
void collect(int times) {
  for (var i = 0; i < times; i++) {
    collectAllGarbageForTesting();
  }
  print('GC: collectAllGarbageForTesting x$times');
}

/// Build a weakly-observed ordinary AOT object and drop every strong reference
/// to it before returning. never-inline matters: inlining would let the
/// allocation's local outlive the call in the caller's frame.
@pragma('vm:never-inline')
WeakReference<Object> makeUnrootedAotObject() => WeakReference<Object>(Tracked(1));

/// Take the weak observation and the pre-GC state INSIDE a never-inline helper,
/// so no local of ours is live across the collection.
///
/// The first version did this in `main` and set the local to null afterwards,
/// which does not compile against a `final` and -- more importantly -- would
/// have left the question of whether a live slot still rooted the object. A
/// helper whose frame is gone before `collect()` runs settles it structurally.
@pragma('vm:never-inline')
(WeakReference<Object>, int) observeProbe() {
  final probed = patchProbe!() as Tracked;
  return (weakOf(probed), probed.read());
}

@pragma('vm:never-inline')
WeakReference<Object> makeRootedAotObject() {
  final t = Tracked(2);
  aotHolder.ref = t;
  return WeakReference<Object>(t);
}

Future<void> main(List<String> args) async {
  final test = args.isEmpty ? 'none' : args[0];
  final modulePath = args.length > 1 ? args[1] : null;
  final moduleUri = args.length > 2 ? args[2] : null;
  const host = 'package:dynamic_modules/g3_host.dart';

  // ---- 0. THE COLLECTOR ITSELF IS FALSIFIED BEFORE IT IS USED AS EVIDENCE.
  // Deliberately ABOVE the oracle gate: this measures ordinary AOT objects
  // and the GC instrument, neither of which depends on dynamic modules. So it
  // runs on BOTH arms, and the collector behaving identically with the flag
  // off is itself evidence that the instrument is not entangled with the
  // substrate under test.
  // A no-op "GC trigger" would make every survival test below pass while
  // collecting nothing, so it must be shown to clear a weak reference it should
  // and to spare one it should not.
  if (test == 'gc_control') {
    final unrooted = makeUnrootedAotObject();
    final rooted = makeRootedAotObject();
    expect('before GC: unrooted object is still there', unrooted.target != null);
    collect(2);
    expect('unrooted ordinary AOT object WAS collected', unrooted.target == null,
        '${unrooted.target}');
    expect('rooted ordinary AOT object SURVIVED', rooted.target != null,
        '${rooted.target}');
    expect('and the rooted one is the object the holder still names',
        identical(rooted.target, aotHolder.ref));
    print(_failures == 0 ? 'G3-TEST PASS' : 'G3-TEST FAIL ($_failures)');
    exitCode = _failures == 0 ? 0 : 1;
    return;
  }


  final selfMode = functionExecutionMode(host, 'dispatchBase');
  print('ORACLE: dispatchBase -> ${modeName(selfMode)}');
  if (selfMode == kUnsupported) {
    print('G3: ORACLE UNSUPPORTED — this build has no dynamic modules');
    exitCode = 3;
    return;
  }
  if (selfMode != kAot) {
    print('G3: ORACLE SELF-CHECK FAILED');
    exitCode = 4;
    return;
  }

  Object? loaded;
  Object? loadError;
  if (modulePath != null) {
    final bytes = Uint8List.fromList(File(modulePath).readAsBytesSync());
    try {
      loaded = await loadDynamicModule(bytes: bytes);
    } on Object catch (e) {
      loadError = e;
    }
  }
  if (loadError != null) {
    print('LOAD FAILED: $loadError');
    exitCode = 1;
    return;
  }

  switch (test) {
    // ---- GC 1. An AOT object's field is the ONLY root of a patch object.
    case 'gc_aot_roots_patch':
      expect('module rooted a patch object in an AOT field', aotHolder.ref != null,
          '${aotHolder.ref.runtimeType}');
      final w = weakOf(aotHolder.ref!);
      final beforeTag = dispatchIface(aotHolder.ref! as Iface);
      collect(2);
      expect('patch object survived a full GC', w.target != null);
      expect('it is the SAME object the AOT field names',
          identical(w.target, aotHolder.ref));
      expect('its method still dispatches after GC',
          dispatchIface(aotHolder.ref! as Iface) == beforeTag, beforeTag);
      expectMode('and still dispatches INTO BYTECODE after GC', moduleUri!,
          'PatchIface.tag', kInterpreted);
      // state readable and mutable across the collection
      final b = aotHolder.ref! as Iface;
      expect('patch object state readable after GC', b.tag().isNotEmpty);

    // ---- GC 2. A patch object's field is the ONLY root of an AOT object.
    case 'gc_patch_roots_aot':
      expect('module installed a bytecode probe', patchProbe != null);
      expect('probe returns an AOT object', patchProbe!() is Tracked,
          '${patchProbe!().runtimeType}');
      // Only the patch object's field may keep the AOT object alive across the
      // collection, so the observation is taken in a helper whose frame is gone
      // before collect() runs.
      final (w, before) = observeProbe();
      collect(2);
      expect('AOT object survived, rooted only through patch code',
          w.target != null);
      final after = patchProbe!();
      expect('bytecode still returns the SAME AOT object', identical(after, w.target));
      expect('its state is preserved', (after as Tracked).read() == before, '$before');
      expect('and an AOT call on it still works', after.read() == before);

    // ---- GC 3. An unrooted AOT->patch->AOT cycle must be collected.
    case 'gc_cycle_collects':
      final ws = (loaded as List<Object?>).cast<WeakReference<Object>>();
      expect('the patch node existed before collection', ws[0].target != null);
      expect('the AOT node existed before collection', ws[1].target != null);
      collect(3);
      expect('unrooted patch object in the cycle WAS collected',
          ws[0].target == null, '${ws[0].target}');
      expect('unrooted AOT object in the cycle WAS collected',
          ws[1].target == null, '${ws[1].target}');

    // ---- TYPES 1. patch class implements an AOT interface.
    case 'type_implements':
      expect('construct: module returned an object', loaded != null, '${loaded.runtimeType}');
      expect('is Iface', loaded is Iface, '${loaded is Iface}');
      final i = dispatchIface(loaded as Iface);
      expect('AOT cast + virtual dispatch', i == 'PATCH-IFACE', i);
      expectMode('dispatch entered bytecode', moduleUri!, 'PatchIface.tag', kInterpreted);

    // ---- TYPES 2. patch class extends an AOT base, including super -> AOT.
    case 'type_extends':
      expect('construct', loaded != null, '${loaded.runtimeType}');
      expect('is Base', loaded is Base, '${loaded is Base}');
      final b = castToBase(loaded!);
      expect('inherited AOT method', b.inherited() == 'INHERITED', b.inherited());
      final r = dispatchBase(b);
      expect('override ran and super reached AOT', r == 'PATCH:AOT-BASE', r);
      expectMode('the override is INTERPRETED', moduleUri!, 'PatchChild.execute',
          kInterpreted);
      expectMode('the super target is AOT', 'package:dynamic_modules/g3_host.dart',
          'Base.execute', kAot);
      b.n = 5;
      expect('inherited field is writable and readable', b.n == 5, '${b.n}');

    // ---- TYPES 3. returning a patch object to AOT.
    case 'type_return':
      final first = loaded;
      expect('runtimeType is the patch class', '${first.runtimeType}' == 'PatchChild',
          '${first.runtimeType}');
      final e1 = dispatchBase(first as Base);
      final e2 = dispatchBase(first);
      expect('repeated calls agree', e1 == e2, '$e1/$e2');
      expect('identity is stable across calls', identical(first, loaded));

    // ---- TYPES 4. AOT typed collections.
    case 'type_collections':
      final p = castToBase(loaded!);
      addToList(p);
      putInMap('k', p);
      expect('List<Base> retrieve', identical(aotList[0], p));
      expect('List<Base> dispatch', dispatchBase(aotList[0]) == 'PATCH:AOT-BASE',
          dispatchBase(aotList[0]));
      expect('Map<String,Base> retrieve', identical(aotMap['k'], p));
      expect('Map<String,Base> dispatch', dispatchBase(aotMap['k']!) == 'PATCH:AOT-BASE',
          dispatchBase(aotMap['k']!));
      expect('elements are still the patch type', '${aotList[0].runtimeType}' == 'PatchChild',
          '${aotList[0].runtimeType}');

    // ---- TYPES 5. bounded generic, where the type ARGUMENT crosses too.
    case 'type_generic':
      final p = castToBase(loaded!);
      final back = echo<Base>(p);
      expect('returned T is identical', identical(back, p));
      expect('runtime type is still the patch class',
          '${back.runtimeType}' == 'PatchChild', '${back.runtimeType}');
      expect('AOT treats the result as Base', back is Base);
      expect('virtual dispatch on the generic result', dispatchBase(back) == 'PATCH:AOT-BASE',
          dispatchBase(back));
      expectMode('and it still enters bytecode', moduleUri!, 'PatchChild.execute',
          kInterpreted);

    // ---- TYPES 6. the generic instantiated AT A PATCH-DEFINED TYPE, by the
    //      module. echo<Base>(p) above only shows the value survives; this
    //      makes the reified type ARGUMENT cross the boundary.
    case 'type_generic_patcharg':
      final parts = loaded as List<Object?>;
      expect('module instantiated the AOT generic at its own type',
          parts[1] == true, 'identical=${parts[1]}');
      expect('runtime type of the returned T is the patch class',
          parts[2] == 'PatchChild', '${parts[2]}');
      expect('the patch type test held inside bytecode', parts[3] == true,
          '${parts[3]}');
      final back = castToBase(parts[0]!);
      expect('AOT treats the result as Base', back is Base);
      expect('and dispatch still enters bytecode',
          dispatchBase(back) == 'PATCH:AOT-BASE', dispatchBase(back));
      expectMode('confirmed by execution mode', moduleUri!, 'PatchChild.execute',
          kInterpreted);

    default:
      print('G3: unknown test $test');
      exitCode = 2;
      return;
  }

  print(_failures == 0 ? 'G3-TEST PASS' : 'G3-TEST FAIL ($_failures)');
  exitCode = _failures == 0 ? 0 : 1;
}
