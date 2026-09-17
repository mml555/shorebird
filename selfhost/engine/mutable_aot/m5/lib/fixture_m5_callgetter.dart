// MAOT-5 (#69) -- serialization falsification, calling getter arm.
//
// The setter crash was reported as a SETTER defect. The paired run showed why
// that label may be wrong: `Alpha::get:v`'s body Code has an EMPTY static-call
// target table, while `Alpha::set:v`'s has three pc-relative entries, one of
// which never gets bound and is dereferenced as null during relocation.
//
// So the two subjects differ by whether the body makes a static call at all,
// not by being a getter or a setter. These two fixtures vary exactly that,
// holding the member kind fixed in each direction:
//
//   * calling_getter -- a GETTER whose body makes static calls. If it
//     crashes, "setter" is the wrong name for the defect.
//   * callless_setter -- a SETTER whose body makes none. If it serializes,
//     that is the same conclusion reached from the other side.
//
// Neither arm alone is sufficient; a single arm that agrees with the
// hypothesis is exactly how a wrong label survives.
//
// The interpolated value depends on a runtime input so the body cannot be
// constant-folded into a literal return, which would erase the calls that are
// the whole point of the arm.
import 'dart:io' show Platform;

final int input = int.tryParse(Platform.environment['M5_INPUT'] ?? '') ?? 10;

class Alpha {
  @pragma('maot:mutable')
  String get v => 'OLD:${input * 2}';
}

class AlphaNew {
  @pragma('maot:mutable')
  String get v => 'NEW:${input * 3}';
}

class AlphaNew2 {
  @pragma('maot:mutable')
  String get v => 'NEW2:${input + 7}';
}

class Beta {
  @pragma('maot:mutable')
  String get v => 'BETA:${input * 5}';
}

class F1 { String get v => 'F1'; }
class F2 { String get v => 'F2'; }
class F3 { String get v => 'F3'; }
class F4 { String get v => 'F4'; }
class F5 { String get v => 'F5'; }
class F6 { String get v => 'F6'; }

@pragma('vm:never-inline')
String site(dynamic d) => d.v as String;

void main() {
  final rs = <dynamic>[Alpha(), Beta(), F1(), F2(), F3(), F4(), F5(), F6()];
  for (final r in rs) {
    print(site(r));
  }
}
