import 'package:corpus/main.dart';
extension E on Child { String sup() => super.value(); }
String target(Child self) => self.sup();
void main() => print(target(Child()));
