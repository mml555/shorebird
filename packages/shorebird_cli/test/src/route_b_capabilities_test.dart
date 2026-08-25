import 'dart:convert';

import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:test/test.dart';

void main() {
  group(RouteBCapabilities, () {
    const uri = 'package:app/main.dart';

    /// A manifest in the exact shape `gen_dynamic_interface.dart --manifest`
    /// writes.
    ///
    /// Built from arguments rather than a fixture file so each test states
    /// the ONE capability difference it turns on. A shared fixture would make
    /// "member present but class absent" indistinguishable from "wrong
    /// fixture".
    String manifest({
      List<String> topLevel = const [],
      List<String> statics = const [],
      List<String> instance = const [],
      List<String> classes = const [],
      List<String> skipped = const [],
    }) => jsonEncode({
      'policy': 'p2',
      'privateTopLevelCallable': topLevel,
      'privateStaticsCallable': statics,
      'privateInstanceCallable': instance,
      'privateClassesConstructible': classes,
      'refused': skipped,
    });

    test('accepts a private member when its class capability is present', () {
      // The P2 shape, and the one Phase 0 says dominates real patches:
      // `_FooState._controller` reached through the receiver.
      final caps = RouteBCapabilities.fromJson(
        manifest(
          instance: ['$uri#_FooState#_controller'],
          classes: ['$uri#_FooState'],
        ),
      );

      expect(
        caps.refuseInstanceMember(
          library: uri,
          className: '_FooState',
          member: '_controller',
        ),
        isNull,
      );
    });

    test('accepts a granted member of a private class with no class item', () {
      // ~~P3's failure, encoded.~~ **REWRITTEN 2026-08-25: the rule this test
      // pinned was misattributed, and the correction is measured.**
      //
      // P3's grants really were inert, but not because a private class needs a
      // class-level capability. They were inert because P3 never granted the
      // TARGET member -- in its own fixture a PUBLIC method of a private class.
      // Attach needs the target member granted; it does not need the class.
      //
      // `probes/p1_dead_allocatability.sh` arm Cfix3 attaches to `_Kept.show`
      // and reads `self._hidden` with NO bare class item anywhere in the
      // interface. Arm Cfix -- the same grant set without the target member's
      // grant -- fails at ATTACH, which is P3 reproduced with its real cause
      // isolated.
      //
      // The old expectation is now actively harmful: since the generator stopped
      // emitting bare private class items, `classesConstructible` means "these
      // constructors were explicitly granted" and is EMPTY on a release that
      // grants none -- so requiring it here would refuse every private member
      // reference on every release.
      final caps = RouteBCapabilities.fromJson(
        manifest(instance: ['$uri#_FooState#_controller']),
      );

      expect(
        caps.refuseInstanceMember(
          library: uri,
          className: '_FooState',
          member: '_controller',
        ),
        isNull,
      );
    });

    test('refuses a private member the release recorded as skipped', () {
      // Present in the skipped set beats absent from the granted set: the
      // release TRIED and could not, which is a different remedy from never
      // having tried.
      final caps = RouteBCapabilities.fromJson(
        manifest(
          classes: ['$uri#_FooState'],
          skipped: ['$uri#_FooState#_controller (member, not indexable)'],
        ),
      );

      expect(
        caps.refuseInstanceMember(
          library: uri,
          className: '_FooState',
          member: '_controller',
        ),
        RouteBRefusal.inSkippedSet,
      );
    });

    test('refuses _enumToString unconditionally, however it is spelled', () {
      // No policy can grant it, so it must not depend on what a manifest
      // happens to contain -- including a manifest that wrongly lists it as
      // granted.
      final caps = RouteBCapabilities.fromJson(
        manifest(
          instance: ['$uri#WonderType#_enumToString'],
          classes: ['$uri#WonderType'],
        ),
      );

      for (final spelling in ['_enumToString', 'get:_enumToString']) {
        expect(
          caps.refuseInstanceMember(
            library: uri,
            className: 'WonderType',
            member: spelling,
          ),
          RouteBRefusal.unconditional,
          reason: spelling,
        );
      }
    });

    test('leaves public behavior unchanged: no class item required', () {
      // A PUBLIC class needs no `class:` item -- a `library:` item already
      // covers it -- so requiring one would refuse the cases that have
      // worked since rung C.
      final caps = RouteBCapabilities.fromJson(
        manifest(instance: ['$uri#PublicThing#_secret']),
      );

      expect(
        caps.refuseInstanceMember(
          library: uri,
          className: 'PublicThing',
          member: '_secret',
        ),
        isNull,
      );
    });

    test('a private top-level member needs no class capability', () {
      // The shape probe D proved and P1 grants: a direct call with no
      // receiver.
      final caps = RouteBCapabilities.fromJson(
        manifest(topLevel: ['$uri#_helper']),
      );

      expect(caps.refuseTopLevel(library: uri, member: '_helper'), isNull);
      expect(
        caps.refuseTopLevel(library: uri, member: '_absent'),
        RouteBRefusal.memberNotEmitted,
      );
    });

    test('a static of a private class needs no class item either', () {
      // Same correction as above, on the static shape. A static dispatches
      // without a receiver, and what attach needs is the target member's own
      // grant -- so a P1-era manifest granting statics and no classes is usable
      // for exactly those statics.
      final caps = RouteBCapabilities.fromJson(
        manifest(statics: ['$uri#_Holder#_count']),
      );

      expect(
        caps.refuseInstanceMember(
          library: uri,
          className: '_Holder',
          member: '_count',
        ),
        isNull,
      );
    });

    test('an absent or malformed manifest is not an empty capability set', () {
      // An empty set would refuse everything and look like a deliberate
      // policy. The caller must be able to tell "granted nothing" from
      // "could not be read".
      expect(() => RouteBCapabilities.fromJson('not json'), throwsException);
    });

    test('every refusal names its cause distinctly', () {
      // The remedies differ -- re-release, policy change, or neither -- so a
      // shared message would send the reader to the wrong fix.
      final messages = RouteBRefusal.values
          .map((r) => describeRouteBRefusal(r, '_x'))
          .toSet();
      expect(messages, hasLength(RouteBRefusal.values.length));
    });
  });
}
