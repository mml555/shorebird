// Try candidate binary layouts for vm.table-selector.metadata and score each
// by how plausible the resulting table is. Usage: layout_scan.dart <dill> <layout>
import 'dart:io';
import 'package:kernel/kernel.dart';
import 'package:kernel/binary/ast_from_binary.dart';

late String kLayout;

class Rec {
  int cc = 0, flags = 0, extra = 0;
}

class Probe extends MetadataRepository<List<Rec>> {
  @override
  final String tag = 'vm.table-selector.metadata';
  @override
  final Map<TreeNode, List<Rec>> mapping = {};

  @override
  void writeToBinary(List<Rec> m, Node node, BinarySink sink) {}

  @override
  List<Rec> readFromBinary(Node node, BinarySource source) {
    final n = source.readUInt30();
    final out = <Rec>[];
    for (var i = 0; i < n; i++) {
      final r = Rec();
      switch (kLayout) {
        case 'A': // vanilla: uint30 cc, byte flags
          r.cc = source.readUInt30();
          r.flags = source.readByte();
        case 'B': // + trailing byte
          r.cc = source.readUInt30();
          r.flags = source.readByte();
          r.extra = source.readByte();
        case 'C': // + trailing uint30
          r.cc = source.readUInt30();
          r.flags = source.readByte();
          r.extra = source.readUInt30();
        case 'D': // uint30 cc, uint30 extra, byte flags
          r.cc = source.readUInt30();
          r.extra = source.readUInt30();
          r.flags = source.readByte();
        case 'E': // uint30 extra, uint30 cc, byte flags
          r.extra = source.readUInt30();
          r.cc = source.readUInt30();
          r.flags = source.readByte();
        case 'F': // + trailing uint32
          r.cc = source.readUInt30();
          r.flags = source.readByte();
          r.extra = source.readUint32();
        case 'G': // leading uint32 hash, then vanilla
          r.extra = source.readUint32();
          r.cc = source.readUInt30();
          r.flags = source.readByte();
      }
      out.add(r);
    }
    return out;
  }
}

void main(List<String> args) {
  kLayout = args.length > 1 ? args[1] : 'A';
  final component = Component();
  final probe = Probe();
  component.addMetadataRepository(probe);
  try {
    BinaryBuilderWithMetadata(
      File(args[0]).readAsBytesSync(),
    ).readComponent(component);
  } catch (e) {
    print('$kLayout: PARSE FAILED (${e.toString().split('\n').first})');
    return;
  }
  final recs = probe.mapping[component];
  if (recs == null) {
    print('$kLayout: no metadata');
    return;
  }
  var bad = 0, nonzero = 0, torn = 0, badFlags = 0;
  final badIdx = <int>[];
  for (var i = 0; i < recs.length; i++) {
    final r = recs[i];
    if (r.cc > 1000000) { bad++; if (badIdx.length < 25) badIdx.add(i); }
    if (r.cc > 0) nonzero++;
    if (r.flags & 2 != 0) torn++;
    if (r.flags > 3) badFlags++;
  }
  print('  badFlags(>3)=$badFlags  firstBadIdx=$badIdx');
  final hist = <int, int>{};
  for (final r in recs) {
    hist[r.flags] = (hist[r.flags] ?? 0) + 1;
  }
  final keys = hist.keys.toList()..sort((a, b) => hist[b]!.compareTo(hist[a]!));
  print('  distinct flag values=${hist.length} top: '
      '${keys.take(12).map((k) => '$k:${hist[k]}').join(' ')}');
  for (final sid in [5182, 5184, 5185, 5186]) {
    if (sid < recs.length) {
      print('  sid=$sid cc=${recs[sid].cc} flags=${recs[sid].flags}');
    }
  }
  var bit2 = 0, bit7 = 0, anyUse = 0;
  for (final r in recs) {
    if (r.flags & 4 != 0) bit2++;
    if (r.flags & 128 != 0) bit7++;
    if (r.cc > 0 || (r.flags & 4) != 0) anyUse++;
  }
  print('  bit2(0x04)=$bit2 bit7(0x80)=$bit7 cc>0||bit2=$anyUse');
  // sid 5185 is List.get:length, 5186 is List.[] in these dills
  String at(int sid) => sid < recs.length ? '${recs[sid].cc}' : 'oob';
  print(
    '$kLayout: n=${recs.length} nonzero=$nonzero torn=$torn implausible=$bad '
    'len@5185=${at(5185)} idx@5186=${at(5186)}',
  );
}
