// Canonical air-gap acceptance fixture.
//
// Renders exactly the three facts the acceptance run asserts, each on its own
// line and each greppable from a screenshot:
//
//   release state  — a constant compiled into the release. A CODE patch
//                    changes it; an assets-only patch must NOT.
//   asset state    — assets/probe.json read through rootBundle. An
//                    assets-only patch changes it.
//   patch number   — from the updater. null when unpatched.
//
// Keeping code state and asset state on separate lines is what makes an
// assets-only patch distinguishable from a code patch at a glance: the iOS
// leg publishes assets-only, so the correct result there is a CHANGED asset
// line beside an UNCHANGED release line.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shorebird_code_push/shorebird_code_push.dart';

// Bump the suffix in a CODE patch to prove patched Dart is executing.
const String kReleaseState = 'AIRGAP-FIXTURE-V1';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Scaffold(body: SafeArea(child: ProbeBody())));
}

class ProbeBody extends StatefulWidget {
  const ProbeBody({super.key});

  @override
  State<ProbeBody> createState() => _ProbeBodyState();
}

class _ProbeBodyState extends State<ProbeBody> {
  String _asset = 'reading…';
  String _patch = 'reading…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String asset;
    try {
      final raw = await rootBundle.loadString('assets/probe.json');
      asset = (jsonDecode(raw) as Map<String, dynamic>)['origin'].toString();
    } on Object catch (e) {
      asset = 'ERROR: $e';
    }

    String patch;
    try {
      // Never let a missing/!available updater blank the screen — an
      // unreadable patch number is itself a result worth seeing.
      final updater = ShorebirdUpdater();
      final current = await updater.readCurrentPatch();
      patch = current?.number.toString() ?? 'null';
    } on Object catch (e) {
      patch = 'ERROR: $e';
    }

    if (mounted) setState(() {
      _asset = asset;
      _patch = patch;
    });
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('release state:', style: TextStyle(fontSize: 14)),
          Text(kReleaseState,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          const Text('asset state:', style: TextStyle(fontSize: 14)),
          Text(_asset,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          const Text('patch number:', style: TextStyle(fontSize: 14)),
          Text(_patch,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ],
      ),
    ),
  );
}
