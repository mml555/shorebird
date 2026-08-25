// Route B (selfhost) P4.3: the replacement ABI boundary, as a stable contract.
//
// The boundary itself is not new -- the analyzer has refused named parameters,
// optional positionals and generics since G3.7, and required positionals became
// supported there. What was missing is a name for each refusal that survives a
// copy edit. Pinning the analyzer's prose character-for-character would make
// wording changes painful and would still not say what a caller may rely on; so
// the PROSE stays free and the CODE is the contract.
//
// WHY THE MAPPING LIVES HERE AND NOT IN THE CELL. The refusal text is produced
// by the coverage analyzer, which ships in the compiler cell and is versioned
// with the release's frontend. Teaching it codes would mean a mint for a
// product-layer naming decision, and would freeze the vocabulary into artifacts
// that outlive it. The product classifies; the cell keeps reporting facts.
//
// THE FAILURE MODE THIS MUST NOT HAVE. If a future cell rewords a reason, the
// mapping stops recognising it. That must not quietly become "supported": an
// unrecognised reason is `RouteBAbiCode.unclassified`, which still REFUSES
// and says the wording was not recognised, so the gap is visible as a gap.

/// Which ABI rule refused a target, in a form that survives rewording.
enum RouteBAbiCode {
  /// The parameter list itself cannot be carried: named or optional positional.
  ///
  /// Required positionals are SUPPORTED and never produce a refusal.
  unsupportedParameterShape('UNSUPPORTED_PARAMETER_SHAPE'),

  /// The member's type shape cannot be carried: a generic method.
  unsupportedTypeShape('UNSUPPORTED_TYPE_SHAPE'),

  /// Refused, but this build does not recognise the analyzer's wording.
  ///
  /// Still a refusal. It means the cell reported something this CLI has no name
  /// for, which is a mapping gap rather than permission.
  unclassified('UNSUPPORTED_UNCLASSIFIED');

  const RouteBAbiCode(this.wire);

  /// The stable token. Safe to match on; the prose is not.
  final String wire;
}

/// One ABI refusal: a stable code, a stable reason token, and the analyzer's
/// own words kept verbatim for the human reading it.
class RouteBAbiRefusal {
  /// {@macro route_b_abi_refusal}
  const RouteBAbiRefusal({
    required this.code,
    required this.reason,
    required this.detail,
  });

  /// The category a caller may branch on.
  final RouteBAbiCode code;

  /// A stable snake_case token naming the specific shape, e.g.
  /// `named_parameters`. `unrecognised` when the wording was not matched.
  final String reason;

  /// The analyzer's wording, unmodified. Kept because it is the part that tells
  /// a person which member and which shape, and because re-deriving it here
  /// would put two sources of truth in the same message.
  final String detail;

  /// `CODE(reason)`, the form that appears in the user-facing refusal.
  String get label => '${code.wire}($reason)';

  @override
  String toString() => '$label: $detail';
}

/// The wordings the current cell emits, mapped to stable tokens.
///
/// Matched as substrings, deliberately: the analyzer joins several reasons with
/// `; ` and may prefix a member name, and a whole-string equality test would
/// have failed on the very message it was written for.
const _known = <String, (RouteBAbiCode, String)>{
  'takes named parameters': (
    RouteBAbiCode.unsupportedParameterShape,
    'named_parameters',
  ),
  'takes optional positional parameters': (
    RouteBAbiCode.unsupportedParameterShape,
    'optional_positional_parameters',
  ),
  'is generic': (RouteBAbiCode.unsupportedTypeShape, 'generic_method'),
};

/// Classifies an analyzer refusal reason.
///
/// Returns every shape the reason names, in a stable order, because one member
/// can violate more than one rule at once and reporting only the first would
/// hide work from whoever has to fix it.
List<RouteBAbiRefusal> classifyRouteBAbiRefusals(String reason) {
  final found = <RouteBAbiRefusal>[];
  for (final entry in _known.entries) {
    if (reason.contains(entry.key)) {
      found.add(
        RouteBAbiRefusal(
          code: entry.value.$1,
          reason: entry.value.$2,
          detail: reason,
        ),
      );
    }
  }
  return found;
}

/// The ABI label to attach to a refusal, or null when the reason is not an ABI
/// matter at all.
///
/// [isRouteBAbiReason] decides that: a refusal about capabilities or receiver
/// use is not an ABI refusal and must not be labelled as one.
String? routeBAbiLabel(String reason) {
  final found = classifyRouteBAbiRefusals(reason);
  if (found.isEmpty) return null;
  return found.map((f) => f.label).join(' ');
}

/// Whether [reason] looks like the analyzer describing a member's SHAPE.
///
/// Used to decide whether an unrecognised reason should be reported as an ABI
/// mapping gap. Kept narrow on purpose: over-claiming here would relabel
/// unrelated refusals as ABI ones and make the codes meaningless.
bool isRouteBAbiReason(String reason) =>
    reason.contains('the method takes') || reason.contains('the method is');
