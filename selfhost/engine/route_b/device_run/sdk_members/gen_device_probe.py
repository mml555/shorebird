#!/usr/bin/env python3
# cspell:words eqop xhello oneshot sdkprobe SDKPROBE NOTPATCHED xids ddecl dstmt
"""gen_device_probe.py <out_dir>

Device version of the host matrix generator (../../evidence/sdk_instance_members
on PR #209's branch; MAIN, RECV and selector_of below are its tables). Writes
<out_dir>/main_release.dart, main_patched.dart, probes.tsv, ids.txt.

The release is a real Flutter app. Its own code never calls a probed member:
receivers are built with constructors and static functions only (no operators,
no `.length`, no `.toList()`), `axNow` is `identical`-based, and the runner uses
only File/Directory members that are not probed. Receiver classes that cannot
be built that way (Iterable from where/map/keys/values, Stream from a
controller) are left out and listed in RESULT.md.

Each probe is a top-level `void p_<id>()` whose release body does nothing. The
patch replaces the body with the probe, which records its outcome with
`probeLog` (a release function) instead of returning it, so a stub that was not
patched leaves `lastResult` null and cannot be read as a result. The runner
marks each probe with files before the call, so an abort is attributed to the
probe whose marker has no result on the next launch.
"""
import os
import re
import sys
import pathlib

# member id -> expression statement on the receiver `R` (without the `;`)
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
 'iter_any': 'rIter.any((x) => x != null)',
 'iter_every': 'rIter.every((x) => x != null)',
 'iter_firstWhere': 'rIter.firstWhere((x) => x != null)',
 'iter_fold': 'rIter.fold<int>(0, (a, x) => a + 1)',
 'iter_reduce': 'rIter.reduce((a, b) => a)',
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

# Device-proven and compiler-introduced members, probed so the host matrix can
# veto them (a member also on the host list must pass the matrix too).
MAIN.update({
 'int_plus': 'R + 1', 'int_minus': 'R - 1', 'int_times': 'R * 2', 'int_div': 'R / 2',
 'int_mod': 'R % 3', 'int_lt': 'R < 2', 'int_gt': 'R > 2', 'int_le': 'R <= 2',
 'int_ge': 'R >= 2', 'int_neg': '-R', 'int_eqop': 'R == 2', 'int_toString': 'R.toString()',
 'dbl_plus': 'R + 1.0', 'dbl_minus': 'R - 1.0', 'dbl_times': 'R * 2.0', 'dbl_div': 'R / 2.0',
 'dbl_floorDiv': 'R ~/ 2.0', 'dbl_mod': 'R % 3.0', 'dbl_lt': 'R < 2.0', 'dbl_gt': 'R > 2.0',
 'dbl_le': 'R <= 2.0', 'dbl_ge': 'R >= 2.0', 'dbl_neg': '-R', 'dbl_eqop': 'R == 2.0',
 'dbl_toString': 'R.toString()',
 'num_plus': 'R + 1', 'num_minus': 'R - 1', 'num_times': 'R * 2', 'num_div': 'R / 2',
 'num_mod': 'R % 3', 'num_lt': 'R < 2', 'num_gt': 'R > 2', 'num_le': 'R <= 2',
 'num_ge': 'R >= 2', 'num_neg': '-R', 'num_eqop': 'R == 2',
 'bool_toString': 'R.toString()',
 'str_toString': 'R.toString()', 'str_split': "R.split(' ')",
 'list_add': 'R.add(1)',
 'iter_join': "R.join(',')", 'iter_where': 'R.where((x) => true)',
 'iter_map': 'R.map((x) => x)', 'iter_toList': 'R.toList()',
 'iter_iterator': 'R.iterator',
 'iter_moveNext': 'R.iterator.moveNext()', 'iter_current': 'R.iterator.current',
 'obj_eq': 'R == R', 'obj_toString': 'R.toString()', 'obj_hashCode': 'R.hashCode',
})

