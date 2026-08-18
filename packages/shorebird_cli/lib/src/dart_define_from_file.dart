import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The option this file exists to expand.
const dartDefineFromFileOption = '--dart-define-from-file';

/// Flutter's `.env` grammar, transcribed from the pinned checkout.
///
/// `flutter_command.dart`, `abstract class DotEnvRegex` (`:37-60` at
/// `c15ef6379403a0a55531a058bdb2c8e55bc05c98`). Copied verbatim rather than
/// re-derived: every one of these is a decision about which characters end a
/// value, and rewriting them "equivalently" is how an expansion drifts from the
/// program that actually ships.
abstract class _DotEnvRegex {
  static final multiLineBlock = RegExp(
    r'^\s*([a-zA-Z_]+[a-zA-Z0-9_]*)\s*=\s*"""\s*(.*)$',
  );
  static final keyValue = RegExp(r'^\s*([a-zA-Z_]+[a-zA-Z0-9_]*)\s*=\s*(.*)?$');
  static final doubleQuotedValue = RegExp(r'^"(.*)"\s*(\#\s*.*)?$');
  static final singleQuotedValue = RegExp(r"^'(.*)'\s*(\#\s*.*)?$");
  static final backQuotedValue = RegExp(r'^`(.*)`\s*(\#\s*.*)?$');
  static final unquotedValue = RegExp(r'^([^#\n\s]*)\s*(?:\s*#\s*(.*))?$');
}

/// {@template dart_define_from_file_expansion}
/// What `--dart-define-from-file` contributes to a build's effective define
/// set, or the reason it could not be determined.
/// {@endtemplate}
class DartDefineFromFileExpansion {
  /// A successful expansion. [defines] is empty when the option was not used,
  /// which is a real answer and not a failure.
  const DartDefineFromFileExpansion.resolved(this.defines)
    : failureReason = null;

  /// The option was used and its meaning could not be determined.
  ///
  /// The caller must treat this as "unknown", never as "no defines": an empty
  /// set is a configuration a patch can match, and unknown is not. That
  /// distinction is the whole reason this returns a result object rather than a
  /// map.
  const DartDefineFromFileExpansion.failed(this.failureReason)
    : defines = const {};

  /// The defines the named files contribute, in Flutter's merge order.
  final Map<String, String> defines;

  /// Why the expansion could not be determined, or null when it could.
  final String? failureReason;

  /// Whether the expansion is usable.
  bool get ok => failureReason == null;

  /// Every path passed to [dartDefineFromFileOption] in [buildArgs], in order.
  ///
  /// Both spellings: our own CLI emits `--dart-define-from-file=<path>`
  /// (`arg_results.dart` `_argsNamed`), while a user writing
  /// `-- --dart-define-from-file path` reaches us as two arguments.
  static List<String> pathsIn(List<String> buildArgs) {
    final paths = <String>[];
    for (var i = 0; i < buildArgs.length; i++) {
      final arg = buildArgs[i];
      if (arg.startsWith('$dartDefineFromFileOption=')) {
        paths.add(arg.substring(dartDefineFromFileOption.length + 1));
      } else if (arg == dartDefineFromFileOption && i + 1 < buildArgs.length) {
        paths.add(buildArgs[i + 1]);
        i++;
      }
    }
    return paths;
  }

  /// Expands every `--dart-define-from-file` in [buildArgs].
  ///
  /// WHY THIS IS A PORT AND NOT A GUESS. Flutter parses these files with rules
  /// that are not obvious from the outside — `.env` values may be quoted three
  /// ways, a `#` ends an unquoted value but not a quoted one, and a JSON value
  /// that is not a string is stringified with Dart's own `toString`. So this
  /// transcribes `flutter_command.dart`'s `extractDartDefineConfigJsonMap`,
  /// `convertEnvFileToJsonRaw` and `_parseProperty` (`:1729-1849` at the pinned
  /// revision) rather than approximating them.
  ///
  /// AND A PORT IS STILL NOT EVIDENCE. The release path checks this expansion
  /// against the `DART_DEFINES` Flutter itself wrote for that same build and
  /// declines when the two disagree — see [disagreementWith]. That check, not
  /// this code's resemblance to its source, is what makes the option
  /// fingerprintable.
  static DartDefineFromFileExpansion expand(
    List<String> buildArgs, {
    String? workingDirectory,
  }) {
    final paths = pathsIn(buildArgs);
    if (paths.isEmpty) return const DartDefineFromFileExpansion.resolved({});

    // One map across all files, later files winning per key — Flutter merges
    // every file into a single `dartDefineConfigJsonMap` in argument order.
    final merged = <String, String>{};
    for (final path in paths) {
      final file = File(
        p.isAbsolute(path) || workingDirectory == null
            ? path
            : p.join(workingDirectory, path),
      );
      if (!file.existsSync()) {
        return DartDefineFromFileExpansion.failed(
          'did not find the file passed to $dartDefineFromFileOption: $path',
        );
      }

      final String raw;
      try {
        raw = file.readAsStringSync();
      } on FileSystemException catch (error) {
        return DartDefineFromFileExpansion.failed(
          'could not read $path: ${error.message}',
        );
      }

      // Flutter's own discriminator, and it is this crude: a leading `{` after
      // trimming means JSON, anything else means `.env`.
      final Map<String, dynamic> decoded;
      try {
        final jsonRaw = raw.trim().startsWith('{')
            ? raw
            : _envToJson(raw, path);
        decoded = jsonDecode(jsonRaw) as Map<String, dynamic>;
      } on _EnvFormatException catch (error) {
        return DartDefineFromFileExpansion.failed(error.message);
      } on FormatException catch (error) {
        return DartDefineFromFileExpansion.failed(
          'could not parse $path: ${error.message}',
        );
      } on TypeError {
        return DartDefineFromFileExpansion.failed(
          'the file at $path is not a JSON object',
        );
      }

      decoded.forEach((key, value) {
        // `'$value'`, exactly as Flutter's `extractDartDefines` writes
        // `'$key=$value'`. A JSON number, bool, null or nested object reaches
        // the compiler as its Dart `toString`, so `{"a":{"b":1}}` defines
        // `a={b: 1}`. Surprising, and reproducing the surprise is the point.
        merged[key] = '$value';
      });
    }
    return DartDefineFromFileExpansion.resolved(Map.unmodifiable(merged));
  }

