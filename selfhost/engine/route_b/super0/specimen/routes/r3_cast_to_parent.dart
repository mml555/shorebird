import 'package:corpus/main.dart';
String target(Child self) => (self as Parent).value();
void main() => print(target(Child()));
