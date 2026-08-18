import 'package:flutter/material.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Bumped by each patch, so "the patch's CODE ran" is a separate reading from
/// "a patch number appeared". G6's whole question is WHICH patch arrived, and
/// a number alone cannot answer that once two patches exist.
///
///   release        TRACKPROBE-V1
///   patch 1        TRACKPROBE-STABLE   published to track `stable`
///   patch 2        TRACKPROBE-BETA     published to track `beta`   (NEWER)
///
/// The ordering is deliberate and is the whole experiment: beta's patch is the
/// NEWER one, so a device asking for `stable` that receives BETA has proved
/// tracks are ignored and latest-wins. See README.md.
const marker = 'TRACKPROBE-V1';

void main() => runApp(const TrackProbeApp());

class TrackProbeApp extends StatefulWidget {
  const TrackProbeApp({super.key});
  @override
  State<TrackProbeApp> createState() => _TrackProbeAppState();
}

class _TrackProbeAppState extends State<TrackProbeApp> {
  final _updater = ShorebirdUpdater();

  String _current = '?';
  String _next = '?';
  String _log = 'idle';

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

  /// Named tracks are reachable from Dart even though the compiled
  /// `shorebird.yaml` never carries `channel` — that is exactly the route
  /// PARITY's G6 device row points at. `UpdateTrack` is an extension type over
  /// String, so an arbitrary track name is expressible here.
  Future<void> _check(UpdateTrack track) async {
    setState(() => _log = 'checking ${track.name}…');
    try {
      final s = await _updater.checkForUpdate(track: track);
      setState(() => _log = 'check(${track.name}) -> $s');
    } on Object catch (e) {
      setState(() => _log = 'check(${track.name}) threw: $e');
    }
    await _refresh();
  }

  Future<void> _update(UpdateTrack track) async {
    setState(() => _log = 'updating ${track.name}…');
    try {
      await _updater.update(track: track);
      setState(() => _log = 'update(${track.name}) returned');
    } on Object catch (e) {
      setState(() => _log = 'update(${track.name}) threw: $e');
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
              Text(marker, style: const TextStyle(fontSize: 26)),
              const SizedBox(height: 12),
              Text(
                'current patch: $_current',
                style: const TextStyle(fontSize: 20),
              ),
              Text('next patch: $_next', style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_log, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => _check(UpdateTrack.stable),
                    child: const Text('check stable'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => _update(UpdateTrack.stable),
                    child: const Text('update stable'),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => _check(UpdateTrack.beta),
                    child: const Text('check beta'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => _update(UpdateTrack.beta),
                    child: const Text('update beta'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
