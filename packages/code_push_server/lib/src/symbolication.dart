// cspell:words symbolicate symbolicated symbolication dwarf armeabi
import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:meta/meta.dart';
import 'package:native_stack_traces/native_stack_traces.dart';

/// Resolves the obfuscated frames in a crash report's Dart stack trace against
/// the debug symbols retained for the patch that produced it.
///
/// Deliberately **not** `llvm-symbolizer` or `atos`. What the CLI retains is
/// Dart's own `--split-debug-info` output, which is what `flutter symbolize`
/// consumes via `package:native_stack_traces` — pure Dart, and able to read
/// both the ELF form (Android) and the Mach-O form (Apple). So one
/// implementation covers every platform inside this Linux container, with no
/// native toolchain and no Mac worker. `atos` would only be needed for native
/// Objective-C/C++ frames out of a dSYM, and a Dart crash handler does not
/// produce those.
///
/// Resolution happens at **read** time, never at ingest. Two reasons: ingest
/// must stay unfailable (`POST /crashes` is called by an app that just died),
/// and symbols are frequently uploaded *after* a crash has already arrived, so
/// an ingest-time attempt would permanently miss.
class Symbolizer {
  /// Creates a symbolizer reading symbol artifacts from [store].
  Symbolizer({required ArtifactStore store, int cacheSize = 4})
    : _store = store,
      _cacheSize = cacheSize;

  final ArtifactStore _store;

  /// How many parsed [Dwarf] objects to retain. Small on purpose: parsing is
  /// the expensive part so caching pays off across a page of crashes sharing
  /// one patch, but a parsed symbol set is large in memory and holding many
  /// would trade a latency win for an OOM.
  final int _cacheSize;

  /// Parsed symbol sets keyed by `<artifact id>:<entry name>`, in insertion
  /// order so the oldest can be evicted.
  final _cache = <String, Dwarf>{};

  /// Symbol sets that failed to load, so a broken or unparseable artifact is
  /// not re-fetched and re-parsed on every request. Bounded the same way.
  final _failed = <String>{};

  /// Returns [stack] with its frames resolved to `library:line` form, or `null`
  /// if it could not be symbolicated — an absent or unreadable symbol set, no
  /// entry matching [arch], or a trace carrying no resolvable frames.
  ///
  /// Never throws. A crash report that cannot be symbolicated is still worth
  /// showing raw, so every failure path degrades to `null` and leaves the
  /// caller's original stack in place.
  Future<String?> symbolicate({
    required String stack,
    required ArtifactRow symbols,
    String? arch,
  }) async {
    try {
      final dwarf = await _dwarfFor(symbols, arch);
      if (dwarf == null) return null;

      final decoded = await Stream.fromIterable(stack.split('\n'))
          .transform(DwarfStackTraceDecoder(dwarf, includeInternalFrames: true))
          .join('\n');

      // The decoder passes unrecognized input through untouched, so an
      // unchanged result means nothing was actually resolved. Reporting that as
      // "symbolicated" would imply a fidelity the output does not have.
      if (decoded == stack) return null;

      return decoded;
    } on Object {
      // Includes FormatException from a truncated archive and anything the
      // DWARF reader throws on malformed input.
      return null;
    }
  }

  /// Loads and caches the [Dwarf] for [symbols], picking the entry matching
  /// [arch].
  Future<Dwarf?> _dwarfFor(ArtifactRow symbols, String? arch) async {
    final archive = await _readArchive(symbols);
    if (archive == null) return null;

    final entry = selectEntry(archive, arch);
    if (entry == null) return null;

    final key = '${symbols.id}:${entry.name}';
    if (_failed.contains(key)) return null;
    final cached = _cache[key];
    if (cached != null) return cached;

    final dwarf = Dwarf.fromBytes(
      Uint8List.fromList(entry.content as List<int>),
    );
    if (dwarf == null) {
      _rememberFailure(key);
      return null;
    }

    if (_cache.length >= _cacheSize) _cache.remove(_cache.keys.first);
    _cache[key] = dwarf;
    return dwarf;
  }

  /// Reads and decodes the symbol zip for [symbols], or null if unreadable.
  Future<Archive?> _readArchive(ArtifactRow symbols) async {
    final bytes = <int>[];
    final stream = await _store.openRead(symbols.storageKey);
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    if (bytes.isEmpty) return null;
    return ZipDecoder().decodeBytes(bytes);
  }

  /// Picks the `.symbols` entry for [arch].
  ///
  /// Apple retains a single file (the CLI writes `app.ios-arm64.symbols` for
  /// both iOS and macOS), so the common case needs no matching at all. Android
  /// retains one per ABI, which does.
  @visibleForTesting
  static ArchiveFile? selectEntry(Archive archive, String? arch) {
    final candidates = archive.files
        .where((f) => f.isFile && f.name.endsWith('.symbols'))
        .toList();
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;

    final token = archToken(arch);
    if (token != null) {
      for (final f in candidates) {
        // Suffix match, not `contains`: `arm` is a prefix of `arm64`, so
        // `contains('arm')` would hand back arm64 symbols for an arm32 crash
        // and resolve every frame to the wrong address.
        if (f.name.endsWith('-$token.symbols')) return f;
      }
    }

    // Several entries and no arch match: guessing would produce confidently
    // wrong line numbers, which is worse than an unresolved trace.
    return null;
  }

  /// Maps a reported architecture onto the token Flutter puts in a symbol
  /// filename (`app.android-<token>.symbols`).
  ///
  /// Liberal in what it accepts because the value originates on-device and
  /// several spellings are in circulation: the CLI's own artifact names
  /// (`aarch64`, `arm`, `x86_64`), Android ABI names (`arm64-v8a`), and
  /// Flutter's target names (`arm64`, `x64`).
  @visibleForTesting
  static String? archToken(String? arch) {
    switch (arch?.toLowerCase()) {
      case 'arm64':
      case 'aarch64':
      case 'arm64-v8a':
        return 'arm64';
      case 'arm':
      case 'arm32':
      case 'armv7':
      case 'armeabi-v7a':
        return 'arm';
      case 'x64':
      case 'x86_64':
        return 'x64';
      default:
        return null;
    }
  }

  void _rememberFailure(String key) {
    if (_failed.length >= _cacheSize) _failed.remove(_failed.first);
    _failed.add(key);
  }
}