  /// Converts a `.env` body to the JSON Flutter would convert it to.
  static String _envToJson(String raw, String path) {
    final lines = raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where((line) => !line.startsWith('#'))
        .toList();

    final properties = <String, String>{};
    for (final line in lines) {
      if (_DotEnvRegex.multiLineBlock.hasMatch(line)) {
        throw _EnvFormatException(
          'multi-line values are not supported by Flutter, in $path: $line',
        );
      }
      final keyValue = _DotEnvRegex.keyValue.firstMatch(line);
      if (keyValue == null) {
        throw _EnvFormatException('invalid property line in $path: $line');
      }
      final key = keyValue.group(1)!;
      final value = keyValue.group(2) ?? '';

      // Quote stripping, in Flutter's order. A quoted value keeps a `#` that an
      // unquoted one would treat as the start of a comment, which is why the
      // order matters and why all four are kept.
      final double = _DotEnvRegex.doubleQuotedValue.firstMatch(value);
      if (double != null) {
        properties[key] = double.group(1)!;
        continue;
      }
      final single = _DotEnvRegex.singleQuotedValue.firstMatch(value);
      if (single != null) {
        properties[key] = single.group(1)!;
        continue;
      }
      final back = _DotEnvRegex.backQuotedValue.firstMatch(value);
      if (back != null) {
        properties[key] = back.group(1)!;
        continue;
      }
      final unquoted = _DotEnvRegex.unquotedValue.firstMatch(value);
      properties[key] = unquoted != null ? unquoted.group(1)! : value;
    }
    return jsonEncode(properties);
  }

  /// The keys on which this expansion disagrees with [flutterResolved], which
  /// is the define set Flutter itself wrote for the same build.
  ///
  /// Empty means agreement, which is what licenses treating the option as
  /// fingerprintable for that release.
  ///
  /// [exempt] names keys that are expected to differ and why the caller says so
  /// — `FLUTTER_APP_FLAVOR` is the standing case, because Flutter rewrites it at
  /// the xcodebuild stage from the Xcode CONFIGURATION (the scheme's own casing)
  /// after the value in `Generated.xcconfig` was already written from the CLI
  /// token. Measured on `selfhost/fixtures/flavored_app`: the xcconfig carries
  /// `FLUTTER_APP_FLAVOR=foo` for the build whose shipped kernel contains `Foo`.
  ///
  /// Keys present only in [flutterResolved] are NOT a disagreement: Flutter
  /// injects `FLUTTER_VERSION` and its siblings into every build, and this
  /// expansion is only responsible for what the files said.
  List<String> disagreementWith(
    Map<String, String> flutterResolved, {
    Set<String> exempt = const {},
  }) {
    final disagreeing = <String>[];
    for (final entry in defines.entries) {
      if (exempt.contains(entry.key)) continue;
      final theirs = flutterResolved[entry.key];
      if (theirs != entry.value) disagreeing.add(entry.key);
    }
    return disagreeing..sort();
  }

  /// Decodes the `DART_DEFINES` line of an `ios/Flutter/Generated.xcconfig`.
  ///
  /// Flutter writes it as base64-encoded `KEY=VALUE` entries joined by commas
  /// (`build_info.dart` `toEnvironmentConfig` `:396`, via
  /// `ios/xcode_build_settings.dart:265`). Returns null when the file has no
  /// such line, which is a real state: a build with no defines at all omits it
  /// (`if (dartDefines.isNotEmpty)`).
  static Map<String, String>? decodeGeneratedXcconfig(File xcconfig) {
    if (!xcconfig.existsSync()) return null;
    final List<String> lines;
    try {
      lines = xcconfig.readAsLinesSync();
    } on FileSystemException {
      return null;
    }
    for (final line in lines) {
      if (!line.startsWith('DART_DEFINES=')) continue;
      final body = line.substring('DART_DEFINES='.length).trim();
      final resolved = <String, String>{};
      for (final encoded in body.split(',')) {
        if (encoded.isEmpty) continue;
        final String decoded;
        try {
          decoded = utf8.decode(base64.decode(encoded));
        } on Object {
          return null;
        }
        final eq = decoded.indexOf('=');
        // Same rule as `--dart-define=K`: no `=` means defined-empty.
        final key = eq < 0 ? decoded : decoded.substring(0, eq);
        if (key.isEmpty) continue;
        resolved[key] = eq < 0 ? '' : decoded.substring(eq + 1);
      }
      return resolved;
    }
    return null;
  }
}

/// Thrown internally so a malformed `.env` reads as a named failure rather than
/// as a JSON error about a file the user never wrote as JSON.
class _EnvFormatException implements Exception {
  const _EnvFormatException(this.message);
  final String message;
}
