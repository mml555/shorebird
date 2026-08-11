// Route B (selfhost): reading the coverage analysis, and deciding what to say.
//
// The analysis itself is NOT here and cannot be. It has to read a dill, which
// needs `package:kernel`, which is unobtainable outside an engine checkout: the
// copy on pub.dev is the abandoned pre-null-safety publication, and the vended
// Flutter SDK ships no `pkg/` at all. It also has to read a dill emitted by the
// RELEASE's frontend, and the kernel binary format is versioned — so the
// analyzer belongs to the release's toolchain for the same reason dart2bytecode
// does, and travels in the same cell.
//
// What lives here is everything downstream of that: parsing the analyzer's
// output, and turning a verdict into something a person can act on. That is a
// small surface and a dangerous one — mapping `conditional` to "representable",
// or losing which target was rejected, would be indistinguishable from the
// analyzer being wrong. `selfhost/engine/route_b/coverage/parity.sh` runs the
// untouched host tools, this analyzer, and this parser over one corpus and
// fails on any field that differs.
import 'dart:convert';
import 'dart:io';

import 'package:scoped_deps/scoped_deps.dart';

import 'package:shorebird_cli/src/route_b_compiler.dart';

/// A reference to a [RouteBCoverageAnalyzer] instance.
final routeBCoverageAnalyzerRef = create(RouteBCoverageAnalyzer.new);

/// The [RouteBCoverageAnalyzer] available in the current zone.
RouteBCoverageAnalyzer get routeBCoverageAnalyzer =>
    read(routeBCoverageAnalyzerRef);

/// The analyzer contract this build understands.
///
/// Refused rather than best-effort parsed: a cell is resolved by the release's
/// engine hash, so an unknown version means the CLI and the release's toolchain
/// disagree about the format, and reading fields that may have moved is how you
/// get a confident wrong answer.
const supportedRouteBAnalysisVersion = 6;

/// What a patch may do with a changed member.
enum RouteBRepresentability {
  /// Static-shaped call. Emitted as the patchable form.
  representable,

  /// Instance member. Reachable only where the call site devirtualizes.
  ///
  /// **Not a verdict.** Whether a given site devirtualizes or becomes a
  /// dispatch-table call is decided per-site by the precompiler and is not
  /// visible in the kernel, so this is an honest "cannot tell from here" rather
  /// than a quiet yes. See [RouteBCoverage.conditional].
  conditional,

  /// The release cannot reach it at all.
  unreachable,

  /// Not in the release's manifest. Unknown reachability is not reachability.
  unknown,

  /// New in the patch. A patch replaces bodies; it cannot introduce members.
  added,
}

/// One member the patch cannot carry, and why.
///
/// The reason is carried verbatim from the analyzer rather than re-derived
/// here. `Foo.bar -> unsupported dispatch-table call` and
/// `Foo.bar -> target unreachable` both reject, and they are not
/// interchangeable: one points at compiler coverage, the other at retention.
class RouteBRejection {
  /// {@macro route_b_rejection}
  const RouteBRejection({
    required this.target,
    required this.category,
    required this.reason,
  });

  /// `library#selector`, the same identity the container packs by.
  final String target;

  /// Which rule rejected it.
  final RouteBRepresentability category;

  /// The analyzer's own wording.
  final String reason;
}

/// Where a changed member's new body lives in the patch's own source.
///
/// A span rather than text: the analyzer has the kernel's offsets, the producer
/// has the file, and neither needs an opinion about how a replacement library
/// is assembled.
class RouteBSourceSpan {
  /// {@macro route_b_source_span}
  const RouteBSourceSpan({
    required this.fileUri,
    required this.start,
    required this.end,
  });

  /// The file the frontend read, as a URI.
  final String fileUri;

  /// Byte offset of the declaration, annotations included.
  final int start;

  /// Byte offset just past its closing token.
  final int end;
}

/// One receiver-based access the producer must rewrite.
class RouteBReceiverAccess {
  /// {@macro route_b_receiver_access}
  const RouteBReceiverAccess({
    required this.offset,
    required this.member,
    required this.kind,
  });

  /// Where the member's IDENTIFIER starts, in code units of the decoded
  /// source. `label` and `this.label` are the same Kernel node and report the
  /// same offset, so only the source text distinguishes them.
  final int offset;

  /// The member being read or called.
  final String member;

