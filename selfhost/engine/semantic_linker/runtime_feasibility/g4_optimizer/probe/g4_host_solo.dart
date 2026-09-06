// SL1-G4 SOLO host: the same five call shapes over a hierarchy with exactly ONE
// host implementation of execute(), so devirtualization is legally available.
//
// WHY THE CONTROL EXISTS. Without HostChild, a shape that returns the wrong
// answer cannot distinguish "the compiler devirtualized every virtual call
// here" from "the compiler specifically failed to honour the dynamic-module
// contract". The control proves the call site is executable normally; the
// subject asks whether extensibility survived.
//
// Each shape is its own never-inline top-level function so it gets its own
// symbol in the AOT ELF and can be disassembled independently. What is NOT
// never-inline is deliberate: s3_chain_b exists to BE inlined into s3_chain_a.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show loadDynamicModule, functionExecutionMode;
import 'dart:io';
import 'dart:typed_data';

const int kUnsupported = -1, kNotFound = 0, kAot = 1, kInterpreted = 2, kNoCode = 3;
String modeName(int m) => switch (m) {
      kUnsupported => 'UNSUPPORTED', kNotFound => 'NOT_FOUND', kAot => 'AOT',
      kInterpreted => 'INTERPRETED', kNoCode => 'NO_CODE', _ => 'UNKNOWN($m)',
    };
const String host = 'package:dynamic_modules/g4_host_solo.dart';

class Base {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  String execute() => 'AOT-BASE';
}

/// SOLO HIERARCHY. HostChild deliberately does NOT override execute, so
/// `Base.execute` is the only implementation the closed world contains and
/// class-hierarchy analysis is FREE to devirtualize the call sites below.
///
/// This arm exists because the two-implementation host could not answer the
/// question: with both Base.execute and HostChild.execute reachable, the
/// compiler must emit a dispatch-table call whatever the contract says, so the
/// fenced/unfenced comparison there measured the hierarchy rather than the
/// fence.
class HostChild extends Base {}

// ------------------------------------------------------------- 1. virtual
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String s1_virtual(Base b) => b.execute();

// --------------------------------------------- 2. hot / monomorphic receiver
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String s2_monomorphic(Base b) => b.execute();

// ------------------------------------------------------- 3. helper chain
/// NOT never-inline on purpose: this is the callee the optimizer is invited to
/// inline into s3_chain_a, which is the whole point of the shape.
///
/// prefer-inline was added after the first run showed the optimizer simply
/// DECLINED to inline it -- s3_chain_a was a plain `bl <s3_chain_b>` and the
/// virtual call still happened one frame down. That is a sound result but it is
/// not the shape #41 asks for, so the pressure is turned up. This makes the case
/// harder, not easier.
@pragma('vm:prefer-inline')
String s3_chain_b(Base b) => b.execute();

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String s3_chain_a(Base b) => s3_chain_b(b);

// --------------------------------------------------- 4. bounded generic
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String s4_generic<T extends Base>(T b) => b.execute();

// ------------------------------------------- 5. receiver in an AOT field
Base? s5_field;

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String s5_fieldCall() => s5_field!.execute();

// ---------------------------------------------------------------- reporting
void shape(String name, String expected, String observed, String modeTarget,
    String moduleUri, {required bool isPatch}) {
  final mode = isPatch
      ? functionExecutionMode(moduleUri, modeTarget)
      : functionExecutionMode(host, modeTarget);
  final bypass = observed != expected;
  print('SHAPE $name');
  print('  subject          ${isPatch ? "PatchChild" : "HostChild (control)"}');
  print('  expected target  $expected');
  print('  observed target  $observed');
  print('  execution mode   $modeTarget -> ${modeName(mode)}');
  print('  bypass           ${bypass ? "YES" : "NO"}');
}

Future<void> main(List<String> args) async {
  final modulePath = args.isNotEmpty ? args[0] : null;
  final moduleUri = args.length > 1 ? args[1] : '';

  final self = functionExecutionMode(host, 's1_virtual');
  print('ORACLE: s1_virtual -> ${modeName(self)}');
  if (self == kUnsupported) {
    print('G4: ORACLE UNSUPPORTED — this build has no dynamic modules');
    exitCode = 3;
    return;
  }
  if (self != kAot) {
    print('G4: ORACLE SELF-CHECK FAILED');
    exitCode = 4;
    return;
  }

  // ---- control pass: the HOST subtype, proving each site is executable.
  final hc = HostChild();
  // Warm the monomorphic site with the host implementation only. AOT has no
  // runtime feedback, so this cannot change codegen -- it is here so the shape
  // matches #41's description and so a reader can see it did not matter.
  var sink = 0;
  for (var i = 0; i < 200000; i++) {
    sink += s2_monomorphic(hc).length;
  }
  print('WARMUP: s2 called 200000x with HostChild (sink=$sink)');
  print("--- CONTROL: plain Base (the only host implementation) ---");
  shape('1_virtual', 'AOT-BASE', s1_virtual(hc), 'Base.execute', moduleUri, isPatch: false);
  shape('2_monomorphic', 'AOT-BASE', s2_monomorphic(hc), 'Base.execute', moduleUri, isPatch: false);
  shape('3_helper_chain', 'AOT-BASE', s3_chain_a(hc), 'Base.execute', moduleUri, isPatch: false);
  shape('4_bounded_generic', 'AOT-BASE', s4_generic<Base>(hc), 'Base.execute', moduleUri, isPatch: false);
  s5_field = hc;
  shape('5_field_receiver', 'AOT-BASE', s5_fieldCall(), 'Base.execute', moduleUri, isPatch: false);

  if (modulePath == null) {
    print('G4: control pass only (no module supplied)');
    return;
  }

  // ---- subject pass: the PATCH subtype through the very same sites.
  final bytes = Uint8List.fromList(File(modulePath).readAsBytesSync());
  final pc = await loadDynamicModule(bytes: bytes) as Base;
  print('--- SUBJECT: PatchChild ---');
  shape('1_virtual', 'PATCH-CHILD', s1_virtual(pc), 'PatchChild.execute', moduleUri, isPatch: true);
  shape('2_monomorphic', 'PATCH-CHILD', s2_monomorphic(pc), 'PatchChild.execute', moduleUri, isPatch: true);
  shape('3_helper_chain', 'PATCH-CHILD', s3_chain_a(pc), 'PatchChild.execute', moduleUri, isPatch: true);
  shape('4_bounded_generic', 'PATCH-CHILD', s4_generic<Base>(pc), 'PatchChild.execute', moduleUri, isPatch: true);
  s5_field = pc;
  shape('5_field_receiver', 'PATCH-CHILD', s5_fieldCall(), 'PatchChild.execute', moduleUri, isPatch: true);

  // A devirtualized host implementation must not be able to masquerade as
  // successful dynamic dispatch: if any subject shape returned HOST-CHILD or
  // AOT-BASE, that is a bypass regardless of how healthy the run looked.
  print('DONE');
}
