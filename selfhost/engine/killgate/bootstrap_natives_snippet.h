// Add to the V(...) list in runtime/vm/bootstrap_natives.h, next to
// V(Internal_loadDynamicModule, 1) at line ~275. The number is the argument
// count (bytes, libraryUri, targetName).
  V(Internal_attachBytecodeToFunction, 3)                                      \
