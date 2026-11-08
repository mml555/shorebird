import 'package:corpus/main.dart';
class _Shim extends Parent { String go() => super.value(); }
String target(Child self) => _Shim().go();
void main() => print(target(Child()));
