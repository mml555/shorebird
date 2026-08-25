// P1's device specimen: a patch to a method of a conventionally PRIVATE Flutter
// State class, whose replacement body consumes explicitly granted private
// members of that class.
//
// WHY A FOURTH-AND-A-BIT FIXTURE. This must not be killswitch_app: that app's
// events feed the FROZEN lifecycle estimator (MEASUREMENT_MODE.md), and an
// engineering qualification launch has no business entering fleet-policy
// evidence. Its own app id keeps it out by construction rather than by adding
// another exclusion rule afterwards.
//
// THE PRECOMMITTED SHAPE. Patch `target()` only. The replacement must consume
// all three private capabilities and render one unmistakable string.
//
//   release  -> OLD
//   patch    -> NEW-FLD-GET-MTH
//   control  -> unchanged in both
// ignore_for_file: unused_field, unused_element
//
// FOUR ANALYZER WARNINGS, ALL INTENDED, AND THEY ARE THE SPECIMEN'S SHAPE.
// `_field`, `_getter` and `_method` are unreferenced BY THE RELEASE: the release
// does not call them, the interface grant is what retains them, and the PATCH is
// what will call them. That is the production shape -- a release cannot know
// which of its privates a future patch will reach, so retention comes from the
// interface naming them rather than from a call site. `_withheld` is referenced
// only through a dynamic receiver, which the analyzer cannot see and which is
// precisely why it survives TFA as a dispatchable member.
//
// Silencing these with a reason beats restructuring the fixture to please the
// analyzer, because every restructuring would change what is being measured.
import 'package:flutter/material.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: ProbeHome(), title: 'PrivateState Probe');
}

class ProbeHome extends StatefulWidget {
  const ProbeHome({super.key});

  @override
  State<ProbeHome> createState() => _FooState();
}

// The idiomatic Flutter shape, and the whole point: the State class is PRIVATE
// by convention, so a replacement compiled as its own library cannot name it and
// is lowered to a `dynamic` receiver. Every value routes through DateTime.now()
// so TFA cannot fold it to a literal -- a folded constant once made a working
// mechanism report OLD.
class _FooState extends State<ProbeHome> {
  final String _field =
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'FLD' : 'X';

  String get _getter =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'GET' : 'X';

  @pragma('vm:never-inline')
  String _method() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'MTH' : 'X';

  // THE NEGATIVE CONTROL, and it is deliberately UNUSED by the positive patch.
  // Its job is to exist in the release while being WITHHELD from the interface,
  // so the release itself carries evidence that ungranted private reach is
  // withheld rather than absent. The runtime refusal is already proven on the
  // host -- `probes/p1_bind_private_receiver.sh` arm B4b -- so nothing here has
  // to crash a device to make the point.
  @pragma('vm:never-inline')
  String _withheld() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'WTH' : 'X';

  // THE PATCH TARGET. A public method of a private class, which is what a real
  // Flutter patch almost always is.
  @pragma('vm:never-inline')
  String target() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

  // P2's target: the target's OWN required positional parameters. The release
  // body ignores them deliberately, so `OLD` cannot depend on argument binding
  // and only the replacement's value can.
  //
  // Called with deliberately ASYMMETRIC values -- 'A' and 7 -- so that an
  // argument swap cannot masquerade as success: swapped binding would render
  // `NEW-7-A-...`, which is a different string, not a plausible one.
  @pragma('vm:never-inline')
  String targetArgs(String label, int count) => 'NEW-$label-$count-$_field';

  // The unrelated same-screen control. Must read `CTL` before and after.
  @pragma('vm:never-inline')
  String control() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'CTL' : 'X';

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('target=${target()}', style: const TextStyle(fontSize: 34)),
          const SizedBox(height: 16),
          Text("args=${targetArgs('A', 7)}",
              style: const TextStyle(fontSize: 30)),
          const SizedBox(height: 16),
          Text('control=${control()}', style: const TextStyle(fontSize: 22)),
          const SizedBox(height: 16),
          // Keeps `_withheld` live in the program without granting it: the
          // release calls it through a DYNAMIC receiver, so nothing can inline
          // or devirtualize the member away. Same construction as B4b.
          Text('kept=${_keepWithheldLive()}',
              style: const TextStyle(fontSize: 14)),
        ],
      ),
    ),
  );

  @pragma('vm:never-inline')
  String _keepWithheldLive() {
    final dynamic self = this;
    return self._withheld() as String;
  }
}
