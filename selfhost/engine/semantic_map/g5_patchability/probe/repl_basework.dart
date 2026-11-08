// An instance method's replacement is a top-level function whose first
// parameter is the receiver.
//
// The receiver is typed `Object`, not `Base`: the release's dynamic interface
// grants this library's members as CALLABLE, which is not the same capability
// as can-be-used-as-type. Naming `Base` as a type made attach fail with
// "Unable to find class Base" -- the body does not need the type, so it does
// not ask for it.
@pragma('dyn-module:entry-point')
String work(Object self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'PATCHED-w' : 'X';