# receiver var prefix -> (declared type, probe-type group)
TYPES = {
 'rFuture': 'Future<int>', 'rStream': 'Stream<int>', 'rCtl': 'StreamController<int>',
 'rTimer': 'Timer', 'rMap': 'Map<String, Object?>', 'rList': 'List<Object?>',
 'rIter': 'Iterable<Object?>', 'rSet': 'Set<Object?>', 'rStr': 'String',
 'rInt': 'int', 'rDbl': 'double', 'rNum': 'num', 'rDate': 'DateTime',
 'rDur': 'Duration', 'rState': 'StateError', 'rFormat': 'FormatException',
}
# probe-id prefix -> receiver prefix
PREFIX = {
 'future': 'rFuture', 'stream': 'rStream', 'ctl': 'rCtl', 'timer': 'rTimer',
 'map': 'rMap', 'list': 'rList', 'iter': 'rIter', 'set': 'rSet', 'str': 'rStr',
 'int': 'rInt', 'dbl': 'rDbl', 'num': 'rNum', 'date': 'rDate', 'dur': 'rDur',
 'state': 'rState', 'format': 'rFormat', 'error': 'rState', 'object': 'rState',
 'bool': 'rBool', 'obj': 'rObj',
}
TYPES.update({'rBool': 'bool', 'rObj': 'Object'})

# receiver prefix -> [(runtime-class label, expression)]
RECV = {
 'rFuture': [
  ('async_fn', 'asyncFn()'),
  ('value', 'Future<int>.value(axNow())'),
  ('completer', '(Completer<int>()..complete(axNow())).future'),
  ('delayed', 'Future<int>.delayed(const Duration(milliseconds: 1), axNow)'),
 ],
 'rStream': [
  ('from_iterable', 'Stream<int>.fromIterable(<int>[axNow(), 2])'),
  ('controller', '(StreamController<int>()..add(axNow())).stream'),
  ('broadcast', 'StreamController<int>.broadcast().stream'),
 ],
 'rCtl': [
  ('plain', 'StreamController<int>()'),
  ('broadcast', 'StreamController<int>.broadcast()'),
 ],
 'rTimer': [('periodic_or_oneshot', 'Timer(const Duration(seconds: 600), () {})')],
 'rMap': [
  ('literal', "<String, Object?>{'a': axNow()}"),
  ('const', "const <String, Object?>{'a': 1}"),
  ('unmodifiable', "Map<String, Object?>.unmodifiable(<String, Object?>{'a': axNow()})"),
  ('json', "jsonDecode('{\"a\":${axNow()}}') as Map<String, Object?>"),
 ],
 'rList': [
  ('growable', '<Object?>[3, 1, axNow() + 1]'),
  ('filled_fixed', 'List<Object?>.filled(3, axNow())'),
  ('const', 'const <Object?>[3, 1, 2]'),
  ('unmodifiable', 'List<Object?>.unmodifiable(<Object?>[3, 1, axNow()])'),
  ('map_values_toList', "<String, Object?>{'a': axNow()}.values.toList()"),
  ('json', "jsonDecode('[3,1,${axNow()}]') as List<Object?>"),
 ],
 'rIter': [
  ('list', '<Object?>[1, 2, axNow() + 2]'),
  ('set', '<Object?>{1, axNow() + 1}'),
  ('map_keys', "<String, Object?>{'a': axNow()}.keys"),
  ('map_values', "<String, Object?>{'a': axNow()}.values"),
  ('where', '<Object?>[1, axNow()].where((x) => true)'),
  ('map', '<Object?>[1, axNow()].map((x) => x)'),
 ],
 'rSet': [
  ('literal', '<Object?>{1, axNow() + 1}'),
  ('const', 'const <Object?>{1, 2}'),
 ],
 'rStr': [
  ('one_byte', "'hello world ${axNow()}'"),
  ('two_byte', "'\u3053\u3093\u306b\u3061\u306f ${axNow()}'"),
  ('substring_result', "'xhello world ${axNow()}'.substring(1)"),
 ],
 'rInt': [('smi', '7 + axNow()'), ('mint', '(1 << 40) + axNow()')],
 'rDbl': [('double', '2.5 + axNow()')],
 'rNum': [('smi', '7 + axNow()'), ('mint', '(1 << 40) + axNow()'), ('double', '2.5 + axNow()')],
 'rDate': [('utc', 'DateTime.utc(2020, 1, axNow())')],
 'rDur': [('duration', 'Duration(seconds: 3 + axNow())')],
 'rState': [('state_error', "StateError('x${axNow()}')")],
 'rFormat': [('format_exception', "FormatException('f${axNow()}')")],
 'rBool': [('bool', 'axNow() == 1')],
 'rObj': [('string', "'o${axNow()}'"), ('int', '7 + axNow()'), ('list', '<Object?>[axNow()]')],
}
EXTRA_GLOBALS = {'rDur', 'rDate'}


