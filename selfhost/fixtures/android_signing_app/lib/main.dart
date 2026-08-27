// B2's fixture: the smallest patchable app that carries a deliberately
// configured NON-DEBUG Android release signing identity.
//
// Arm B asks whether publishing a patch mutates the signed release artifact. The
// app's behaviour is irrelevant to that question; it only has to be releasable
// and patchable. So this is deliberately minimal, and it is a NEW fixture rather
// than an edit to a certified one.
//
// The marker sits in a function body with a DateTime guard so a patch to it is
// visible to the analyzer rather than folded into a constant -- the constant
// blindness that cost two release cycles earlier in P6.

import 'package:flutter/material.dart';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String markerText() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'ANDROID-SIGN-V1'
    : 'ANDROID-SIGN-V1!';

void main() => runApp(const SigningProbeApp());

class SigningProbeApp extends StatelessWidget {
  const SigningProbeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Text(markerText(), style: const TextStyle(fontSize: 24)),
      ),
    ),
  );
}
