// Does the shim route reach the APP's receiver, or merely a lookalike?
class PState {
  String slot = 'UNSET';
  @pragma('vm:never-inline')
  String read() => 'P:$slot';
}

class CState extends PState {
  @pragma('vm:never-inline')
  @override
  String read() => 'C:$slot';
}