def selector_of(pid, expr):
    """The VM selector the probe tests, which analysis would report."""
    names = {
     'plus': '+', 'minus': '-', 'times': '*', 'div': '/', 'mod': '%', 'lt': '<',
     'gt': '>', 'le': '<=', 'ge': '>=', 'neg': 'unary-', 'eqop': '==',
     'floorDiv': '~/', 'and': '&', 'shl': '<<', 'index': '[]', 'eq': '==',
     'get': '[]', 'set': '[]=',
    }
    suffix = pid.split('_', 1)[1]
    if pid in ('obj_eq',): return '=='
    if pid in ('str_eq',): return '=='
    if pid.startswith('str_plus'): return '+'
    if pid.startswith('str_times'): return '*'
    if suffix in names and not pid.startswith(('map_', 'list_')) and pid not in ('str_index',):
        return names[suffix]
    if pid in ('map_get', 'list_get', 'str_index'): return '[]'
    if pid in ('map_set', 'list_set'): return '[]='
    if pid in ('dur_plus',): return '+'
    if pid in ('dur_gt',): return '>'
    if pid.startswith('state_error_message') or pid.startswith('format_exception_message'):
        return 'message'
    if pid == 'iter_iterator': return 'get:iterator'
    if pid == 'iter_moveNext': return 'moveNext'
    if pid == 'iter_current': return 'get:current'
    m = re.search(r'R\.(\w+)', expr)
    name = m.group(1) if m else suffix
    isCall = bool(re.search(r'R\.' + name + r'\s*[(<]', expr))
    if isCall: return name
    return 'get:' + name




# --- device receivers: constructors and static functions only -----------------
I = "int.parse('{}')"
RECV['rFuture'] = [
    ('async_fn', 'asyncFn()'),
    ('value', 'Future<int>.value(axNow())'),
    ('completer', '(Completer<int>()..complete(axNow())).future'),
    ('delayed', 'Future<int>.delayed(const Duration(milliseconds: 1), axNow)'),
]
RECV['rStream'] = [
    ('from_iterable', 'Stream<int>.fromIterable(<int>[axNow(), 2])'),
    ('value', 'Stream<int>.value(axNow())'),
    ('as_broadcast', 'Stream<int>.fromIterable(<int>[axNow()]).asBroadcastStream()'),
]
RECV['rMap'] = [
    ('literal', "<String, Object?>{'a': axNow()}"),
    ('const', "const <String, Object?>{'a': 1}"),
    ('unmodifiable', "Map<String, Object?>.unmodifiable(<String, Object?>{'a': axNow()})"),
    ('json', "jsonDecode('{\"a\":1}') as Map<String, Object?>"),
]
RECV['rList'] = [
    ('growable', '<Object?>[3, 1, axNow()]'),
    ('filled_fixed', 'List<Object?>.filled(3, axNow())'),
    ('const', 'const <Object?>[3, 1, 2]'),
    ('unmodifiable', 'List<Object?>.unmodifiable(<Object?>[3, 1, axNow()])'),
    ('generate', 'List<Object?>.generate(3, (int i) => i)'),
    ('json', "jsonDecode('[3,1,2]') as List<Object?>"),
]
RECV['rIter'] = [
    ('list', '<Object?>[1, 2, axNow()]'),
    ('set', '<Object?>{1, axNow()}'),
    ('generate', 'Iterable<Object?>.generate(3, (int i) => i)'),
]
RECV['rSet'] = [
    ('literal', '<Object?>{1, axNow()}'),
    ('const', 'const <Object?>{1, 2}'),
]
RECV['rStr'] = [
    ('one_byte', "'hello world ${axNow()}'"),
    ('two_byte', "'こんにちは ${axNow()}'"),
]
RECV['rInt'] = [('smi', "int.parse('7')"), ('mint', "int.parse('1099511627776')")]
RECV['rDbl'] = [('double', "double.parse('2.5')")]
RECV['rNum'] = [('smi', "int.parse('7')"), ('mint', "int.parse('1099511627776')"),
                ('double', "double.parse('2.5')")]
