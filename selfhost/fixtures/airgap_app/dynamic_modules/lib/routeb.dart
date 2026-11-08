// Route B step 4a: the only place allowed to touch dart:_internal.
//
// The CFE permits importing a platform-private library only from a package
// whose URI PATH starts with `dart_internal/` or `dynamic_modules/`
// (pkg/kernel/lib/target/targets.dart:399). `importer.path` for
// package:airgap_probe/main.dart is "airgap_probe/main.dart", so putting these
// calls in a subdirectory of the app package does NOT satisfy the rule -- the
// PACKAGE must be named dynamic_modules. The kill gate hit the same wall and
// solved it the same way.
//
// TEST-ONLY. This is scaffolding for the 4a hardware gate, not the delivery
// path. Delete it with the rest of the 4a hook once 4b exists.
// ignore_for_file: implementation_imports
import 'dart:_internal' as internal;
import 'dart:typed_data';

/// Replace [target]'s body in [libraryUri] with [bytecode], to be interpreted.
bool attachBytecode(Uint8List bytecode, String libraryUri, String target) =>
    internal.attachBytecodeToFunction(bytecode, libraryUri, target);

/// Restore the original AOT Code saved when the bytecode was attached.
///
/// Vanilla AOT provides no working undo -- ClearBytecode calls ClearCode, which
/// is UNREACHABLE under DART_PRECOMPILED_RUNTIME -- so Route B saves the
/// original Code on attach and restores it here.
bool detachBytecode(String libraryUri, String target) =>
    internal.detachBytecodeFromFunction(libraryUri, target);
