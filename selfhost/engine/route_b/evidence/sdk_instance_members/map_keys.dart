// map_keys.dart <dill> <out.tsv> [--harness] [--platform=<vm_platform.dill>]
//
// Default: for every probe function `p_<id>` in container_target.dart, the
// `library#Class#member` keys of the dart: instance members it references (the
// key the retention check uses), `tearoff:` for a tear-off, and
// `dynamic#<selector>` for a call by name.
//
// --harness: the same keys for everything the RELEASE's own non-SDK code
// references outside the probes (the installer, JSON, crypto). Such a member is
// kept by the harness, not by the platform, so a host "resolves" on it is not
// evidence. One key per line.
import 'dart:io';
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

void main(List<String> a) {
  final c = Component();
  // import.dill is built without the platform; link it from --platform=<dill>.
  for (final p in a.where((x) => x.startsWith('--platform='))) {
    BinaryBuilder(File(p.substring(11)).readAsBytesSync()).readComponent(c);
  }
  BinaryBuilder(File(a[0]).readAsBytesSync()).readComponent(c);
  final harness = a.contains('--harness');
  final out = StringBuffer();
  if (harness) {
    final keys = <String>{};
    for (final lib in c.libraries) {
      if (lib.importUri.scheme == 'dart') continue;
      lib.accept(_V(keys, skipProbes: true));
    }
    for (final k in keys.toList()..sort()) {
      out.writeln(k);
    }
  } else {
    for (final lib in c.libraries) {
      if (!lib.importUri.path.endsWith('container_target.dart')) continue;
      for (final p in lib.procedures) {
        if (!p.name.text.startsWith('p_')) continue;
        final keys = <String>{};
        p.accept(_V(keys));
        out.writeln('${p.name.text.substring(2)}\t${keys.join(' ')}');
      }
    }
  }
  File(a[1]).writeAsStringSync(out.toString());
}

class _V extends RecursiveVisitor {
  _V(this.keys, {this.skipProbes = false});
  final Set<String> keys;
  final bool skipProbes;

  @override
  void visitProcedure(Procedure node) {
    final n = node.name.text;
    if (skipProbes &&
        (n.startsWith('p_') || n == 'probeAll' || n == 'keepReceivers')) {
      return;
    }
    super.visitProcedure(node);
  }

  void _m(Reference? r, {bool tearOff = false}) {
    final m = r?.node;
    if (m is! Member) return;
    final cls = m.enclosingClass;
    final lib = m.enclosingLibrary.importUri;
    if (cls == null || lib.scheme != 'dart') return;
    var n = m.name.text;
    if (m is Procedure && m.isGetter) n = 'get:$n';
    if (m is Procedure && m.isSetter) n = 'set:$n';
    if (tearOff) n = 'tearoff:$n';
    keys.add('$lib#${cls.name}#$n');
  }

  @override
  void visitInstanceInvocation(InstanceInvocation n) {
    _m(n.interfaceTargetReference);
    super.visitInstanceInvocation(n);
  }

  @override
  void visitInstanceGet(InstanceGet n) {
    _m(n.interfaceTargetReference);
    super.visitInstanceGet(n);
  }

  @override
  void visitInstanceSet(InstanceSet n) {
    _m(n.interfaceTargetReference);
    super.visitInstanceSet(n);
  }

  @override
  void visitEqualsCall(EqualsCall n) {
    _m(n.interfaceTargetReference);
    super.visitEqualsCall(n);
  }

  @override
  void visitInstanceTearOff(InstanceTearOff n) {
    _m(n.interfaceTargetReference, tearOff: true);
    super.visitInstanceTearOff(n);
  }

  @override
  void visitDynamicInvocation(DynamicInvocation n) {
    keys.add('dynamic#${n.name.text}');
    super.visitDynamicInvocation(n);
  }

  @override
  void visitDynamicGet(DynamicGet n) {
    keys.add('dynamic#get:${n.name.text}');
    super.visitDynamicGet(n);
  }

  @override
  void visitDynamicSet(DynamicSet n) {
    keys.add('dynamic#set:${n.name.text}');
    super.visitDynamicSet(n);
  }

  @override
  void visitForInStatement(ForInStatement n) {
    keys.add('dart:core#Iterable#get:iterator');
    keys.add('dart:core#Iterator#moveNext');
    keys.add('dart:core#Iterator#get:current');
    super.visitForInStatement(n);
  }
}
