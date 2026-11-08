// The instrument's own falsification control. Attaches to the host's
// attachTarget so the oracle can be checked against a function whose mode is
// KNOWN to change, beside one that must not.
@pragma('dyn-module:entry-point')
String attachTarget() => 'NEW';
