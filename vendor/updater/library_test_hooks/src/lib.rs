//! Test-only C symbols layered on top of `updater`.
//!
//! This crate exists so Dart integration tests under
//! `shorebird_code_push/test/integration/` can drive the updater
//! end-to-end without bloating the production C API or adding
//! `#[cfg(test)]` symbols to the cdylib that ships in the engine.
//!
//! The crate produces a single `cdylib` artifact
//! (`libupdater_test_hooks.{dylib,so}` / `updater_test_hooks.dll`) that
//! exposes:
//!
//! 1. The production C surface from `updater::c_api::dart` and
//!    `updater::c_api::engine`, re-exported so Dart tests can drive a
//!    real `shorebird_init` / `shorebird_update_with_result` cycle
//!    against tempdir-scoped state.
//! 2. Extra `shorebird_test_*` symbols defined here that wrap
//!    Rust-internal items in `updater` (gated behind the `test-hooks`
//!    Cargo feature) — currently just `shorebird_test_reset`, with more
//!    to come as later stages of the integration suite need them.
//!
//! Production updater builds (the cdylib/staticlib that ships in the
//! engine) do not enable `test-hooks` and never link this crate.

use std::os::raw::c_char;

use updater::c_api::engine;

// Re-export the production C API. This makes the symbols part of this
// crate's public API surface, which prevents the linker from stripping
// them when producing the cdylib (an rlib's `#[no_mangle]` items are
// otherwise eligible for DCE because they aren't roots from this
// crate's perspective).
#[allow(unused_imports)]
pub use updater::c_api::dart::*;
#[allow(unused_imports)]
pub use updater::c_api::engine::*;

/// Resets the updater's global config so the next `shorebird_init`
/// starts from scratch. Equivalent to a process restart for state
/// purposes — Dart tests call this between scenarios so each test
/// runs against a fresh updater.
#[no_mangle]
pub extern "C" fn shorebird_test_reset() {
    updater::testing_reset_config();
}

/// Verifies a patch signature with the PRODUCTION verifier.
///
/// Returns 0 when the signature is valid and 1 when it is not, so a caller can
/// distinguish accept from reject without parsing an error string.
///
/// Exists to close a specific gap: the Dart CLI emits a base64 signature and a
/// base64 DER public key, and until now nothing verified that those exact bytes
/// are accepted by the code that runs on a device. The Dart tests sign and
/// verify with Dart; the Rust tests verify hand-generated constants. Neither
/// crosses the boundary.
///
/// All three arguments are NUL-terminated UTF-8. A null pointer or invalid UTF-8
/// returns 1 (reject) rather than panicking across the FFI boundary — for a
/// verifier, failing closed on malformed input is the only safe direction.
///
/// # Safety
///
/// The pointers must be valid NUL-terminated C strings for the duration of the
/// call.
#[no_mangle]
pub unsafe extern "C" fn shorebird_test_check_signature(
    message: *const c_char,
    signature: *const c_char,
    public_key: *const c_char,
) -> libc::c_int {
    let to_str = |ptr: *const c_char| -> Option<String> {
        if ptr.is_null() {
            return None;
        }
        std::ffi::CStr::from_ptr(ptr)
            .to_str()
            .ok()
            .map(|s| s.to_owned())
    };

    let (Some(message), Some(signature), Some(public_key)) =
        (to_str(message), to_str(signature), to_str(public_key))
    else {
        return 1;
    };

    match updater::testing_check_signature(&message, &signature, &public_key) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

// Stub `FileCallbacks` mirroring the `#[cfg(test)]` `FileCallbacks::new`
// in `library/src/c_api/c_file.rs`. The test patch fixtures are
// self-contained zstd payloads that bipatch can apply against an empty
// source, so the read/seek callbacks never need to deliver real bytes.
extern "C" fn stub_open() -> *mut libc::c_void {
    // `CFileProvider` only checks for null to detect open failure, so
    // any non-null value works. `NonNull::dangling()` gives us one
    // without tripping clippy's `manual_dangling_ptr` lint (which fires
    // on integer-to-pointer casts like `1 as *mut _`).
    std::ptr::NonNull::<libc::c_void>::dangling().as_ptr()
}
extern "C" fn stub_read(_handle: *mut libc::c_void, _buffer: *mut u8, _count: usize) -> usize {
    0
}
extern "C" fn stub_seek(_handle: *mut libc::c_void, _offset: i64, _whence: i32) -> i64 {
    0
}
extern "C" fn stub_close(_handle: *mut libc::c_void) {}

/// Test-only convenience wrapper around `shorebird_init` that builds
/// `AppParameters` and stub `FileCallbacks` internally. Dart tests
/// pass plain C strings instead of needing bindings for those
/// engine-API structs.
#[no_mangle]
pub extern "C" fn shorebird_test_init(
    app_storage_dir: *const c_char,
    code_cache_dir: *const c_char,
    release_version: *const c_char,
    libapp_path: *const c_char,
    yaml: *const c_char,
) -> bool {
    let libapp_paths = [libapp_path];
    let params = engine::AppParameters {
        release_version,
        original_libapp_paths: libapp_paths.as_ptr(),
        original_libapp_paths_size: 1,
        app_storage_dir,
        code_cache_dir,
    };
    let callbacks = engine::FileCallbacks {
        open: stub_open,
        read: stub_read,
        seek: stub_seek,
        close: stub_close,
    };
    engine::shorebird_init(&params, callbacks, yaml)
}

/// Simulates the engine's successful boot of `next_boot_patch`.
/// In production this is two engine actions (launch-start, then
/// launch-success after Dart VM startup completes); the Dart layer
/// has no concept of either, so we expose the combined outcome as a
/// single semantic action: "the next patch booted cleanly."
#[no_mangle]
pub extern "C" fn shorebird_test_simulate_successful_launch() {
    engine::shorebird_report_launch_start();
    engine::shorebird_report_launch_success();
}
