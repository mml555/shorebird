"""variants.py <base main.dart> <base tally.dart> <variant> <out main.dart> <out tally.dart>

Each variant is one ordinary edit a developer would ship as a patch. Every
substitution must match exactly once, so a variant cannot silently no-op.
`list` prints the variant names.
"""
import sys

NEW_BADGE = '''
class Badge2 extends StatelessWidget {
  const Badge2({super.key});

  @override
  Widget build(BuildContext context) {
    log('badge', 'B2');
    return const Text('B2');
  }
}
'''

EXTRA_PAGE = '''
class ExtraPage extends StatelessWidget {
  const ExtraPage({super.key});

  @override
  Widget build(BuildContext context) {
    log('extra', 'X2');
    return const Scaffold(body: Center(child: Text('X2')));
  }
}
'''

# name -> list of (file, old, new); file is 'main' or 'tally'
V = {
    'p01_stateless_build': [('main', "log('label', 'L1');\n    return const Text('L1');",
                             "log('label', 'L2');\n    return const Text('L2');")],
    'p02_stateful_build': [('main', "log('home-build', 'H1 $_count');", "log('home-build', 'H2 $_count');"),
                           ('main', "Text('H1 $_count'", "Text('H2 $_count'")],
    'p03_setstate_closure': [('main', '_count += 1;', '_count += 10;')],
    'p04_method_body': [('main', "log('count', _count);", "log('count', 'c$_count');")],
    'p05_init_state': [('main', "log('init', 'I1');", "log('init', 'I2');")],
    'p06_async_return': [('main', "return 'G1';", "return 'G2';")],
    'p07_async_loop': [('main', 'i < 3; i++) {\n      await', 'i < 5; i++) {\n      await')],
    'p08_async_star': [('main', "yield 'T$i';", "yield 'U$i';")],
    'p09_route_page_build': [('main', "log('detail', 'D1');", "log('detail', 'D2');"),
                             ('main', "Text('D1'", "Text('D2'")],
    'p10_route_table': [('main', "log('route', 'R1 ${settings.name}');", "log('route', 'R2 ${settings.name}');")],
    'p11_new_widget_class': [('main', '            const Label(),\n', '            const Label(),\n            const Badge2(),\n'),
                             ('main', '\nclass DetailPage', NEW_BADGE + '\nclass DetailPage')],
    'p12_new_route_page': [('main', 'builder: (_) => const DetailPage(),', 'builder: (_) => const ExtraPage(),'),
                           ('main', '\nclass DetailPage', EXTRA_PAGE + '\nclass DetailPage')],
    'p13_dep_same_api': [('main', "DateFormat('yyyy-MM-dd')", "DateFormat('dd MMM yyyy')")],
    'p14_dep_new_api': [('main', "=> DateFormat('yyyy-MM-dd').format(t);",
                         "=> '${DateFormat('yyyy-MM-dd').format(t)} ${NumberFormat.compact().format(1234567)}';")],
    'p15_dep_body': [('tally', "'K1 $n ", "'K2 $n ")],
    'p16_sdk_list_add': [('main', "    log('count', _count);\n",
                          "    log('count', _count);\n    _events.add('e$_count');\n    log('events-list', _events.join(','));\n")],
    'p17_sdk_chain': [('main', "log('done', 'START-DONE');",
                       "log('words', 'a b c'.split(' ').where((w) => w != 'b').map((w) => w.toUpperCase()).toList());\n    log('done', 'START-DONE');")],
    'p18_polymorphic': [('main', "=> 'circle1';", "=> 'circle2';")],
    'p19_getter': [('main', "get mood => 'M1';", "get mood => 'M2';")],
    'p20_const': [('main', "const kTitle = 'KT1';", "const kTitle = 'KT2';")],
    'p21_enum_switch': [('main', "return 'hi1';", "return 'hi2';")],
    'p22_extension': [('main', "=> glyph * this;", "=> '#' * this;")],
    'p23_closure_in_build': [('main', "log('future-builder', 'FB1 ${snap.data}');\n                return Text('FB1 ${snap.data}');",
                              "log('future-builder', 'FB2 ${snap.data}');\n                return Text('FB2 ${snap.data}');")],
    'p24_pattern_switch': [('main', "=> 'ok $value',", "=> 'OK $value',")],
    'p25_new_field': [('main', "  int _count = 0;\n", "  int _count = 0;\n  int _extra = 5;\n"),
                      ('main', "log('home-build', 'H1 $_count');", "log('home-build', 'H1 $_count $_extra');")],
    'p26_static_method': [('main', "static String tag() => 'S1';", "static String tag() => 'S2';")],
    'p27_generic': [('main', "'F1'));", "'F2'));")],
    'p28_new_top_level_fn': [('main', "log('done', 'START-DONE');", "log('helper', helper2());\n    log('done', 'START-DONE');"),
                             ('main', '\nvoid main()', "\nString helper2() => 'HP2';\n\nvoid main()")],
    # --- cell 2fc41d3f: a patch may ADD a private top-level function (#193) and a private
    # instance method of an existing class (#194).
    'h1_new_private_top_level_fn': [
        ('main', "    log('count', _count);\n  }\n\n  @override\n  Widget build",
         "    log('count', _count);\n    log('h1', _greet(_count));\n  }\n\n  @override\n  Widget build"),
        ('main', '\nvoid main()', "\nString _greet(int n) => 'N$n';\n\nvoid main()")],
    'm1_new_private_method': [
        ('main', "    log('count', _count);\n  }\n\n  @override\n  Widget build",
         "    log('count', _count);\n    log('m1', _label());\n  }\n\n  String _label() => 'LBL$_count';\n\n  @override\n  Widget build")],
    'm2_new_private_method_calls_and_writes': [
        ('main', "    log('events', _events.length);\n",
         "    _bump();\n    log('events', _events.length);\n"),
        ('main', "  void _increment() {",
         "  void _bump() {\n    _increment();\n    _count += 100;\n    log('bump', _count);\n  }\n\n  void _increment() {")],
    'r1_new_public_method_tojson': [
        ('main', "import 'dart:async';\n", "import 'dart:async';\nimport 'dart:convert';\n"),
        ('main', "    log('events', _events.length);\n",
         "    log('json', jsonEncode(this));\n    log('events', _events.length);\n"),
        ('main', "  void _increment() {",
         "  Map<String, Object?> toJson() => {'count': _count};\n\n  void _increment() {")],
    'r2_new_private_method_name_collision': [
        ('main', "    log('label', 'L1');\n", "    log('label', 'L1 ${_increment()}');\n"),
        ('main', "    return const Text('L1');\n  }\n}\n",
         "    return const Text('L1');\n  }\n\n  String _increment() => 'dup';\n}\n")],
    # --- cell a6a48cf6: analysis 21 enclosingScope (#219) and int/double operators in lowered
    # instance methods (#217).
    's1_static_unqualified': [
        ('main', "String _decorate() => _wrap('$_prefix:$_count');",
         "String _decorate() => '$_prefix/${_wrap(_prefix)}/$_count';")],
    'i1_int_ops': [
        ('main', "String _arith(int a, int b) => '${a - 1}:${a > b}';",
         "String _arith(int a, int b) => '${a + 1}:${a * 2 > b}';")],
    'i2_double_op': [
        ('main', 'double _half(int n) => n / 2;', 'double _half(int n) => n / 4 + 0.5;')],
    'e1_extension_static': [
        ('main', "String get stars => glyph * this;", "String get stars => '$glyph$glyph' * this;")],
    't1_class_type_param_refusal': [
        ('main', "String kind(Object o) => o is T ? 'T1' : 'no';",
         "String kind(Object o) => o is T ? 'T2' : 'no';")],
    # --- cell a6a48cf6 dry run (2026-11-17): the same kinds of edit without the SDK calls the
    # cell measured as unsafe (Iterable.join/map/toList, num./, String.*) or a private static const.
    'p16b_sdk_list_add_length': [('main', "    log('count', _count);\n",
                                  "    log('count', _count);\n    _events.add('e$_count');\n    log('events-list', _events.length);\n")],
    's1b_static_unqualified_nested': [
        ('main', "String _decorate() => _wrap('$_prefix:$_count');",
         "String _decorate() => _wrap(_wrap('n$_count'));")],
    'i2b_double_mul': [
        ('main', 'double _half(int n) => n / 2;', 'double _half(int n) => n * 0.25 + 0.5;')],
    'e1b_extension_static_interp': [
        ('main', "String get stars => glyph * this;", "String get stars => '$glyph$this$glyph';")],
    'p29_const_only': [('main', "    log('label', 'L1');\n    return const Text('L1');", "    log('label', 'L1');\n    return const Text('L2');")],
    # #254: an await on a TickerFuture calls its `then`; analysis 24 reports it as Future.then on TickerFuture.
    't254_await_ticker': [('main', "import 'package:flutter/material.dart';", "import 'package:flutter/material.dart';\nimport 'package:flutter/scheduler.dart';"),
                          ('main', "await Future<void>.delayed(const Duration(milliseconds: 200));\n  return 'G1';",
                           "await TickerFuture.complete();\n  return 'G4';")],
    # #289 follow-up: a call of Future.timeout / whenComplete / catchError on a Future value, which every Material
    # app's TickerFuture overrides. Each also changes the greeting, so a launch shows it ran.
    'f01_timeout': [('main', "await Future<void>.delayed(const Duration(milliseconds: 200));\n  return 'G1';",
                     "await Future<void>.delayed(const Duration(milliseconds: 200)).timeout(const Duration(seconds: 5));\n  return 'G5';")],
    'f02_when_complete': [('main', "await Future<void>.delayed(const Duration(milliseconds: 200));\n  return 'G1';",
                           "await Future<void>.delayed(const Duration(milliseconds: 200)).whenComplete(() => log('when-complete', 'W1'));\n  return 'G6';")],
    'f03_catch_error': [('main', "await Future<void>.delayed(const Duration(milliseconds: 200));\n  return 'G1';",
                         "await Future<void>.delayed(const Duration(milliseconds: 200)).catchError((Object e) => log('catch-error', e));\n  return 'G7';")],
    'p30_field_initializer': [('main', 'final List<String> _events = <String>[];', "final List<String> _events = <String>['seed'];")],
}

