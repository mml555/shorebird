// cspell:words sels selfhost
import 'dart:io';
import 'package:kernel/kernel.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:vm/metadata/table_selector.dart';

void main(List<String> args) {
  final component = Component();
  final repo = TableSelectorMetadataMetadataStub();
  component.addMetadataRepository(repo.real);
  BinaryBuilderWithMetadata(
    File(args[0]).readAsBytesSync(),
  ).readComponent(component);
  final md = repo.real.mapping[component];
  if (md == null) {
    print('NO table-selector metadata attached');
    return;
  }
  final sels = md.selectors;
  var used = 0, torn = 0;
  for (final s in sels) {
    if (s.callCount > 0) used++;
    if (s.tornOff) torn++;
  }
  print('selectors=${sels.length} callCount>0=$used tornOff=$torn');
  for (final id in [5194, 5195, 5196, 5197]) {
    if (id < sels.length) {
      print('  sid=$id callCount=${sels[id].callCount} '
          'tornOff=${sels[id].tornOff} calledOnNull=${sels[id].calledOnNull}');
    }
  }
  // Where does the stream stop making sense? A call count above this is not a
  // count; it is misread bytes.
  const sane = 100000;
  var firstBad = -1;
  for (var i = 0; i < sels.length; i++) {
    if (sels[i].callCount > sane) { firstBad = i; break; }
  }
  print('first implausible callCount at sid=$firstBad');
  var bad = 0;
  for (final s in sels) { if (s.callCount > sane) bad++; }
  print('implausible entries: $bad of ${sels.length}');
  String row(int i) => '$i:cc=${sels[i].callCount},t=${sels[i].tornOff}';
  print('first 8: ' + [for (var i=0;i<8 && i<sels.length;i++) row(i)].join(' '));
  if (firstBad > 2) {
    print('around firstBad: ' +
      [for (var i=firstBad-2;i<firstBad+3 && i<sels.length;i++) row(i)].join(' '));
  }
}

class TableSelectorMetadataMetadataStub {
  final real = TableSelectorMetadataRepository();
}
