#!/usr/bin/env python3
"""gen_probe.py <variant: main|sub> <container_target.dart> <out_dir>

Writes <out_dir>/release_source.dart and <out_dir>/patched_source.dart, and
<out_dir>/ids.txt (one probe id per line).

The release declares one live receiver per runtime type (top-level finals,
constructed by the release) and one stub per candidate dart: instance member,
`String p_<id>()`, which never calls the member. The patched source replaces each
stub with a body that calls the member inside try/catch. Each probe is its own
top-level target, so the attach native's receiver-less invocation (a host
harness artifact: it calls the target once with no receiver) cannot be mistaken
for a NoSuchMethodError on the member: a top-level target has no receiver, and
the member is called on a receiver the release built.
"""
import sys, pathlib

# id -> expression statement (without the trailing semicolon)
MAIN = {
 # Future
 'future_then': 'rFuture.then((v) => v)',
 'future_catchError': 'rFuture.catchError((e) => 0)',
 'future_whenComplete': 'rFuture.whenComplete(() {})',
 'future_timeout': 'rFuture.timeout(const Duration(seconds: 1))',
 # Stream / controller
 'stream_listen': 'rStream.listen((v) {})',
 'stream_where': 'rStream.where((v) => true)',
 'stream_map': 'rStream.map((v) => v)',
 'stream_toList': 'rStream.toList()',
 'stream_first': 'rStream.first',
 'stream_isBroadcast': 'rStream.isBroadcast',
 'ctl_add': 'rCtl.add(1)',
 'ctl_stream': 'rCtl.stream',
 'ctl_sink': 'rCtl.sink',
 'ctl_isClosed': 'rCtl.isClosed',
 'ctl_close': 'rCtl.close()',
 # Timer
 'timer_cancel': 'rTimer.cancel()',
 'timer_isActive': 'rTimer.isActive',
 'timer_tick': 'rTimer.tick',
 # Map
 'map_keys': 'rMap.keys',
 'map_values': 'rMap.values',
 'map_get': "rMap['a']",
 'map_set': "rMap['b'] = 2",
 'map_containsKey': "rMap.containsKey('a')",
 'map_containsValue': 'rMap.containsValue(1)',
 'map_remove': "rMap.remove('b')",
 'map_entries': 'rMap.entries',
 'map_length': 'rMap.length',
 'map_isEmpty': 'rMap.isEmpty',
 'map_isNotEmpty': 'rMap.isNotEmpty',
 'map_forEach': 'rMap.forEach((k, v) {})',
 'map_addAll': "rMap.addAll({'c': 3})",
 'map_putIfAbsent': "rMap.putIfAbsent('d', () => 4)",
 # List
 'list_contains': 'rList.contains(1)',
 'list_remove': 'rList.remove(99)',
 'list_insert': 'rList.insert(0, 5)',
 'list_length': 'rList.length',
 'list_get': 'rList[0]',
 'list_set': 'rList[0] = 4',
 'list_isEmpty': 'rList.isEmpty',
 'list_isNotEmpty': 'rList.isNotEmpty',
 'list_first': 'rList.first',
 'list_last': 'rList.last',
 'list_indexOf': 'rList.indexOf(2)',
 'list_sort': 'rList.sort()',
 'list_sublist': 'rList.sublist(1)',
 'list_addAll': 'rList.addAll([7])',
 'list_removeLast': 'rList.removeLast()',
 'list_removeAt': 'rList.removeAt(0)',
 'list_reversed': 'rList.reversed',
 'list_clear': 'rList.clear()',
 # Iterable
 'iter_any': 'rIter.any((x) => x > 1)',
 'iter_every': 'rIter.every((x) => x > 0)',
 'iter_firstWhere': 'rIter.firstWhere((x) => x > 1)',
 'iter_fold': 'rIter.fold<int>(0, (a, x) => a + x)',
 'iter_reduce': 'rIter.reduce((a, b) => a + b)',
 'iter_length': 'rIter.length',
 'iter_isEmpty': 'rIter.isEmpty',
 'iter_isNotEmpty': 'rIter.isNotEmpty',
 'iter_first': 'rIter.first',
 'iter_last': 'rIter.last',
 'iter_contains': 'rIter.contains(2)',
 'iter_toSet': 'rIter.toSet()',
 'iter_take': 'rIter.take(1)',
 'iter_skip': 'rIter.skip(1)',
 'iter_elementAt': 'rIter.elementAt(0)',
 # Set
 'set_contains': 'rSet.contains(1)',
 'set_add': 'rSet.add(3)',
 'set_remove': 'rSet.remove(3)',
 'set_length': 'rSet.length',
 # String
 'str_length': 'rStr.length',
 'str_isEmpty': 'rStr.isEmpty',
 'str_isNotEmpty': 'rStr.isNotEmpty',
 'str_contains': "rStr.contains('o')",
 'str_startsWith': "rStr.startsWith('h')",
 'str_endsWith': "rStr.endsWith('d')",
 'str_substring': 'rStr.substring(1)',
 'str_trim': 'rStr.trim()',
 'str_toUpperCase': 'rStr.toUpperCase()',
 'str_toLowerCase': 'rStr.toLowerCase()',
 'str_replaceAll': "rStr.replaceAll('o', '0')",
 'str_padLeft': "rStr.padLeft(20, '.')",
 'str_codeUnitAt': 'rStr.codeUnitAt(0)',
 'str_indexOf': "rStr.indexOf('w')",
 'str_index': 'rStr[0]',
 'str_plus': "rStr + 'x'",
 'str_times': 'rStr * 2',
 'str_compareTo': "rStr.compareTo('a')",
 'str_eq': "rStr == 'a'",
 # numbers
 'int_toStringAsFixed': 'rInt.toStringAsFixed(2)',
 'int_abs': 'rInt.abs()',
 'int_clamp': 'rInt.clamp(1, 5)',
 'int_compareTo': 'rInt.compareTo(3)',
 'int_isEven': 'rInt.isEven',
 'int_remainder': 'rInt.remainder(2)',
 'int_toDouble': 'rInt.toDouble()',
 'int_and': 'rInt & 3',
 'int_shl': 'rInt << 1',
 'int_floorDiv': 'rInt ~/ 2',
 'dbl_toStringAsFixed': 'rDbl.toStringAsFixed(1)',
 'dbl_round': 'rDbl.round()',
 'dbl_floor': 'rDbl.floor()',
 'dbl_ceil': 'rDbl.ceil()',
 'dbl_abs': 'rDbl.abs()',
 'dbl_clamp': 'rDbl.clamp(1.0, 2.0)',
 'dbl_compareTo': 'rDbl.compareTo(1.0)',
 'dbl_truncate': 'rDbl.truncate()',
 'dbl_isNaN': 'rDbl.isNaN',
 'dbl_toInt': 'rDbl.toInt()',
 'num_toStringAsFixed': 'rNum.toStringAsFixed(1)',
 'num_round': 'rNum.round()',
 'num_floor': 'rNum.floor()',
 'num_abs': 'rNum.abs()',
 'num_clamp': 'rNum.clamp(1, 2)',
 'num_compareTo': 'rNum.compareTo(1)',
 'num_toInt': 'rNum.toInt()',
 'num_toDouble': 'rNum.toDouble()',
 # DateTime / Duration
 'date_difference': 'rDate.difference(rDate)',
 'date_add': 'rDate.add(rDur)',
 'date_subtract': 'rDate.subtract(rDur)',
 'date_isBefore': 'rDate.isBefore(rDate)',
 'date_isAfter': 'rDate.isAfter(rDate)',
 'date_year': 'rDate.year',
 'date_month': 'rDate.month',
 'date_weekday': 'rDate.weekday',
 'date_toIso8601String': 'rDate.toIso8601String()',
 'date_toUtc': 'rDate.toUtc()',
 'date_microsecondsSinceEpoch': 'rDate.microsecondsSinceEpoch',
 'dur_inMilliseconds': 'rDur.inMilliseconds',
 'dur_inSeconds': 'rDur.inSeconds',
 'dur_inMinutes': 'rDur.inMinutes',
 'dur_inMicroseconds': 'rDur.inMicroseconds',
 'dur_plus': 'rDur + rDur',
 'dur_gt': 'rDur > rDur',
 'dur_isNegative': 'rDur.isNegative',
 # errors
 'state_error_message': 'rState.message',
 'format_exception_message': 'rFormat.message',
 'error_stackTrace': 'rState.stackTrace',
 'object_runtimeType': 'rState.runtimeType',
}
SUB = {
 'sub_cancel': 'rSub.cancel()',
 'sub_pause': 'rSub.pause()',
 'sub_resume': 'rSub.resume()',
 'sub_isPaused': 'rSub.isPaused',
 'sub_onData': 'rSub.onData((v) {})',
}

