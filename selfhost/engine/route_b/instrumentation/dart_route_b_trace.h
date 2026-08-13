// Copyright (c) 2026, the Shorebird self-host fork. All rights reserved.
//
// Route B: the post-attach state of a patched Function, as a POD record.
//
// WHY THIS FILE EXISTS AT ALL. On device, `Dart_RouteBActivatePatch` returns
// `Dart_RouteB_Ok` and the embedder reports `applied 1/1 targets` — and the app
// goes on executing the original AOT body. Reproduced with a private-member body
// AND with a public one, so the fault is common to all replacements. `applied
// 1/1` proves exactly one thing: that call returned success. What happened to the
// Function between `RouteBSaveOriginalCode` and the return is unobserved, and
// every surviving hypothesis lives in that gap.
//
// WHY IT IS A POD THE VM FILLS AND THE EMBEDDER WRITES. The attach runs while
// holding `program_lock()` as a writer, inside a DARTSCOPE, before main. Opening
// a file there would add I/O under a write lock on the isolate group. So the VM
// fills fixed-width fields and `shorebird.cc` writes them out afterwards, which
// is the division `lib/object.cc` already documents: "I/O is deliberately the
// embedder's: it passes bytes, the VM attaches them."
//
// WHY IT IS A NEW HEADER RATHER THAN A CHANGE TO dart_api.h. `include/dart_api.h`
// is included across the whole runtime, so editing it turns a two-file rebuild
// into a whole-runtime one. More importantly `runtime/vm/object.{cc,h}` are in
// `VM_SNAPSHOT_FILES` (`tools/make_version.py:20-36`, read and confirmed):
// editing them changes `SNAPSHOT_HASH`, and the ALREADY-PUBLISHED App.framework
// snapshot then refuses to load with "Wrong full snapshot version". That would
// surface as a brand-new device failure on the very run meant to explain one —
// instrumentation manufacturing a fifth false cause, and the first one that would
// have looked like data. So nothing here touches either file: the existing
// four-argument export keeps its signature and a traced sibling is added beside
// it in `runtime/lib/object.cc`, which is NOT a snapshot file.
#ifndef RUNTIME_INCLUDE_DART_ROUTE_B_TRACE_H_
#define RUNTIME_INCLUDE_DART_ROUTE_B_TRACE_H_

#include <stdint.h>

// Spelled out rather than reusing `DART_EXPORT`, so this header needs no
// `dart_api.h` include and the coupling to it stays at zero. Same effect for the
// platforms Route B builds for.
// `extern "C"` is the load-bearing half, and leaving it out cost a full iOS link:
// the DEFINITION lives inside `namespace dart`, so without C linkage it becomes
// `dart::Dart_RouteBActivatePatchTraced` and the embedder's call fails with
// `undefined symbol`. `DART_EXPORT` works precisely because it expands to
// `DART_EXTERN_C ...` -- extern "C" ignores the enclosing namespace for linkage.
#if defined(__cplusplus)
#define DART_ROUTE_B_EXTERN_C extern "C"
#else
#define DART_ROUTE_B_EXTERN_C
#endif

#if defined(_WIN32)
#define DART_ROUTE_B_EXPORT DART_ROUTE_B_EXTERN_C __declspec(dllexport)
#else
#define DART_ROUTE_B_EXPORT                                                    \
  DART_ROUTE_B_EXTERN_C __attribute__((visibility("default")))                 \
      __attribute((used))
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// Every field is fixed-width and set unconditionally to a known sentinel before
// use, so a field that was never reached reads as "not observed" rather than as
// stack garbage that happens to look plausible.
#define DART_ROUTE_B_TRACE_UNSET (-1)

typedef struct {
  // The existing return code, carried here so the record is self-contained: a
  // reader must never have to correlate two sources to know what the call said.
  int32_t result;

  // Reached the attach at all, and returned from it. These bracket the ONE
  // statement whose effect is in question, so `attach_entered=1
  // attach_returned=0` would mean it did not come back — which no other field
  // could tell you.
  int32_t attach_entered;
  int32_t attach_returned;

  // `Function::HasBytecode()` and `Function::IsInterpreted()`. The `pre` values
  // matter because `AttachBytecode` asserts the slot is empty and that assert is
  // compiled out in a release build: if `pre` is already set, the attach silently
  // overwrote something.
  int32_t has_bytecode_pre;
  int32_t has_bytecode_post;
  int32_t is_interpreted_pre;
  int32_t is_interpreted_post;

  // THE PATCHER-SIDE FUNCTION IDENTITY. Without it the caller/patcher comparison
  // is impossible, which is what stalled v1: the trace could say the field moved
  // but never which OBJECT's field.
  uint64_t function_ptr;

  // Code object IDENTITY, not contents: the raw pointer is enough to tell "the
  // same Code is still installed" from "a different one is".
  uint64_t code_pre;
  uint64_t code_post;
  int64_t code_pre_size;

  // TWO LAYERS, NEVER COLLAPSED. v1 labelled Code accessors as if they were the
  // Function's fields, and the mismatch that produced looked exactly like a real
  // VM anomaly -- it sent an investigation after a Function-identity bug that the
  // data never supported. The generated call reads the FUNCTION field, so that is
  // what has to be measured; the Code values are kept beside it precisely so the
  // two can be compared instead of confused.
  //
  // `fn_*` are read out of UntaggedFunction at the VM's own offsets -- the same
  // bytes, at the same addresses, that `ldur x30,[x0,#0x7]` and `[x0,#0xf]` load.
  uint64_t fn_entry_point_pre;
  uint64_t fn_entry_point_post;
  uint64_t fn_unchecked_entry_point_pre;
  uint64_t fn_unchecked_entry_point_post;

  // `code_*` are Code::EntryPoint()/UncheckedEntryPoint() -- what v1 actually
  // recorded under the fn_ names.
  uint64_t code_entry_point_pre;
  uint64_t code_entry_point_post;
  uint64_t code_unchecked_entry_point_pre;
  uint64_t code_unchecked_entry_point_post;

  // THE CALLER-SIDE IDENTITY, so the comparison needs no external pool reader.
  // When a caller name is supplied, its Code's object pool is scanned for
  // Function entries: how many were seen, how many are THIS target, and the
  // first pointer that is not.
  int32_t caller_resolved;
  int32_t caller_pool_functions;
  int32_t caller_pool_matches_target;
  uint64_t caller_pool_other_fn;

  // The value `entry_point_post` is SUPPOSED to equal, captured in the same run
  // rather than compared against a constant recorded elsewhere — stub addresses
  // are per-snapshot and a stale expectation would read as a mismatch.
  uint64_t interpret_call_entry_point;
  int32_t entry_point_post_is_interpret_call;

  int64_t bytecode_size;
} Dart_RouteBTrace;

// The traced sibling of `Dart_RouteBActivatePatch`.
//
// Identical behaviour and identical return values; `trace` may be null, and when
// it is this is the original function. It is deliberately NOT a gate: the attach
// path's decisions are unchanged, because a diagnostic that alters what it
// measures cannot settle what the un-instrumented build does.
DART_ROUTE_B_EXPORT int32_t Dart_RouteBActivatePatchTraced(
    const uint8_t* payload,
    intptr_t payload_length,
    const char* library_uri,
    const char* target_name,
    Dart_RouteBTrace* trace,
    const char* caller_name);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // RUNTIME_INCLUDE_DART_ROUTE_B_TRACE_H_
