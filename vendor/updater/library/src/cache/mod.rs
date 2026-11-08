pub(crate) mod disk_io;
pub mod lifecycle;
// pub(crate), NOT pub: `testing_check_signature` in updater.rs needs to reach
// the production verifier from inside this crate, without widening the module
// into the library's public API.
pub(crate) mod signing;
pub mod updater_state;

pub use signing::hash_file;
pub use updater_state::UpdaterState;

/// The public interface for talking about patches to the Cache.
#[derive(PartialEq, Eq, Debug, Clone)]
pub struct PatchInfo {
    pub path: std::path::PathBuf,
    pub number: usize,
}
