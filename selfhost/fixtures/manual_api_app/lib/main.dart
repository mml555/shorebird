import 'package:flutter/material.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Bumped by a patch, so "the patch's CODE ran" is a separate reading from
/// "a patch number appeared".
const marker = 'MANUALAPI-V1';

void main() => runApp(const ManualApiApp());

class ManualApiApp extends StatefulWidget {
  const ManualApiApp({super.key});
  @override
  State<ManualApiApp> createState() => _ManualApiAppState();
}

class _ManualApiAppState extends State<ManualApiApp> {
  final _updater = ShorebirdUpdater();

  String _current = '?';
  String _next = '?';
  String _status = 'idle';
  // PRECOMMITTED OUTCOME 9: a number on screen is not evidence. What matters is
  // that it CHANGED across an update() we made. Captured before the call.
  String _before = '?';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final cur = await _updater.readCurrentPatch();
    final nxt = await _updater.readNextPatch();
    setState(() {
      _current = cur?.number.toString() ?? 'none';
      _next = nxt?.number.toString() ?? 'none';
    });
  }

  Future<void> _check() async {
    setState(() => _status = 'checking…');
    try {
      final s = await _updater.checkForUpdate(track: UpdateTrack.stable);
      setState(() => _status = 'checkForUpdate -> $s');
    } on Object catch (e) {
      setState(() => _status = 'checkForUpdate threw: $e');
    }
    await _refresh();
  }

  Future<void> _update() async {
    _before = _current;
    setState(() => _status = 'updating…');
    try {
      await _updater.update(track: UpdateTrack.stable);
      setState(() => _status = 'update() returned');
    } on Object catch (e) {
      setState(() => _status = 'update threw: $e');
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(marker, style: const TextStyle(fontSize: 24)),
                  const SizedBox(height: 12),
                  Text('current patch: $_current',
                      style: const TextStyle(fontSize: 20)),
                  Text('next patch: $_next',
                      style: const TextStyle(fontSize: 20)),
                  Text('before update(): $_before',
                      style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(_status, textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                      onPressed: _check, child: const Text('checkForUpdate')),
                  ElevatedButton(
                      onPressed: _update, child: const Text('update()')),
                ],
              ),
            ),
          ),
        ),
      );
}
