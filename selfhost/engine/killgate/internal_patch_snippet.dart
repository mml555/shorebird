// Add to sdk/lib/_internal/vm/lib/internal_patch.dart, near the existing
// loadDynamicModule patch (~line 468). The vm:external-name pragma is what
// binds this to DEFINE_NATIVE_ENTRY(Internal_attachBytecodeToFunction, ...).
//
// Deliberately returns bool rather than throwing: a kill gate needs to tell
// "the harness could not find the function" apart from "the VM refused".

@pragma("vm:external-name", "Internal_attachBytecodeToFunction")
external bool attachBytecodeToFunction(
  Uint8List bytecode,
  String libraryUri,
  String targetName,
);