RECV['rDur'] = [('duration', "Duration(seconds: int.parse('3'))")]
RECV['rBool'] = [('bool', "bool.fromEnvironment('sdkprobe', defaultValue: true)")]
RECV['rObj'] = [('string', "'o${axNow()}'"), ('int', "int.parse('7')"),
                ('list', '<Object?>[axNow()]')]
RECV['rSize'] = [('size', "Size(double.parse('1'), double.parse('2'))")]
RECV['rOffset'] = [('offset', "Offset(double.parse('1'), double.parse('2'))")]
TYPES.update({'rSize': 'Size', 'rOffset': 'Offset'})
PREFIX.update({'size': 'rSize', 'offset': 'rOffset'})
MAIN.update({
    'size_width': 'rSize.width', 'size_height': 'rSize.height',
    'offset_dx': 'rOffset.dx', 'offset_dy': 'rOffset.dy',
})
# a StreamSubscription is made inside the patch (listen), then cancelled
SUB = [('from_iterable', 'Stream<int>.fromIterable(<int>[1])'),
       ('controller', 'StreamController<int>().stream'),
       ('broadcast', 'StreamController<int>.broadcast().stream')]
SEL_OVERRIDE = {'size_width': 'get:width', 'size_height': 'get:height',
                'offset_dx': 'get:dx', 'offset_dy': 'get:dy'}


