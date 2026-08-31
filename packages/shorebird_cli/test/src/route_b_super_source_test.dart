// D-SUPER-2B.0. The source is the authority for what the developer wrote.
//
// The specimen these tests are built around is permanent and lives at
// `selfhost/engine/route_b/super0/s2b0/`, where the three-kernel fact is
// re-measured rather than remembered: source two arguments, import kernel two,
// AOT kernel ZERO.
import 'package:shorebird_cli/src/route_b_super_source.dart';
import 'package:test/test.dart';

void main() {
  group('routeBSuperCallArgs', () {
    RouteBSuperArgs read(String source, String member) {
      // The Kernel offset points at the MEMBER NAME, measured on both kernels of
      // the control specimen. The tests locate it the same way rather than
      // hardcoding a number, so a reformatted fixture cannot silently pass.
      final offset = source.indexOf('super') >= 0
          ? source.indexOf(member, source.indexOf('super'))
          : -1;
      return routeBSuperCallArgs(
        source: source,
        offset: offset,
        member: member,
      );
    }

    test('admits an empty argument list', () {
      expect(read('String t() => super.plain();', 'plain'),
          RouteBSuperArgs.zeroArguments);
      expect(read('String t() => super.plain(\n);', 'plain'),
          RouteBSuperArgs.zeroArguments);
      expect(read('String t() => super.plain(/* nested /*c*/ */);', 'plain'),
          RouteBSuperArgs.zeroArguments);
      expect(read('String t() => super . plain();', 'plain'),
          RouteBSuperArgs.zeroArguments);
    });

    test('THE CONTROL: refuses the arguments TFA would have erased', () {
      // The exact site from the permanent specimen. In the AOT kernel this call
      // reports ZERO arguments; the source says otherwise, and the source wins.
      expect(read("String t() => super.tag('a', 7);", 'tag'),
          RouteBSuperArgs.hasArguments);
    });

    test('refuses any argument shape', () {
      for (final call in <String>[
        'super.foo(x)',
        "super.foo('a', 7)",
        'super.foo(named: x)',
        'super.foo(  x  )',
        'super.foo(() {})',
        'super.foo((a, b) => a)',
      ]) {
        expect(read('String t() => $call;', 'foo'),
            RouteBSuperArgs.hasArguments,
            reason: call);
      }
    });

    test('refuses a generic super invocation', () {
      expect(read('String t() => super.foo<int>();', 'foo'),
          RouteBSuperArgs.hasArguments);
    });

    test('refuses what it cannot read, rather than guessing', () {
      // Offset does not name the member.
      expect(
        routeBSuperCallArgs(
            source: 'String t() => super.plain();', offset: 0, member: 'plain'),
        RouteBSuperArgs.unverifiable,
      );
      // Offset out of range.
      expect(
        routeBSuperCallArgs(
            source: 'super.plain();', offset: 999, member: 'plain'),
        RouteBSuperArgs.unverifiable,
      );
      // No `super.` prefix — an ordinary receiver call must not be admitted by
      // this gate even when the member name matches.
      expect(read('String t() => other.plain();', 'plain'),
          RouteBSuperArgs.unverifiable);
      // No argument list at all: a super TEAR-OFF, which is not a call.
      expect(read('var f = super.plain;', 'plain'),
          RouteBSuperArgs.unverifiable);
      // A comment between `super` and `.` is not read backwards; refused
      // rather than mis-lexed.
      expect(read('String t() => super/*c*/.plain();', 'plain'),
          RouteBSuperArgs.unverifiable);
    });

    test('does not match a longer identifier that starts the same way', () {
      // `tag` must not be found inside `tagged`: the offset would land on a
      // different member and the argument list read would belong to it.
      final source = 'String t() => super.tagged();';
      expect(
        routeBSuperCallArgs(
          source: source,
          offset: source.indexOf('tagged'),
          member: 'tag',
        ),
        RouteBSuperArgs.unverifiable,
      );
    });
  });
}
