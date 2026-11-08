import 'package:corpus/state.dart';
class _Shim extends PState { String go() => super.read(); }
String target(CState self) => _Shim().go();
void main() {
  final app = CState()..slot = 'APP-STATE';
  print('shim route says : ${target(app)}');
  print('correct answer  : P:APP-STATE');
}