  /// `get` for `label`, `set` for `label = x`, `invoke` for `helper()` with or
  /// without arguments. The
  /// argument list is copied verbatim and never interpreted, so its shape is
  /// not part of what the lowering has to understand. The surface
  /// widens one form at a time, and the producer refuses a kind it does not
  /// know rather than assuming its lexical edit happens to suit.
  final String kind;
}

/// What Kernel knows about turning an instance method into a static
/// replacement that takes its receiver as argument 0.
///
/// Kernel decides MEANING — which accesses are receiver-based, what they
/// resolve to, where their identifier starts. The producer supplies SYNTAX.
/// Neither re-derives the other's job.
class RouteBLowering {
  /// {@macro route_b_lowering}
  const RouteBLowering({
    required this.receiverType,
    required this.nameOffset,
    required this.accesses,
    required this.unsupported,
  });

  /// The class the receiver belongs to, used as the parameter's type.
  final String receiverType;

  /// Offset of the method's NAME. The producer scans forward from here for the
  /// parameter list, because an annotation like `@pragma('vm:never-inline')`
  /// has parentheses of its own.
  final int nameOffset;

  /// Every receiver access to rewrite.
  final List<RouteBReceiverAccess> accesses;

  /// Reasons this body is outside the supported surface. Non-empty means
  /// refuse by name rather than lower on a guess.
  final List<String> unsupported;
}

/// The whole-patch outcome.
enum RouteBVerdict {
  /// Every changed member can be carried.
  accept,

  /// At least one cannot, so none of them ship.
  reject,

  /// Nothing changed. A patch would install and do nothing.
  inert,
}

/// The analyzer's output, parsed.
class RouteBCoverage {
  /// {@macro route_b_coverage}
  const RouteBCoverage({
    required this.verdict,
    required this.changed,
    required this.added,
    required this.removed,
    required this.representable,
    required this.conditional,
    required this.rejections,
    required this.refusalSummary,
    this.sources = const {},
    this.lowering = const {},
  });

  /// Parses the analyzer's JSON document.
  ///
  /// Throws [FormatException] on anything it does not fully understand.
  factory RouteBCoverage.fromJson(String contents) {
    final Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } on FormatException catch (error) {
      throw FormatException(
        'the coverage analyzer did not emit JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'the coverage analyzer did not emit a JSON object',
      );
    }

    final version = decoded['analysisVersion'];
    if (version != supportedRouteBAnalysisVersion) {
      throw FormatException(
        'the coverage analyzer speaks version $version, and this build of '
        'Shorebird understands $supportedRouteBAnalysisVersion',
      );
    }

    final map = decoded;
    List<String> strings(String key) {
      final value = map[key];
      if (value is! List) {
        throw FormatException('the analysis is missing "$key"');
      }
      return value.cast<String>();
    }

    final verdict = switch (map['verdict']) {
      'accept' => RouteBVerdict.accept,
      'reject' => RouteBVerdict.reject,
      'inert' => RouteBVerdict.inert,
      final Object? other => throw FormatException(
        'the analysis carries an unknown verdict "$other"',
      ),
    };

    final rejections = <RouteBRejection>[];
    for (final entry in (map['rejections'] as List<Object?>? ?? const [])) {
      final rejection = entry! as Map<String, dynamic>;
      rejections.add(
        RouteBRejection(
          target: rejection['target']! as String,
          category: switch (rejection['category']) {
            'unreachable' => RouteBRepresentability.unreachable,
            'unknown' => RouteBRepresentability.unknown,
            'added' => RouteBRepresentability.added,
            final Object? other => throw FormatException(
              'the analysis carries an unknown rejection category "$other"',
            ),
          },
          reason: rejection['reason']! as String,
        ),
      );
    }

    // A reject with nothing to point at is a contract violation, not a patch
    // failure. Refusing with "something was wrong" is the failure mode the
    // whole reason-carrying design exists to avoid.
    if (verdict == RouteBVerdict.reject && rejections.isEmpty) {
      throw const FormatException(
        'the analysis rejects the patch but names no target',
      );
    }

    final sources = <String, RouteBSourceSpan>{};
    if (map['sources'] case final Map<String, dynamic> recorded) {
      for (final entry in recorded.entries) {
        final span = entry.value as Map<String, dynamic>;
        sources[entry.key] = RouteBSourceSpan(
          fileUri: span['fileUri']! as String,
          start: span['start']! as int,
          end: span['end']! as int,
        );
      }
    }

