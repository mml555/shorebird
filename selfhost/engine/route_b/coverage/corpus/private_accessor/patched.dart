// Case: private accessors. The VM matches its disambiguated get:/set: forms,
// and a real app caught this when bare names were emitted -- gen_kernel refused
// the whole app with "a member with disambiguated name `_platform` was not
// found". Private, because a `library:` retention item covers public members
// only.
class Holder {
  String _slot = 'NEW';

  @pragma('vm:never-inline')
  String get _value => '$_slot-NEW';

  @pragma('vm:never-inline')
  set _value(String v) => _slot = 'NEW-$v';

  String probe() {
    _value = DateTime.now().millisecondsSinceEpoch >= 0 ? 'a' : 'b';
    return _value;
  }
}

@pragma('vm:never-inline')
String get _topLevel => 'NEW-top';

void main() => print('${Holder().probe()}$_topLevel');