def main():
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    recv_names = []
    decls = ''
    for prefix, items in RECV.items():
        for label, expr in items:
            nm = f'{prefix}__{label}'
            recv_names.append(nm)
            decls += f'final Object {nm} = {expr};\n'
    probes = []  # (id, type, label, form, selector, kind, payload)
    for mid, expr in MAIN.items():
        pre = mid.split('_', 1)[0]
        prefix = PREFIX[pre]
        e = re.sub(r'^(-?)' + prefix + r'\b', r'\1R', expr)
        e = re.sub(r'\b' + prefix + r'\b', 'R', e)
        sel = SEL_OVERRIDE.get(mid) or selector_of(mid, e)
        is_method = bool(re.search(r'R\.(\w+)\s*[(<]', e)) and not mid.startswith('iter_moveNext')
        for label, _ in RECV[prefix]:
            for form in ('static', 'dynamic'):
                probes.append((f'{mid}__{label}__{form[0]}', TYPES[prefix], label, form, sel, 'recv', (prefix, e)))
                if is_method:
                    name = re.search(r'R\.(\w+)', e).group(1)
                    probes.append((f'{mid}__{label}__t{form[0]}', TYPES[prefix], label,
                                   'tearoff-' + form, 'tearoff:' + name, 'recv', (prefix, f'R.{name}')))
    for label, expr in SUB:
        for form in ('static', 'dynamic'):
            probes.append((f'sub_cancel__{label}__{form[0]}', 'StreamSubscription<int>', label, form, 'cancel', 'sub', expr))
            probes.append((f'sub_cancel__{label}__t{form[0]}', 'StreamSubscription<int>', label,
                           'tearoff-' + form, 'tearoff:cancel', 'sub', expr))

    rel = ["// Generated by gen_device_probe.py. The release: a Flutter app whose own code\n"
           "// calls none of the probed members.\n"
           "// ignore_for_file: unused_element, unused_local_variable, prefer_const_constructors\n"
           "import 'dart:async';\nimport 'dart:convert';\nimport 'dart:io';\n"
           "import 'dart:ui' show Offset, Size;\n\nimport 'package:flutter/material.dart';\n\n"]
    rel.append("@pragma('vm:never-inline')\nint axNow() => identical(DateTime.now(), 0) ? 0 : 1;\n\n"
               "@pragma('vm:never-inline')\nFuture<int> asyncFn() async => axNow();\n\n")
    rel.append("final Duration rDur = Duration(seconds: int.parse('3'));\n"
               "final DateTime rDate = DateTime.utc(2020, 1, 2);\n")
    recv_names += ['rDur', 'rDate']
    rel.append(decls)
    # rDate / rState / rFormat share the receivers declared above
    ids = [p[0] for p in probes]
    rel.append("\n// The patch installer invokes every attached target once, with no arguments, before main. A probe\n// body does nothing until the runner arms it, so that call cannot abort the process or read as a result.\nbool probesArmed = false;\n\nString? lastResult;\n\nvoid probeLog(String r) {\n  lastResult = r;\n}\n\n"
               "@pragma('vm:never-inline')\nvoid armProbe() {\n  axNow();\n}\n")
    for pid in ids:
        rel.append(f"\n@pragma('vm:never-inline')\nvoid p_{pid}() {{\n  axNow();\n}}\n")
    # runner
    rel.append(RUNNER_HEAD)
    for i, pid in enumerate(ids):
        rel.append(f"  if (_begin({i}, '{pid}')) {{\n    p_{pid}();\n    _end({i}, '{pid}');\n  }}\n")
    rel.append("  print('SDKPROBE SWEEP_DONE');\n  File('$_dir/DONE').createSync();\n}\n")
    keep = ", ".join(recv_names)
    rel.append("\n@pragma('vm:never-inline')\nvoid _sink(Object o) {\n  axNow();\n}\n\n"
               "void keepReceivers() {\n" + "".join(f"  _sink({n});\n" for n in recv_names) + "}\n")
    kept = bool(os.environ.get('KEPT_CALLS'))
    if kept:
        # The kept release: every probed member is called from code the compiler cannot prove dead, on
        # the receivers the probes use, so the release keeps it (typed and tear-off forms; a `dynamic`
        # probe binds by selector to whatever the receiver's class kept).
        kc = []
        dyn_sel = set(open(os.environ['KEPT_DYNAMIC_SELECTORS']).read().split()) if os.environ.get('KEPT_DYNAMIC_SELECTORS') else set()
        for pid, typ, label, form, sel, kind, payload in probes:
            if 'dynamic' in form:
                continue
            if kind == 'recv':
                prefix, e = payload
                decl = f"final {TYPES[prefix]} R = {prefix}__{label} as {TYPES[prefix]};"
            else:
                decl = f"final StreamSubscription<int> R = {payload}.listen((int v) {{}});"
                e = 'R.cancel()' if not form.startswith('tearoff') else 'R.cancel'
            stmt = f"_sink({e} as Object);" if form.startswith('tearoff') else f"{e};"
            rel.append(f"\n@pragma('vm:never-inline')\nvoid k_{pid}() {{\n  {decl}\n  {stmt}\n}}\n")
            kc.append(f"  k_{pid}();\n")
            # A typed call can be inlined or folded away (String.length, num operators on a smi), which
            # leaves the member without code. A call by name on a `dynamic` receiver cannot: the compiler
            # keeps every member of that name. Used for the selectors the first build still missed.
            plain = re.sub(r'^tearoff:', '', sel)
            if plain in dyn_sel and kind == 'recv':
                ddecl = f"dynamic R = {prefix}__{label};"
                dstmt = f"_sink({e} as Object);" if form.startswith('tearoff') else f"{e};"
                rel.append(f"\n@pragma('vm:never-inline')\nvoid kd_{pid}() {{\n  {ddecl}\n  {dstmt}\n}}\n")
                kc.append(f"  kd_{pid}();\n")
        rel.append("\n// Never runs (no machine has a million cores), but the compiler cannot know that.\n"
                   "void keptCalls() {\n" + "".join(kc) + "}\n")
    rel.append(MAIN_FN.replace("  keepReceivers();\n", "  keepReceivers();\n  if (Platform.numberOfProcessors > 1000000) keptCalls();\n") if kept else MAIN_FN)
    release = "".join(rel)
    (out / 'main_release.dart').write_text(release)

    patched = release
    # Probes left out of the patch (still stubs in the release, so they report NOTPATCHED):
    # PATCH_EXCLUDE is a comma list of selectors; a probe is left out when its selector is listed
    # and its form is dynamic.
    excl = set(filter(None, os.environ.get('PATCH_EXCLUDE_DYNAMIC', '').split(',')))
    left_out = []
    # excluded_ids.tsv: id, kind. `host-abort` ids aborted the process on the host matrix and are
    # not tried on the device; `device-abort` ids aborted it on the device (found by a launch).
    xids = {}
    xf = os.environ.get('PATCH_EXCLUDED_IDS')
    if xf:
        for l in open(xf):
            if l.strip():
                a, b = l.rstrip('\n').split('\t')
                xids[a] = b
    patched = patched.replace("void armProbe() {\n  axNow();\n}",
                              "void armProbe() {\n  probeLog('${runIdLiteral}');\n}".replace('${runIdLiteral}', RUN_ID), 1)
    for pid, typ, label, form, sel, kind, payload in probes:
        if pid in xids:
            left_out.append(pid)
            continue
        if os.environ.get('PATCH_ONLY_DYNAMIC') and 'dynamic' not in form:
            left_out.append(pid)
            continue
        if 'dynamic' in form and re.sub(r'^(get:|set:|tearoff:)', '', sel) in excl:
            left_out.append(pid)
            continue
        if kind == 'recv':
            prefix, e = payload
            decl = (f"dynamic R = {prefix}__{label};" if 'dynamic' in form
                    else f"final {TYPES[prefix]} R = {prefix}__{label} as {TYPES[prefix]};")
        else:
            decl = (f"dynamic R = {payload}.listen((int v) {{}});" if 'dynamic' in form
                    else f"final StreamSubscription<int> R = {payload}.listen((int v) {{}});")
            e = 'R.cancel()' if not form.startswith('tearoff') else 'R.cancel'
        if form.startswith('tearoff'):
            stmt = f"final Object? t = {e};\n    if (t is! Function) {{\n      probeLog('ERR not a function');\n      return;\n    }}"
        else:
            stmt = f"{e};"
        old = f"void p_{pid}() {{\n  axNow();\n}}"
        new = (f"void p_{pid}() {{\n  if (!probesArmed) return;\n  try {{\n    {decl}\n    {stmt}\n    probeLog('OK');\n"
               f"  }} catch (e) {{\n    probeLog('ERR $e');\n  }}\n}}")
        assert patched.count(old) == 1, pid
        patched = patched.replace(old, new)
    (out / 'main_patched.dart').write_text(patched)
    (out / 'excluded_ids.tsv').write_text(''.join(f'{a}\t{b}\n' for a, b in xids.items()))
    (out / 'left_out.txt').write_text("".join(f'{x}\n' for x in left_out))
    (out / 'probes.tsv').write_text("".join(
        f"{pid}\t{typ}\t{label}\t{form}\t{sel}\n" for pid, typ, label, form, sel, k, pl in probes))
    (out / 'ids.txt').write_text("\n".join(ids) + "\n")
    print(len(ids), 'probes')


