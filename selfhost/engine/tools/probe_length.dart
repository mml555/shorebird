// cspell:words sels selfhost
import 'dart:io';
import 'package:kernel/kernel.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:vm/metadata/table_selector.dart';
import 'package:vm/metadata/procedure_attributes.dart';

void main(List<String> args) {
  final component = Component();
  final ts = TableSelectorMetadataRepository();
  final pa = ProcedureAttributesMetadataRepository();
  component..addMetadataRepository(ts)..addMetadataRepository(pa);
  BinaryBuilderWithMetadata(File(args[0]).readAsBytesSync())
      .readComponent(component);
  final table = ts.mapping[component]!;
  for (final lib in component.libraries) {
    if (lib.importUri.toString() != 'dart:core') continue;
    for (final cls in lib.classes) {
      if (cls.name != 'List' && cls.name != 'Map') continue;
      for (final m in cls.members) {
        if (m.name.text != 'length' && m.name.text != '[]') continue;
        final attrs = pa.mapping[m];
        if (attrs == null) {
          print('${cls.name}.${m.name.text}: NO procedure-attributes');
          continue;
        }
        final gid = attrs.getterSelectorId;
        final mid = attrs.methodOrSetterSelectorId;
        String cc(int id) => (id >= 0 && id < table.selectors.length)
            ? '${table.selectors[id].callCount}'
            : 'n/a';
        print('${cls.name}.${m.name.text}: getterSid=$gid cc=${cc(gid)} '
            'methodSid=$mid cc=${cc(mid)} hasTearOffUses=${attrs.hasTearOffUses}');
      }
    }
  }
}
