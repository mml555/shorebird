// Native for the iOS code-push kill gate. Append to runtime/lib/object.cc,
// next to Internal_loadDynamicModule (which this is modelled on).
//
// What it does that loadDynamicModule does not: instead of invoking the loaded
// module's own entry point, it attaches the loaded bytecode onto a function the
// AOT snapshot ALREADY contains. That is the whole difference between "load new
// code" (which upstream supports, and which Phase 4 showed cannot patch) and
// "replace existing code" (which is what a patch has to do).
//
// Returns true on success, false on any lookup/load failure. It returns rather
// than throwing so the Dart side can distinguish "the harness is wrong" from
// "the VM said no" -- those are very different results for a kill gate.
//
// NOT YET COMPILED. Two things to verify against the tree first:
//   1. The accessor for a function's attached bytecode. object.h:13458 reads
//      `Bytecode::RawCast(function.untag()->ic_data_array_or_bytecode())`;
//      confirm whether the public spelling is `GetBytecode()` or `bytecode()`.
//   2. AttachBytecode asserts `ic_data_array_or_bytecode() == Object::null()`.
//      In AOT there are no IC arrays so this should hold, but if the target
//      already has something in that slot, call ClearBytecode() first.

DEFINE_NATIVE_ENTRY(Internal_attachBytecodeToFunction, 0, 3) {
#if defined(DART_DYNAMIC_MODULES)
  GET_NON_NULL_NATIVE_ARGUMENT(TypedDataBase, module_bytes,
                               arguments->NativeArgAt(0));
  GET_NON_NULL_NATIVE_ARGUMENT(String, library_uri, arguments->NativeArgAt(1));
  GET_NON_NULL_NATIVE_ARGUMENT(String, target_name, arguments->NativeArgAt(2));

  // Copy into malloc'd memory owned by an ExternalTypedData, exactly as
  // Internal_loadDynamicModule does: the loader keeps a reference to these
  // bytes beyond this call, so they cannot live in the Dart heap.
  const intptr_t length = module_bytes.LengthInBytes();
  uint8_t* data = reinterpret_cast<uint8_t*>(::malloc(length));
  if (data == nullptr) {
    const auto& exception = Instance::Handle(
        zone, thread->isolate_group()->object_store()->out_of_memory());
    Exceptions::Throw(thread, exception);
  }
  {
    NoSafepointScope no_safepoint;
    memcpy(data, module_bytes.DataAddr(0), length);  // NOLINT
  }
  const ExternalTypedData& typed_data = ExternalTypedData::Handle(
      zone,
      ExternalTypedData::New(kExternalTypedDataUint8ArrayCid, data, length));

  auto& loaded = Function::Handle(zone);
  auto& target = Function::Handle(zone);

  {
    // AttachBytecode asserts the caller is the program_lock writer, and the
    // loader requires it too.
    SafepointWriteRwLocker ml(thread, thread->isolate_group()->program_lock());

    bytecode::BytecodeLoader loader(thread, typed_data);
    loaded = loader.LoadBytecode();
    if (loaded.IsNull()) {
      return Bool::False().ptr();
    }

    // Resolve the function to be replaced in the already-compiled program.
    const auto& lib =
        Library::Handle(zone, Library::LookupLibrary(thread, library_uri));
    if (lib.IsNull()) {
      return Bool::False().ptr();
    }
    target = lib.LookupFunctionAllowPrivate(target_name);
    if (target.IsNull()) {
      return Bool::False().ptr();
    }

    // The gate's premise: the target is an ordinary AOT-compiled function.
    // If it is already interpreted, the test proves nothing.
    if (target.IsInterpreted()) {
      return Bool::False().ptr();
    }

    const auto& bc = Bytecode::Handle(zone, loaded.GetBytecode());
    if (bc.IsNull()) {
      return Bool::False().ptr();
    }

    // This is the operation under test: repoint an AOT function's entry at the
    // InterpretCall stub, with this bytecode as its body.
    target.AttachBytecode(bc);
  }

  return Bool::True().ptr();
#else
  // Built without dart_dynamic_modules: report it rather than pretending.
  return Bool::False().ptr();
#endif  // defined(DART_DYNAMIC_MODULES)
}
