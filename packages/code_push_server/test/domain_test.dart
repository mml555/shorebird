import 'package:code_push_server/src/domain.dart';
import 'package:test/test.dart';

void main() {
  Matcher throwsConflict() => throwsA(
    isA<DomainException>().having((e) => e.statusCode, 'statusCode', 409),
  );

  group('DomainException helpers', () {
    test('conflict maps to 409', () {
      final e = conflict('nope');
      expect(e.statusCode, 409);
      expect(e.code, 'conflict');
    });

    test('notFound maps to 404', () {
      expect(notFound('gone').statusCode, 404);
    });

    test('badRequest maps to 400', () {
      expect(badRequest('bad').statusCode, 400);
    });
  });

  group('enum parse round-trips', () {
    test('ArtifactStatus', () {
      for (final v in ArtifactStatus.values) {
        expect(ArtifactStatus.parse(v.name), equals(v));
      }
    });

    test('ReleaseLifecycle', () {
      for (final v in ReleaseLifecycle.values) {
        expect(ReleaseLifecycle.parse(v.name), equals(v));
      }
    });

    test('PatchStatus', () {
      for (final v in PatchStatus.values) {
        expect(PatchStatus.parse(v.name), equals(v));
      }
    });

    test('ChannelPatchStatus', () {
      for (final v in ChannelPatchStatus.values) {
        expect(ChannelPatchStatus.parse(v.name), equals(v));
      }
    });

    test('parse throws for an unknown name', () {
      expect(() => PatchStatus.parse('bogus'), throwsStateError);
    });
  });

  group('requireArtifactTransition', () {
    test('allows valid forward transitions', () {
      expect(
        () => requireArtifactTransition(
          ArtifactStatus.pending,
          ArtifactStatus.uploading,
        ),
        returnsNormally,
      );
      expect(
        () => requireArtifactTransition(
          ArtifactStatus.pending,
          ArtifactStatus.failed,
        ),
        returnsNormally,
      );
      expect(
        () => requireArtifactTransition(
          ArtifactStatus.uploading,
          ArtifactStatus.verified,
        ),
        returnsNormally,
      );
      expect(
        () => requireArtifactTransition(
          ArtifactStatus.uploading,
          ArtifactStatus.failed,
        ),
        returnsNormally,
      );
    });

    test('allows same-state (idempotent) transitions', () {
      for (final v in ArtifactStatus.values) {
        expect(() => requireArtifactTransition(v, v), returnsNormally);
      }
    });

    test('rejects invalid transitions with a 409', () {
      expect(
        () => requireArtifactTransition(
          ArtifactStatus.pending,
          ArtifactStatus.verified,
        ),
        throwsConflict(),
      );
      expect(
        () => requireArtifactTransition(
          ArtifactStatus.verified,
          ArtifactStatus.uploading,
        ),
        throwsConflict(),
      );
      // Terminal states have no outgoing transitions.
      expect(
        () => requireArtifactTransition(
          ArtifactStatus.failed,
          ArtifactStatus.verified,
        ),
        throwsConflict(),
      );
    });
  });

  group('requirePatchTransition', () {
    test('allows valid forward transitions', () {
      expect(
        () => requirePatchTransition(PatchStatus.draft, PatchStatus.uploading),
        returnsNormally,
      );
      expect(
        () => requirePatchTransition(PatchStatus.uploading, PatchStatus.ready),
        returnsNormally,
      );
      expect(
        () =>
            requirePatchTransition(PatchStatus.ready, PatchStatus.invalidated),
        returnsNormally,
      );
      expect(
        () =>
            requirePatchTransition(PatchStatus.draft, PatchStatus.invalidated),
        returnsNormally,
      );
      // ready -> uploading: a multi-arch patch re-opens to accept the next
      // arch's artifact (e.g. macOS x86_64 + arm64).
      expect(
        () => requirePatchTransition(PatchStatus.ready, PatchStatus.uploading),
        returnsNormally,
      );
    });

    test('allows same-state (idempotent) transitions', () {
      for (final v in PatchStatus.values) {
        expect(() => requirePatchTransition(v, v), returnsNormally);
      }
    });

    test('rejects invalid transitions with a 409', () {
      expect(
        () => requirePatchTransition(PatchStatus.draft, PatchStatus.ready),
        throwsConflict(),
      );
      expect(
        () =>
            requirePatchTransition(PatchStatus.invalidated, PatchStatus.ready),
        throwsConflict(),
      );
    });
  });

  group('requireChannelPatchTransition', () {
    test('allows the active -> withdrawn transition', () {
      expect(
        () => requireChannelPatchTransition(
          ChannelPatchStatus.active,
          ChannelPatchStatus.withdrawn,
        ),
        returnsNormally,
      );
    });

    test('allows same-state (idempotent) transitions', () {
      for (final v in ChannelPatchStatus.values) {
        expect(() => requireChannelPatchTransition(v, v), returnsNormally);
      }
    });

    test('rejects withdrawn -> active with a 409', () {
      expect(
        () => requireChannelPatchTransition(
          ChannelPatchStatus.withdrawn,
          ChannelPatchStatus.active,
        ),
        throwsConflict(),
      );
    });
  });

  group('email domain allowlist', () {
    test('parses a comma or whitespace separated list', () {
      expect(parseDomainList('example.com, example.org'), [
        'example.com',
        'example.org',
      ]);
      expect(parseDomainList('example.com example.org'), [
        'example.com',
        'example.org',
      ]);
    });

    test('normalizes case, @ prefixes, and *. wildcards', () {
      expect(parseDomainList('@Example.COM, *.example.org'), [
        'example.com',
        'example.org',
      ]);
    });

    test('drops blanks, duplicates, and things that are not domains', () {
      expect(parseDomainList(''), isEmpty);
      expect(parseDomainList(null), isEmpty);
      expect(parseDomainList(' , ,, '), isEmpty);
      // No dot, a pasted address, and a pasted URL.
      expect(parseDomainList('localhost'), isEmpty);
      expect(parseDomainList('bob@example.com'), isEmpty);
      expect(parseDomainList('https://example.com/x'), isEmpty);
      expect(parseDomainList('example.com,EXAMPLE.com'), ['example.com']);
    });

    test('preserves the order it was given', () {
      expect(parseDomainList('b.com,a.com'), ['b.com', 'a.com']);
    });

    test('an empty allowlist admits everyone', () {
      expect(emailAllowedByDomains('anyone@gmail.com', const []), isTrue);
    });

    test('admits only exact domain matches', () {
      const allowed = ['example.com'];
      expect(emailAllowedByDomains('bob@example.com', allowed), isTrue);
      expect(emailAllowedByDomains('BOB@EXAMPLE.COM', allowed), isTrue);
      expect(emailAllowedByDomains('bob@gmail.com', allowed), isFalse);
    });

    // A subdomain someone else controls must not widen the org.
    test('does not admit subdomains of an allowed domain', () {
      expect(
        emailAllowedByDomains('bob@mail.example.com', const ['example.com']),
        isFalse,
      );
    });

    test('does not admit a domain that merely ends with an allowed one', () {
      expect(
        emailAllowedByDomains('bob@notexample.com', const ['example.com']),
        isFalse,
      );
    });

    test('refuses a malformed address rather than admitting it', () {
      for (final bad in ['bob', 'bob@', '']) {
        expect(emailAllowedByDomains(bad, const ['example.com']), isFalse);
      }
    });

    test('emailDomain extracts the domain, or empty when there is none', () {
      expect(emailDomain('bob@Example.com'), 'example.com');
      // Only the last @ separates the domain.
      expect(emailDomain('weird@name@example.com'), 'example.com');
      expect(emailDomain('bob'), '');
      expect(emailDomain('bob@'), '');
    });
  });
}