# Every edit expected to patch with carrying, the const fix and super support,
# applied together: one release, one install, one launch shows them all.
# p17_sdk_chain left out for a6a48cf6: it calls Iterable.map/toList, which the cell measured unsafe.
COMBO = ['p01_stateless_build', 'p02_stateful_build', 'p04_method_body', 'p05_init_state',
         'p06_async_return', 'p08_async_star', 'p09_route_page_build', 'p10_route_table',
         'p13_dep_same_api', 'p15_dep_body', 'p18_polymorphic', 'p19_getter',
         'p21_enum_switch', 'p23_closure_in_build', 'p24_pattern_switch',
         'p26_static_method', 'p27_generic']
V['combo'] = [sub for name in COMBO for sub in V[name]]
# cell 54117a2f: with #251 a patch that changes a dependency (p15, the tally package) is refused, so the
# combo is first built whole (expected: refused for p15), then without p15 (published), and p15 alone (refused).
V['combo_nop15'] = [sub for name in COMBO if name != 'p15_dep_body' for sub in V[name]]


def main():
    if sys.argv[1] == 'list':
        print('\n'.join(V))
        return
    base_main, base_tally, name, out_main, out_tally = sys.argv[1:6]
    text = {'main': open(base_main).read(), 'tally': open(base_tally).read()}
    # `a+b+c` applies several variants together, for bisecting a combination.
    edits = [sub for part in name.split('+') for sub in V[part]] if '+' in name else V.get(name, [])
    for f, old, new in edits if name != 'base' else []:
        n = text[f].count(old)
        if n != 1:
            sys.exit(f'{name}: {old!r} matched {n} times in {f}')
        text[f] = text[f].replace(old, new)
    open(out_main, 'w').write(text['main'])
    open(out_tally, 'w').write(text['tally'])


main()