DECLS = '''
// Live receivers, built by the release. Each is the runtime type a patch would
// call the member on; none of the candidate members is called here.
final Future<int> rFuture = Future<int>.value(axNow());
final Stream<int> rStream = Stream<int>.fromIterable(<int>[axNow(), 2]);
final StreamController<int> rCtl = StreamController<int>();
final Timer rTimer = Timer(const Duration(seconds: 600), () {});
final Map<String, int> rMap = <String, int>{'a': axNow()};
final List<int> rList = <int>[3, 1, axNow() + 1];
final Iterable<int> rIter = <int>[1, 2, axNow() + 2];
final Set<int> rSet = <int>{1, axNow() + 1};
final String rStr = 'hello world ${axNow()}';
final int rInt = 7 + axNow();
final double rDbl = 2.5 + axNow();
final num rNum = rInt;
final DateTime rDate = DateTime.utc(2020, 1, axNow());
final Duration rDur = Duration(seconds: 3 + axNow());
final StateError rState = StateError('x${axNow()}');
final FormatException rFormat = FormatException('f${axNow()}');
'''
SUB_DECLS = '''
final StreamController<int> rCtl2 = StreamController<int>.broadcast();
final StreamSubscription<int> rSub = rCtl2.stream.listen((v) {});
'''

