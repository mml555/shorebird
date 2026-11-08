import 'package:corpus/main.dart';
String target(Child self) => Parent.value(self);
void main() => print(target(Child()));
