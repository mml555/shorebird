// Domain model: lifecycle enums + transition guards, isolated from the
// Shorebird wire DTOs (which live only at the HTTP boundary in api.dart).
//
// The state machines enforce the plan's invariants:
//   Artifact:     pending -> uploading -> verified | failed
//   Release:      draft -> uploading -> ready -> archived
//   Patch:        draft -> uploading -> ready -> invalidated
//   ChannelPatch: active -> withdrawn
// Invalid transitions throw [ConflictException] (HTTP 409) — fail closed.

/// Thrown for domain rule violations that map to a specific HTTP status.
class DomainException implements Exception {
  DomainException(this.statusCode, this.code, this.message);
  final int statusCode;
  final String code;
  final String message;
  @override
  String toString() => 'DomainException($statusCode $code): $message';
}

DomainException conflict(String message) =>
    DomainException(409, 'conflict', message);
DomainException notFound(String message) =>
    DomainException(404, 'not_found', message);
DomainException badRequest(String message) =>
    DomainException(400, 'bad_request', message);

/// Parses a stored/submitted email-domain allowlist into normalized, lowercase
/// domains with duplicates and blanks removed.
///
/// Accepts a comma- or whitespace-separated list, tolerating a leading `@` or a
/// `*.` wildcard prefix on each entry (both are written by hand often enough to
/// be worth accepting). Order is preserved so a round-trip reads back the way
/// it was set. Returns an empty list for null/blank input, which every caller
/// treats as "unrestricted".
List<String> parseDomainList(String? raw) {
  if (raw == null) return const [];
  final out = <String>[];
  for (final part in raw.split(RegExp(r'[,\s]+'))) {
    var d = part.trim().toLowerCase();
    if (d.startsWith('@')) d = d.substring(1);
    if (d.startsWith('*.')) d = d.substring(2);
    // A bare dot-less token can't be a mail domain, and anything with a slash,
    // an `@`, or whitespace is a pasted address or URL rather than a domain.
    if (d.isEmpty || !d.contains('.')) continue;
    if (d.contains('/') || d.contains('@')) continue;
    if (!out.contains(d)) out.add(d);
  }
  return out;
}

/// The domain part of [email], lowercased, or empty if it has no `@`.
String emailDomain(String email) {
  final at = email.lastIndexOf('@');
  if (at < 0 || at == email.length - 1) return '';
  return email.substring(at + 1).trim().toLowerCase();
}

/// Whether [email] is admissible to an org whose allowlist is [allowedDomains].
///
/// An empty allowlist admits everyone. Matching is exact on the domain — a
/// policy of `example.com` does not admit `mail.example.com`, so an org can't
/// be widened by a subdomain someone else controls.
bool emailAllowedByDomains(String email, List<String> allowedDomains) {
  if (allowedDomains.isEmpty) return true;
  final d = emailDomain(email);
  return d.isNotEmpty && allowedDomains.contains(d);
}

enum ArtifactStatus {
  pending,
  uploading,
  verified,
  failed;

  static ArtifactStatus parse(String s) =>
      ArtifactStatus.values.firstWhere((v) => v.name == s);
}

enum ReleaseLifecycle {
  draft,
  uploading,
  ready,
  archived;

  static ReleaseLifecycle parse(String s) =>
      ReleaseLifecycle.values.firstWhere((v) => v.name == s);
}

enum PatchStatus {
  draft,
  uploading,
  ready,
  invalidated;

  static PatchStatus parse(String s) =>
      PatchStatus.values.firstWhere((v) => v.name == s);
}

enum ChannelPatchStatus {
  active,
  withdrawn;

  static ChannelPatchStatus parse(String s) =>
      ChannelPatchStatus.values.firstWhere((v) => v.name == s);
}

/// Allowed forward transitions per machine. A transition to the same state is
/// treated as idempotent and always allowed.
const _artifactNext = {
  ArtifactStatus.pending: {ArtifactStatus.uploading, ArtifactStatus.failed},
  ArtifactStatus.uploading: {ArtifactStatus.verified, ArtifactStatus.failed},
  ArtifactStatus.verified: <ArtifactStatus>{},
  ArtifactStatus.failed: <ArtifactStatus>{},
};

const _patchNext = {
  PatchStatus.draft: {PatchStatus.uploading, PatchStatus.invalidated},
  PatchStatus.uploading: {PatchStatus.ready, PatchStatus.invalidated},
  // ready -> uploading: a multi-arch patch (e.g. macOS x86_64 + arm64, or
  // Android arm/arm64/x64) registers each arch artifact sequentially; the patch
  // may be marked ready after the first arch verifies, then re-opens when the
  // next arch's artifact is registered.
  PatchStatus.ready: {PatchStatus.uploading, PatchStatus.invalidated},
  PatchStatus.invalidated: <PatchStatus>{},
};

const _channelPatchNext = {
  ChannelPatchStatus.active: {ChannelPatchStatus.withdrawn},
  ChannelPatchStatus.withdrawn: <ChannelPatchStatus>{},
};

void requireArtifactTransition(ArtifactStatus from, ArtifactStatus to) {
  if (from == to) return;
  if (!_artifactNext[from]!.contains(to)) {
    throw conflict('Artifact cannot go ${from.name} -> ${to.name}');
  }
}

void requirePatchTransition(PatchStatus from, PatchStatus to) {
  if (from == to) return;
  if (!_patchNext[from]!.contains(to)) {
    throw conflict('Patch cannot go ${from.name} -> ${to.name}');
  }
}

void requireChannelPatchTransition(
  ChannelPatchStatus from,
  ChannelPatchStatus to,
) {
  if (from == to) return;
  if (!_channelPatchNext[from]!.contains(to)) {
    throw conflict('ChannelPatch cannot go ${from.name} -> ${to.name}');
  }
}
