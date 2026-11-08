// r3 — SDK-symbol binding: the canonical failure. The killgate's first attempt
// died here: "Unable to find function print in Library:'dart:core'"
// (bytecode_reader.cc:1172), because the AOT precompiler drops library
// dictionaries. If this loads and prints, SDK symbols resolve.
@pragma('dyn-module:entry-point')
String greet() {
  print('BOUND');
  return 'NEW-PRINTED';
}
