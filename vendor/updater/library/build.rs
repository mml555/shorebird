extern crate cbindgen;

use std::env;
use std::path::{Path, PathBuf};

// See:
// <https://github.com/eqrion/cbindgen/blob/master/docs.md#buildrs>
// <https://doc.rust-lang.org/cargo/reference/build-scripts.html>
// <https://doc.rust-lang.org/cargo/reference/build-script-examples.html>
fn main() {
    let crate_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());

    // `engine_http`: HTTP goes through the engine's client (the platform's
    // HTTP stack) rather than ureq. Keep in sync with the target-specific
    // `ureq` dependency in Cargo.toml.
    println!("cargo:rustc-check-cfg=cfg(engine_http)");
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if matches!(target_os.as_str(), "ios" | "macos" | "android") {
        println!("cargo:rustc-cfg=engine_http");
    }

    emit_updater_revision(&crate_dir);

    // Each header is generated from a single source file. cbindgen scans
    // exactly that file and emits the `pub extern "C"` items it defines plus
    // the C types they reference. Since each bucket file is self-contained
    // (defines its own types), there is no cross-bucket leak and no need for
    // exclusion lists in the cbindgen configs.
    generate_header(
        &crate_dir,
        "cbindgen_dart.toml",
        "src/c_api/dart.rs",
        "include/updater_dart.h",
    );
    generate_header(
        &crate_dir,
        "cbindgen_engine.toml",
        "src/c_api/engine.rs",
        "include/updater_engine.h",
    );
}

fn generate_header(crate_dir: &Path, config_name: &str, src_relative: &str, output_path: &str) {
    let config_path = crate_dir.join(config_name);
    let config = match cbindgen::Config::from_file(&config_path) {
        Ok(config) => config,
        Err(e) => {
            println!("cargo:warning=Error loading {}: {e}", config_path.display());
            return;
        }
    };

    let src_path = crate_dir.join(src_relative);
    let result = cbindgen::Builder::new()
        .with_src(&src_path)
        .with_config(config)
        .generate();
    match result {
        Ok(contents) => {
            contents.write_to_file(output_path);
        }
        Err(e) => {
            println!("cargo:warning=Error generating {output_path}: {e}");
            // We don't exit non-zero here so local rust-analyzer keeps
            // working when cbindgen has an issue.
        }
    }
}

/// Stamps the updater's own git revision into the binary as `UPDATER_REVISION`.
///
/// WHY. Event eligibility for lifecycle/policy analysis must be decided by the
/// BEHAVIOUR-BEARING CLIENT CODE, not inferred from an app release version. Three
/// separate defects (server dedupe collision, whole-queue wipe, head-of-line
/// starvation) each silently zeroed the recovery numerator, and each was fixed in
/// THIS crate — so "did this client ship the fixes" is a fact about this revision.
///
/// READS THE GIT FILES DIRECTLY, no subprocess. The first version shelled out to
/// `git`, which is not on PATH inside the ninja action that builds this crate for
/// the engine, so it silently produced "unknown" — an engine that could never be
/// matched to an eligible revision. Caught only because the stamp is verified in
/// the shipped bytes.
///
/// Never fails the build: anything unreadable yields "unknown", which the server
/// treats as ineligible rather than trusting.
fn emit_updater_revision(crate_dir: &Path) {
    let repo_root = crate_dir.parent().unwrap_or(crate_dir);
    let git_dir = repo_root.join(".git");
    let head_path = git_dir.join("HEAD");

    let mut rev = String::from("unknown");
    let mut watch = vec![head_path.clone()];

    if let Ok(head) = std::fs::read_to_string(&head_path) {
        let head = head.trim().to_string();
        if let Some(ref_name) = head.strip_prefix("ref: ") {
            // Symbolic HEAD: the sha lives in the ref file, NOT in HEAD. HEAD's
            // contents do not change when a commit lands on the branch, which is
            // why watching HEAD alone left the stamp frozen.
            let ref_path = git_dir.join(ref_name);
            watch.push(ref_path.clone());
            if let Ok(sha) = std::fs::read_to_string(&ref_path) {
                let sha = sha.trim().to_string();
                if !sha.is_empty() {
                    rev = sha;
                }
            } else if let Ok(packed) = std::fs::read_to_string(git_dir.join("packed-refs")) {
                // Ref may be packed rather than loose.
                watch.push(git_dir.join("packed-refs"));
                for line in packed.lines() {
                    if let Some((sha, name)) = line.split_once(' ') {
                        if name.trim() == ref_name {
                            rev = sha.trim().to_string();
                            break;
                        }
                    }
                }
            }
        } else if !head.is_empty() {
            rev = head; // detached HEAD holds the sha directly
        }
    }

    if rev != "unknown" && rev.len() > 12 {
        rev.truncate(12);
    }

    for path in watch {
        if path.exists() {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
    println!("cargo:rustc-env=UPDATER_REVISION={rev}");
}
