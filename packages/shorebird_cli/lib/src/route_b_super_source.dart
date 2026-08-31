// Route B (selfhost): is a `super.member(...)` call site written with NO
// arguments, decided from the SOURCE.
//
// WHY THE SOURCE AND NOT THE KERNEL. TFA specialises a callee for its call
// sites, and when it does it erases the arguments from the AOT kernel. Measured
// on a permanent control (`selfhost/engine/route_b/super0/s2b0/`):
//
//     source        super.tag('a', 7)      two arguments
//     import kernel tag(String a, int b)   call site passes two
//     AOT kernel    tag()                  call site passes ZERO
//
// The analyzer reads the AOT kernel. So an admission gate that asks the AOT
// kernel how many arguments a super call has would ADMIT `super.tag('a', 7)`
// as a zero-argument call, and the replacement would then be compiled from
// source against the import kernel, where the member takes two parameters.
//
// The division of authority this file exists to enforce:
//
//     AOT kernel     a genuine super operation exists here, and what it retains
//     PATCH SOURCE   what the developer actually wrote  <-- this file
//     import kernel  what that super means locally, decided by dart2bytecode
//
// FAIL-CLOSED. Three outcomes, and only one of them admits. Anything this
// scanner cannot read confidently is [RouteBSuperArgs.unverifiable], never
// "probably fine": a wrong answer here compiles and then misbehaves on a
// device, which is the failure mode the whole project is organised against.
/// What the SOURCE says about a `super.member(...)` call's argument list.
enum RouteBSuperArgs {
  /// `super.member()` — an empty argument list, containing only trivia.
  zeroArguments,

  /// Something is between the parentheses, or type arguments are present.
  hasArguments,

  /// The scanner could not establish either answer: the offset does not name
  /// the member, no `super.` prefix precedes it, the parentheses are missing or
  /// unbalanced. Refused, not guessed.
  unverifiable,
}

/// Reads the `super.[member](…)` call at [offset] in [source].
///
/// [offset] is the Kernel `SuperMethodInvocation.fileOffset`, which points at
/// the MEMBER NAME rather than at `super` — measured on both kernels of the
/// control specimen, where it is 1066 in each, so it is also stable across the
/// AOT boundary.
RouteBSuperArgs routeBSuperCallArgs({
  required String source,
  required int offset,
  required String member,
}) {
  if (offset < 0 || offset + member.length > source.length) {
    return RouteBSuperArgs.unverifiable;
  }
  // The offset must actually name the member. If it does not, the analyzer and
  // this scanner disagree about where the site is, and nothing below can be
  // trusted.
  if (!source.startsWith(member, offset)) return RouteBSuperArgs.unverifiable;
  // An identifier character immediately before or after would mean the offset
  // landed inside a longer name (`tagged` when looking for `tag`).
  if (_isIdentifierPart(_charAt(source, offset - 1)) ||
      _isIdentifierPart(_charAt(source, offset + member.length))) {
    return RouteBSuperArgs.unverifiable;
  }

  // Confirm the prefix really is `super` `.` — the producer refuses unusual
  // `this` spacing for the same reason, and this is the same class of guess.
  var i = _skipTriviaBackward(source, offset - 1);
  if (_charAt(source, i) != '.') return RouteBSuperArgs.unverifiable;
  i = _skipTriviaBackward(source, i - 1);
  const keyword = 'super';
  final start = i - keyword.length + 1;
  if (start < 0 || !source.startsWith(keyword, start)) {
    return RouteBSuperArgs.unverifiable;
  }
  if (_isIdentifierPart(_charAt(source, start - 1))) {
    return RouteBSuperArgs.unverifiable;
  }

  // Forward to the argument list.
  var j = _skipTriviaForward(source, offset + member.length);
  if (j >= source.length) return RouteBSuperArgs.unverifiable;
  // `super.foo<T>()` is a generic invocation and stays refused. Reported as
  // hasArguments rather than unverifiable: it IS readable, and it is exactly a
  // shape v1 declines.
  if (source[j] == '<') return RouteBSuperArgs.hasArguments;
  if (source[j] != '(') return RouteBSuperArgs.unverifiable;

  // Only trivia may sit between the parentheses. No nesting to track: the first
  // thing that is not trivia or `)` means arguments are present.
  j = _skipTriviaForward(source, j + 1);
  if (j >= source.length) return RouteBSuperArgs.unverifiable;
  return source[j] == ')'
      ? RouteBSuperArgs.zeroArguments
      : RouteBSuperArgs.hasArguments;
}

String? _charAt(String s, int i) =>
    (i < 0 || i >= s.length) ? null : s[i];

bool _isIdentifierPart(String? c) =>
    c != null &&
    (c == '_' ||
        c == r'$' ||
        (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) ||
        (c.codeUnitAt(0) >= 0x41 && c.codeUnitAt(0) <= 0x5A) ||
        (c.codeUnitAt(0) >= 0x61 && c.codeUnitAt(0) <= 0x7A));

bool _isSpace(String c) =>
    c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';

/// Forward past whitespace, `//` comments and nested `/* */` comments.
int _skipTriviaForward(String s, int from) {
  var i = from;
  while (i < s.length) {
    if (_isSpace(s[i])) {
      i++;
      continue;
    }
    if (s.startsWith('//', i)) {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
      continue;
    }
    if (s.startsWith('/*', i)) {
      // Dart block comments nest, so a depth count is not paranoia.
      var depth = 1;
      i += 2;
      while (i < s.length && depth > 0) {
        if (s.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (s.startsWith('*/', i)) {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      continue;
    }
    return i;
  }
  return i;
}

/// Backward past whitespace only.
///
/// NOT past comments. Scanning comments in reverse cannot be done correctly
/// without lexing the whole file forward — `*/` may sit inside a string — and a
/// comment between `super` and `.` is rare enough that refusing it as
/// [RouteBSuperArgs.unverifiable] costs nothing. Under-reading here is safe;
/// over-reading is not.
int _skipTriviaBackward(String s, int from) {
  var i = from;
  while (i >= 0 && _isSpace(s[i])) {
    i--;
  }
  return i;
}
