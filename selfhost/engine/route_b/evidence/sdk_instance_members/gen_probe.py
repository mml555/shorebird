#!/usr/bin/env python3
# cspell:words eqop oneshot xhello
"""gen_probe.py <container_target.dart> <out_dir>

Writes <out_dir>/release_source.dart, patched_source.dart and probes.tsv.

The matrix. Retention is per (allocated runtime class, selector), not per the
declared interface a call site names, so every member is probed on every
representative runtime class a value of its declared type commonly has in app
code (RECV below), in three forms:

  static   a local of the declared type calls the member
  dynamic  a `dynamic` local calls it (a dispatch by name, as `jsonDecode`
           data does: `data['x']`)
  tearoff  the member is torn off (only for methods), static and dynamic

The release builds one live receiver per class (top-level finals) and declares
one stub per probe, `String p_<id>()`, which never calls the member. The
patched source replaces each stub with a body that calls the member inside
try/catch. Each probe is its own top-level target, run in its own container and
process (run.sh), so the attach native's receiver-less invocation (a host
harness artifact) cannot be mistaken for a NoSuchMethodError on the member.

probes.tsv columns: id, receiver type, runtime-class label, form, selector.
"""
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


def split_expr(expr):
    m = re.match(r'^(-?)(r[A-Z]\w*)\b(.*)$', expr, re.S)
    if m:  # unary minus on the receiver, or the receiver first
        return m.group(1), m.group(2), m.group(3)
    m = re.match(r'^(-)R(.*)$', expr, re.S)
    return None


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


def main():
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    s = src.read_text()

    def sub(old, new):
        nonlocal s
        assert s.count(old) == 1, old
        s = s.replace(old, new)

    sub("import 'dart:convert';\n", "import 'dart:async';\nimport 'dart:convert';\n")
    stubs = ("\n@pragma('vm:never-inline')\nint axNow() => DateTime.now().millisecondsSinceEpoch >= 0 ? 1 : 0;\n"
             "\n@pragma('vm:never-inline')\nFuture<int> asyncFn() async => axNow();\n")
    # receivers
    stubs += ("final Duration rDur = Duration(seconds: 3 + axNow());\n"
              "final DateTime rDate = DateTime.utc(2020, 1, axNow());\n")
    recv_names = ['rDur', 'rDate']
    for prefix, items in RECV.items():
        for label, expr in items:
            nm = f'{prefix}__{label}'
            recv_names.append(nm)
            stubs += f"final Object {nm} = {expr};\n"
    probes = []  # (id, prefix, label, form, selector, stmt)
    for mid, expr in MAIN.items():
        pre = mid.split('_', 1)[0]
        prefix = PREFIX[pre]
        e = expr
        # normalise the first receiver token to R
        e = re.sub(r'^(-?)' + prefix + r'\b', r'\1R', e)
        if prefix == 'rDate':
            e = e.replace('rDate', 'R')
        else:
            e = re.sub(r'\b' + prefix + r'\b', 'R', e)
        sel = selector_of(mid, e)
        classes = RECV[prefix]
        if mid.startswith('int_') and prefix == 'rInt': classes = RECV['rInt']
        is_method = bool(re.search(r'R\.(\w+)\s*[(<]', e)) and not mid.startswith(('iter_moveNext',))
        for label, _ in classes:
            for form in ('static', 'dynamic'):
                probes.append((f'{mid}__{label}__{form[0]}', prefix, label, form, sel, e))
                if is_method:
                    name = re.search(r'R\.(\w+)', e).group(1)
                    probes.append((f'{mid}__{label}__t{form[0]}', prefix, label, 'tearoff-' + form, 'tearoff:' + name, f'R.{name}'))
    for pid, prefix, label, form, sel, e in probes:
        stubs += f"\n@pragma('vm:never-inline')\nString p_{pid}() => axNow() >= 0 ? 'REL' : 'X';\n"
    ids = [p[0] for p in probes]
    runner = ("\nvoid probeAll(String when) {\n"
              "  final only = Platform.environment['PROBE'];\n" + "".join(
        f"  if (only == null || only == '{pid}') print('P $when {pid}=${{p_{pid}()}}');\n"
        for pid in ids) + "}\n")
    keep = "\nvoid keepReceivers() {\n  print('KEEP ${[" + ", ".join(recv_names) + "].length}');\n}\n"
    sub("  if (args.isEmpty) return; // identity-only mode, used to build the patch", "  if (args.isEmpty) exit(0); // identity-only mode, used to build the patch")
    sub("void main(List<String> args) {", "void main(List<String> args) {\n  keepReceivers();\n  probeAll('before');")
    sub("  _state('after ');\n", "  _state('after ');\n  probeAll('after');\n  exit(0);\n")
    s += stubs + runner + keep
    (out / 'release_source.dart').write_text(s)
    p = s
    for pid, prefix, label, form, sel, e in probes:
        T = TYPES[prefix]
        decl = (f"dynamic R = {prefix}__{label};" if 'dynamic' in form
                else f"final {T} R = {prefix}__{label} as {T};")
        if form.startswith('tearoff'):
            stmt = f"final Object? t = {e};\n    if (t is! Function) return 'ERR not a function';"
        else:
            stmt = f"{e};"
        old = f"String p_{pid}() => axNow() >= 0 ? 'REL' : 'X';"
        new = (f"String p_{pid}() {{\n  try {{\n    {decl}\n    {stmt}\n    return 'OK';\n"
               f"  }} catch (e) {{\n    return 'ERR $e';\n  }}\n}}")
        assert p.count(old) == 1, pid
        p = p.replace(old, new)
    (out / 'patched_source.dart').write_text(p)
    (out / 'probes.tsv').write_text("".join(
        f"{pid}\t{TYPES[prefix]}\t{label}\t{form}\t{sel}\n" for pid, prefix, label, form, sel, e in probes))
    (out / 'ids.txt').write_text("\n".join(ids) + "\n")
    print(len(ids), 'probes')


main()
