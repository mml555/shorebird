// The replacement body. Deliberately self-contained -- it returns a literal and
// touches nothing outside itself -- so a failure is attributable to the
// substrate rather than to reference binding, which is a separate question the
// killgate's Spike B already answered.
@pragma('dyn-module:entry-point')
String target() => 'NEW';