RUN_ID = os.environ.get('RUN_ID', 'S2')  # a new id gives the app a fresh Documents folder of markers
RUNNER_HEAD = '''
late String _dir;

bool _has(String n) => File('$_dir/$n').existsSync();

void _mk(String n) {
  File('$_dir/$n').createSync();
}

void _res(String id, String r) {
  File('$_dir/results.tsv').writeAsStringSync('$id\\t$r\\n', mode: FileMode.append, flush: true);
  print('SDKPROBE RESULT $id $r');
}

bool _begin(int i, String id) {
  if (_has('d$i') || _has('x$i')) return false;
  if (_has('a$i')) {
    _mk('x$i');
    _res(id, 'ABORTS');
    return false;
  }
  _mk('a$i');
  print('SDKPROBE ABOUT $id');
  lastResult = null;
  probesArmed = true;
  return true;
}

void _end(int i, String id) {
  probesArmed = false;
  final r = lastResult;
  if (r == null) {
    File('$_dir/a$i').deleteSync();
    print('SDKPROBE NOTPATCHED $id');
    return;
  }
  _res(id, r);
  _mk('d$i');
}

void sweep() {
  lastResult = null;
  armProbe();
  final run = lastResult;
  if (run == null) {
    print('SDKPROBE PATCH_INACTIVE');
    return;
  }
  _dir = '${Directory.systemTemp.parent.path}/Documents/sdkprobe_$run';
  Directory(_dir).createSync(recursive: true);
  print('SDKPROBE START $run $_dir');
  if (_has('DONE')) {
    print('SDKPROBE SWEEP_DONE');
    return;
  }
'''
MAIN_FN = '''
void main() {
  keepReceivers();
  // The updater marks a patch bad after two boots that die before they report a successful launch
  // (after the first frame), so the sweep starts 6 s after runApp.
  Timer(const Duration(seconds: 6), sweep);
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('sdkprobe')))));
}
'''

main()