    final lowering = <String, RouteBLowering>{};
    if (map['lowering'] case final Map<String, dynamic> recorded) {
      for (final entry in recorded.entries) {
        final l = entry.value as Map<String, dynamic>;
        lowering[entry.key] = RouteBLowering(
          receiverType: l['receiverType']! as String,
          nameOffset: l['nameOffset']! as int,
          accesses: [
            for (final a in (l['accesses'] as List<Object?>? ?? const []))
              RouteBReceiverAccess(
                offset: (a! as Map<String, dynamic>)['offset']! as int,
                member: (a as Map<String, dynamic>)['member']! as String,
                kind: a['kind']! as String,
              ),
          ],
          unsupported: [
            for (final u in (l['unsupported'] as List<Object?>? ?? const []))
              u! as String,
          ],
        );
      }
    }

    return RouteBCoverage(
      verdict: verdict,
      sources: sources,
      lowering: lowering,
      changed: strings('changed'),
      added: strings('added'),
      removed: strings('removed'),
      representable: strings('patchable'),
      conditional: strings('conditional'),
      rejections: rejections,
      refusalSummary: map['refusalSummary'] as String?,
    );
  }

  /// The whole-patch outcome.
  final RouteBVerdict verdict;

  /// Members whose compiled form differs from the release's.
  final List<String> changed;

  /// Members the patch introduces. Always a rejection.
  final List<String> added;

  /// Members the patch drops. Reported, never fatal: the release keeps them and
  /// nothing calls them from the patch's own code.
  final List<String> removed;

  /// Changed members that are static-shaped, and so genuinely patchable.
  final List<String> representable;

  /// Changed instance members, which the kernel cannot decide.
  ///
  /// **These ship.** That is the reference tooling's behaviour, preserved
  /// deliberately rather than tightened here: deciding them needs per-call-site
  /// data from the release snapshot, which no kernel carries. Tightening it to
  /// a refusal without that data would reject every instance-member patch,
  /// including the ones that work today.
  final List<String> conditional;

  /// Every member that cannot be carried, with the analyzer's own reason.
  final List<RouteBRejection> rejections;

  /// The analyzer's aggregate refusal line, if it refused.
  final String? refusalSummary;

  /// Where each changed member's new body lives, by `library#selector`.
  final Map<String, RouteBSourceSpan> sources;

  /// Implicit-`this` lowering facts, for changed INSTANCE members only.
  final Map<String, RouteBLowering> lowering;

  /// The refusal, as the user will read it.
  ///
  /// Names every rejected target and its reason. A count would be worse than
  /// useless here: "1 changed member is not reachable" tells you a patch failed
  /// and gives you nowhere to go.
  String get refusalMessage {
    final buffer = StringBuffer()
      ..writeln(
        'This patch cannot be built: ${rejections.length} of '
        '${changed.length + added.length} changed members cannot be carried by '
        'a Route B patch.',
      )
      ..writeln();
    for (final rejection in rejections) {
      buffer.writeln('  ${rejection.target}');
      buffer.writeln('      ${rejection.reason}');
    }
    buffer
      ..writeln()
      ..write(
        'The whole patch is refused, not the part that failed. Shipping the '
        'rest would leave your app running some functions from the patch and '
        'some from the release. Nothing was uploaded.',
      );
    return buffer.toString();
  }
}

/// Runs the coverage analyzer out of a resolved compiler cell.
///
/// [compiler] is the cell belonging to the RELEASE's engine, so the analyzer
/// reading these dills is version-matched to the frontend that wrote them.
class RouteBCoverageAnalyzer {
  /// {@macro route_b_coverage_analyzer}
  const RouteBCoverageAnalyzer();

  /// Analyze the change between [baseDill] and [patchedDill].
  RouteBCoverage analyze({
    required RouteBCompiler compiler,
    required File baseDill,
    required File patchedDill,
    List<String> includePrefixes = const [],
  }) {
    final result = Process.runSync(compiler.runtime.path, [
      compiler.analyzer.path,
      '--base-dill',
      baseDill.path,
      '--patched-dill',
      patchedDill.path,
      for (final prefix in includePrefixes) ...['--include', prefix],
    ]);

    if (result.exitCode != 0) {
      throw RouteBCompilerException(
        RouteBCompilerProblem.invalid,
        '''
The Route B coverage analyzer failed (exit ${result.exitCode}):

${result.stderr}

Treat this as corruption or a bad cache, not as a problem with the release.
Nothing was uploaded.''',
      );
    }

    return RouteBCoverage.fromJson(result.stdout as String);
  }
}