def main():
    variant, src, out = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    probes = MAIN if variant == 'main' else SUB
    s = src.read_text()
    def sub(old, new):
        nonlocal s
        assert s.count(old) == 1, old
        s = s.replace(old, new)
    sub("import 'dart:convert';\n", "import 'dart:async';\nimport 'dart:convert';\n")
    stubs = "\n@pragma('vm:never-inline')\nint axNow() => DateTime.now().millisecondsSinceEpoch >= 0 ? 1 : 0;\n"
    stubs += DECLS if variant == 'main' else DECLS.split('final Future')[0] + SUB_DECLS
    if variant == 'sub':
        # axNow decls only needed by the SUB receivers: none.
        pass
    for pid in probes:
        stubs += f"\n@pragma('vm:never-inline')\nString p_{pid}() => axNow() >= 0 ? 'REL' : 'X';\n"
    ids = list(probes)
    runner = ("\nvoid probeAll(String when) {\n"
              "  final only = Platform.environment['PROBE'];\n" + "".join(
        f"  if (only == null || only == '{pid}') print('P $when {pid}=${{p_{pid}()}}');\n"
        for pid in ids) + "}\n")
    # keep every receiver alive and allocated in the release
    keep = "\nvoid keepReceivers() {\n  print('KEEP ${[" + ", ".join(
        (['rFuture','rStream','rCtl','rTimer','rMap','rList','rIter','rSet','rStr','rInt','rDbl','rNum','rDate','rDur','rState','rFormat'] if variant=='main' else ['rSub'])) + "].length}');\n}\n"
    sub("void main(List<String> args) {", "void main(List<String> args) {\n  keepReceivers();\n  probeAll('before');")
    sub("  _state('after ');\n", "  _state('after ');\n  probeAll('after');\n  exit(0);\n")
    s += stubs + runner + keep
    (out / 'release_source.dart').write_text(s)
    p = s
    for pid, expr in probes.items():
        old = f"String p_{pid}() => axNow() >= 0 ? 'REL' : 'X';"
        new = (f"String p_{pid}() {{\n  try {{\n    {expr};\n    return 'OK';\n"
               f"  }} catch (e) {{\n    return 'ERR $e';\n  }}\n}}")
        assert p.count(old) == 1
        p = p.replace(old, new)
    (out / 'patched_source.dart').write_text(p)
    (out / 'ids.txt').write_text("\n".join(ids) + "\n")
    print(len(ids), 'probes')

main()
