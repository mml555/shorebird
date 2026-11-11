// This file deals with the cache / state management for the updater.

use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::cache::lifecycle::{BootRecovery, BootSuccess};
use crate::events::PatchEvent;
use crate::yaml::PatchVerificationMode;

use super::lifecycle::{PatchLifecycle, PatchState};
use super::{disk_io, PatchInfo};

const STATE_FILE_NAME: &str = "state.json";

/// The most events kept waiting to be sent. A device offline for long enough
/// to queue more drops the oldest, so the state file stays small.
pub const MAX_QUEUED_EVENTS: usize = 50;

/// Files and directories under `cache_dir` that shorebird has ever
/// written. On a release-version change or unparseable state we wipe
/// these and keep going. `state.json` is intentionally absent — it's
/// rewritten in place with the preserved `client_id` (so removing it
/// would lose the only thing we want to carry forward).
///
/// `patches_state.json` is the legacy file from the prior `PatchManager`
/// implementation; carrying it forward would orphan ~few-KB of stale
/// state on every device upgrading through this PR.
// TODO(eseidel): Drop `patches_state.json` from this list two minor
// versions after the release that ships this PR. By that point the
// in-flight devices upgrading from a pre-PR build have all wiped it
// once on their first release-version change, and nothing on disk
// references it anymore.
const SHOREBIRD_OWNED_PATHS: &[&str] = &["patches", "pointers.json", "patches_state.json"];

/// Records the updater's "state of the world": which patches we have
/// downloaded or installed, which patch booted last, events that need to
/// be reported to the server, etc.
///
/// Per-patch state lives inside [`PatchLifecycle`] (one document per
/// patch number under `{cache}/patches/{N}/state.json`). UpdaterState
/// itself only owns the per-install `client_id` and the event queue; all
/// other patch-related fields are pointers managed by the
/// lifecycle.
// TODO(eseidel): Split the per-release state from the per-install state
// so per-install state isn't reset on release-version change.
#[derive(Debug)]
pub struct UpdaterState {
    /// Persistent app-storage root. Holds `state.json`, `pointers.json`,
    /// and `patches/{N}/` (state.json + dlc.vmcode). The compressed
    /// download bytes live separately under the OS-managed cache dir
    /// (passed to `load_or_new_on_error`); the lifecycle owns both
    /// roots and we don't store the download dir here directly.
    cache_dir: PathBuf,
    lifecycle: PatchLifecycle,
    patch_public_key: Option<String>,
    verification_mode: PatchVerificationMode,
    serialized_state: SerializedState,
    /// Diagnostic-only identity for this in-memory instance. Nothing branches on
    /// it. Exists to make a LOST UPDATE between two concurrent instances
    /// mechanically recognisable rather than inferred: an event queued and saved
    /// by instance A can be silently discarded by a later whole-file save from
    /// instance B, which loaded before that event existed.
    instance_id: u64,
}

/// Diagnostic-only instance counter.
static NEXT_INSTANCE_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn next_instance_id() -> u64 {
    NEXT_INSTANCE_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

/// Cheap fingerprint of what is in memory / about to be written, so two saves can
/// be told apart without dumping whole files.
fn state_fingerprint(st: &SerializedState) -> String {
    use std::hash::{Hash, Hasher};
    let json = serde_json::to_string(st).unwrap_or_default();
    let mut h = std::collections::hash_map::DefaultHasher::new();
    json.hash(&mut h);
    format!("{:016x}", h.finish())
}

/// Appends one diagnostic line.
///
/// DELIBERATELY OUTSIDE the persistence mechanism under investigation: its own
/// file, opened and closed per line, append-only, and taking NO lock that state
/// operations take. Adding shared synchronisation here could serialise the very
/// race being measured and make the defect vanish.
fn state_diag(cache_dir: &Path, line: &str) {
    // Bounded by `diag_log`: rotated at a size cap, failures swallowed.
    crate::diag_log::append(
        &cache_dir.join("state_diag.log"),
        &format!(
            "pid={} tid={:?} {}",
            std::process::id(),
            std::thread::current().id(),
            line
        ),
    );
}

/// UpdaterState fields that are serialized to disk at `{cache}/state.json`.
///
/// Every per-release field on disk (`release_version` here, `pointers.json`,
/// and the per-patch `state.json` files under `patches/`) is wiped when
/// `release_version` changes; `client_id` and `queued_events` are kept. The release version effectively names a
/// unique build of the engine + updater, since the updater ships
/// embedded in the engine — there's no "version range" of updater code
/// that's mutually compatible. On a release-version mismatch, anything
/// we read from disk could have been written by code we don't
/// recognize, so we discard it.
#[derive(Debug, Deserialize, Serialize)]
struct SerializedState {
    /// Stable per-install ID. Survives release-version changes; only
    /// reset when the app is uninstalled. Used for analytics.
    /// <https://shorebird.dev/privacy/>
    client_id: String,
    /// The release version this cache corresponds to. Mismatch with the
    /// app's reported release version triggers a wipe of all per-release
    /// state.
    release_version: String,
    /// Events that have not yet been sent to the server, oldest first. Kept
    /// across release-version changes: each event names its own release, and
    /// dropping them would lose installs the server should count. An updater
    /// that can't read an older format falls back to a new state (see
    /// `load_or_new_on_error`), as for any unreadable state file.
    queued_events: Vec<PatchEvent>,
}

fn generate_client_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// True if `error` is a failure to read the file rather than to parse what
/// was read: a permission error, an I/O error, anything but not-found. iOS
/// refuses reads of protected files while a device that hasn't been unlocked
/// since boot launches the app in the background. The file is fine and will
/// read again later, so it must not be treated as corrupt.
fn is_read_failure(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        if let Some(io_error) = cause.downcast_ref::<std::io::Error>() {
            return io_error.kind() != std::io::ErrorKind::NotFound;
        }
        if let Some(json_error) = cause.downcast_ref::<serde_json::Error>() {
            return json_error.classify() == serde_json::error::Category::Io;
        }
        false
    })
}

/// The selected patch and, if one was rejected on the way, `(patch_number, error)`.
pub type PreparedBoot = (Option<PatchInfo>, Option<(usize, anyhow::Error)>);

impl UpdaterState {
    pub fn client_id(&self) -> String {
        self.serialized_state.client_id.clone()
    }
}

impl UpdaterState {
    fn new(
        cache_dir: PathBuf,
        download_dir: PathBuf,
        release_version: String,
        patch_public_key: Option<&str>,
        verification_mode: PatchVerificationMode,
        client_id: String,
        queued_events: Vec<PatchEvent>,
    ) -> Self {
        Self {
            lifecycle: PatchLifecycle::load_or_default(cache_dir.clone(), download_dir),
            cache_dir,
            patch_public_key: patch_public_key.map(|s| s.to_owned()),
            verification_mode,
            instance_id: next_instance_id(),
            serialized_state: SerializedState {
                client_id,
                release_version,
                queued_events,
            },
        }
    }

    fn load(
        cache_dir: &Path,
        download_dir: &Path,
        patch_public_key: Option<&str>,
        verification_mode: PatchVerificationMode,
    ) -> Result<Self> {
        let path = cache_dir.join(STATE_FILE_NAME);
        // Annotated because the value is now read (for the LOAD diagnostic) before
        // the struct literal that used to pin its type.
        let serialized_state: SerializedState = disk_io::read(&path)?;
        let instance_id = next_instance_id();
        state_diag(
            cache_dir,
            &format!(
                "LOAD instance={} queue_len={} fingerprint={}",
                instance_id,
                serialized_state.queued_events.len(),
                state_fingerprint(&serialized_state),
            ),
        );
        Ok(Self {
            cache_dir: cache_dir.to_path_buf(),
            lifecycle: PatchLifecycle::load_or_default(
                cache_dir.to_path_buf(),
                download_dir.to_path_buf(),
            ),
            patch_public_key: patch_public_key.map(|s| s.to_owned()),
            verification_mode,
            serialized_state,
            instance_id,
        })
    }

    /// Initializes a new UpdaterState and saves it to disk. Wipes the
    /// shorebird-managed files in `cache_dir` and the entire
    /// `download_dir` — used when the release version changes or when
    /// the on-disk state was unparseable.
    ///
    /// We *don't* blanket-wipe `cache_dir` because the embedder may
    /// configure it to be shared with non-shorebird files (the test
    /// suite does this; production engines typically hand us a
    /// dedicated subdir but the API doesn't enforce that). Instead we
    /// enumerate the set of files we've ever written there. Add new
    /// entries to `SHOREBIRD_OWNED_PATHS` when introducing new files
    /// or directories under `cache_dir`.
    fn create_new_and_save(
        cache_dir: &Path,
        download_dir: &Path,
        release_version: &str,
        patch_public_key: Option<&str>,
        verification_mode: PatchVerificationMode,
        client_id: String,
        queued_events: Vec<PatchEvent>,
    ) -> Self {
        for relative in SHOREBIRD_OWNED_PATHS {
            let path = cache_dir.join(relative);
            if !path.exists() {
                continue;
            }
            let result = if path.is_dir() {
                std::fs::remove_dir_all(&path)
            } else {
                std::fs::remove_file(&path)
            };
            if let Err(e) = result {
                shorebird_error!("Failed to wipe {:?} on reset: {:?}", path, e);
            }
        }
        // The download dir is fully shorebird-owned — wipe it whole.
        if download_dir.exists() {
            if let Err(e) = std::fs::remove_dir_all(download_dir) {
                shorebird_error!("Failed to wipe download dir on reset: {:?}", e);
            }
        }

        let mut state = Self::new(
            cache_dir.to_owned(),
            download_dir.to_owned(),
            release_version.to_owned(),
            patch_public_key,
            verification_mode,
            client_id,
            queued_events,
        );
        if let Err(e) = state.save() {
            shorebird_warn!("Error saving state {:?}, ignoring.", e);
        }
        state.lifecycle =
            PatchLifecycle::load_or_default(cache_dir.to_path_buf(), download_dir.to_path_buf());
        state
    }

    /// Loads the state in `cache_dir`, or starts a new one (wiping any
    /// per-release files) when the release version changed, there is no
    /// state file, or it doesn't parse.
    ///
    /// Returns an error, touching nothing on disk, when the state file is
    /// there but can't be read (see [`is_read_failure`]). Starting over then
    /// would delete installed patches that are only unreadable for now.
    pub fn load_or_new_on_error(
        cache_dir: &Path,
        download_dir: &Path,
        release_version: &str,
        patch_public_key: Option<&str>,
        verification_mode: PatchVerificationMode,
    ) -> Result<Self> {
        match Self::load(cache_dir, download_dir, patch_public_key, verification_mode) {
            Ok(loaded) => {
                if loaded.serialized_state.release_version != release_version {
                    shorebird_info!(
                        "release_version changed {} -> {}, creating new state",
                        loaded.serialized_state.release_version,
                        release_version
                    );
                    return Ok(Self::create_new_and_save(
                        cache_dir,
                        download_dir,
                        release_version,
                        patch_public_key,
                        verification_mode,
                        loaded.client_id(),
                        loaded.serialized_state.queued_events,
                    ));
                }
                Ok(loaded)
            }
            Err(e) if is_read_failure(&e) => {
                shorebird_error!(
                    "Can't read state file, leaving installed patches in place: {:#}",
                    e
                );
                Err(e)
            }
            Err(e) => {
                shorebird_info!("No usable state file ({:#}), creating new state.", e);
                Ok(Self::create_new_and_save(
                    cache_dir,
                    download_dir,
                    release_version,
                    patch_public_key,
                    verification_mode,
                    generate_client_id(),
                    Vec::new(),
                ))
            }
        }
    }

    /// Saves the top-level (non-patch) state to disk.
    pub fn save(&self) -> Result<()> {
        let fp = state_fingerprint(&self.serialized_state);
        let qlen = self.serialized_state.queued_events.len();
        state_diag(
            &self.cache_dir,
            &format!(
                "SAVE_BEGIN instance={} queue_len={} fingerprint={}",
                self.instance_id, qlen, fp
            ),
        );
        let result = disk_io::write(
            &self.serialized_state,
            &self.cache_dir.join(STATE_FILE_NAME),
        );
        state_diag(
            &self.cache_dir,
            &format!(
                "SAVE_END instance={} queue_len={} fingerprint={} result={}",
                self.instance_id,
                qlen,
                fp,
                if result.is_ok() { "ok" } else { "ERR" }
            ),
        );
        result
    }
}

/// Patch lifecycle accessors — UpdaterState delegates to [`PatchLifecycle`].
impl UpdaterState {
    /// Direct access to the lifecycle. Wrapping every transition in a
    /// forwarding method on UpdaterState would be churn for no reader
    /// benefit, so callers are expected to reach in for transitions
    /// (`decide_start`, `record_download_*`, `mark_bad`, etc). The
    /// boot-lifecycle / install / boot-failure helpers below are kept
    /// as wrappers because they have invariants (e.g. patch number
    /// argument validation, breadcrumb clearing) that a direct caller
    /// would have to know about.
    pub fn lifecycle(&self) -> &PatchLifecycle {
        &self.lifecycle
    }

    /// See [`lifecycle`].
    pub fn lifecycle_mut(&mut self) -> &mut PatchLifecycle {
        &mut self.lifecycle
    }

    /// Records that we are attempting to boot the patch with `patch_number`.
    pub fn record_boot_start_for_patch(&mut self, patch_number: usize) -> Result<()> {
        self.lifecycle.record_boot_start(patch_number)
    }

    /// Records that patch `patch_number` failed to boot. Marks it
    /// `Bad{BootCrash}` and recomputes `next_boot_patch`. Clears the
    /// boot breadcrumb regardless of whether it matched.
    pub fn record_boot_failure_for_patch(&mut self, patch_number: usize) -> Result<()> {
        self.lifecycle.record_boot_failure(patch_number)
    }

    /// C3/C4: threshold-governed recovery at process init. If a prior boot left
    /// its breadcrumb set, that boot recorded neither success nor an explicit
    /// failure — which says the boot did not finish, NOT that the patch is at
    /// fault. Below [`BOOT_FAILURE_THRESHOLD`] this clears the breadcrumb and
    /// lets the patch try again; at the threshold it retires it.
    ///
    /// Returns the patch number if one was RETIRED, `None` if it was retried or
    /// if no boot was in flight.
    ///
    /// [`BOOT_FAILURE_THRESHOLD`]: crate::cache::lifecycle::BOOT_FAILURE_THRESHOLD
    pub fn detect_boot_crash_on_init(&mut self) -> Result<BootRecovery> {
        self.lifecycle.detect_boot_crash_on_init()
    }

    /// Records that the in-flight boot succeeded.
    pub fn record_boot_success(&mut self) -> Result<BootSuccess> {
        self.lifecycle.record_boot_success()
    }

    pub fn currently_booting_patch(&self) -> Option<PatchInfo> {
        self.lifecycle
            .pointers()
            .currently_booting_patch
            .map(|n| self.patch_info(n))
    }

    pub fn boot_started_at(&self) -> Option<u64> {
        self.lifecycle.pointers().boot_started_at
    }

    pub fn last_successfully_booted_patch(&self) -> Option<PatchInfo> {
        self.lifecycle
            .pointers()
            .last_booted_patch
            .map(|n| self.patch_info(n))
    }

    /// The patch this process is using. Backed by the session-scoped
    /// global in `config.rs` — survives server-driven rollback (the
    /// running process is still using the patch) and resets on every
    /// fresh process start.
    pub fn running_patch(&self) -> Option<PatchInfo> {
        crate::config::running_patch_number().map(|n| self.patch_info(n))
    }

    pub fn set_running_patch(&mut self, patch_number: Option<usize>) {
        crate::config::set_running_patch_number(patch_number);
    }

    pub fn next_boot_patch(&mut self) -> Option<PatchInfo> {
        self.lifecycle
            .pointers()
            .next_boot_patch
            .map(|n| self.patch_info(n))
    }

    /// Validates that `next_boot_patch` is bootable. On failure, marks
    /// the patch `Bad{ValidationFailed}` and recomputes `next_boot_patch`.
    pub fn validate_next_boot_patch(&mut self) -> Result<()> {
        self.lifecycle
            .validate_next_boot_patch(self.patch_public_key.as_deref(), self.verification_mode)
    }

    /// Validates, selects and ATTRIBUTES the next boot in one transition, and
    /// returns the patch that must actually be executed.
    ///
    /// The invariant, true by construction rather than by ordering luck:
    ///
    ///   currently_booting_patch == the patch number of the returned PatchInfo
    ///
    /// The old boot surface established attribution BEFORE validation, so a
    /// candidate rejected for a bad signature stayed credited; a later
    /// `record_boot_success` then promoted it and `cleanup_older_than` deleted
    /// the fallback that had actually booted. Measured on device in
    /// `selfhost/evidence/p6-signing/ARM_C_EXECUTION_IDENTITY.md`.
    ///
    /// Rejecting a candidate is a NORMAL outcome, not an error: the patch is
    /// tombstoned, the pointer recomputed, and the fallback returned. Failure to
    /// persist that tombstone, or to record the boot start for the selected
    /// patch, propagates — the rejected candidate is never returned.
    pub fn prepare_next_boot(&mut self) -> Result<Option<PatchInfo>> {
        self.prepare_next_boot_reporting()
            .map(|(selected, _)| selected)
    }

    /// [`Self::prepare_next_boot`], also returning the candidate that was
    /// rejected, if any, as `(patch_number, error)`, so the caller can report it
    /// (upstream's `validate_next_boot_patch` queues a `boot_validation` event
    /// for a rejected candidate; the port keeps that on the prepare path).
    pub fn prepare_next_boot_reporting(&mut self) -> Result<PreparedBoot> {
        let candidate = self.next_boot_patch().map(|p| p.number);
        let rejected = match self.validate_next_boot_patch() {
            Ok(()) => None,
            Err(e) => {
                shorebird_info!("Next boot candidate rejected: {:?}", e);
                candidate.map(|n| (n, e))
            }
        };

        // Read the pointer only AFTER validation has had its say.
        let selected = self.next_boot_patch();
        self.set_running_patch(selected.as_ref().map(|p| p.number));
        if let Some(patch) = &selected {
            self.record_boot_start_for_patch(patch.number)?;
        }
        Ok((selected, rejected))
    }

    /// Removes the artifacts for `patch_number` and recomputes pointers.
    /// Used today for server-driven rollbacks.
    pub fn uninstall_patch(&mut self, patch_number: usize) -> Result<()> {
        self.lifecycle.cleanup(patch_number)?;
        self.lifecycle.recompute_next_boot()
    }

    /// True if `patch_number` is currently in `Bad` state — we tried it
    /// and it failed, and shouldn't be retried within this release.
    pub fn is_known_bad_patch(&self, patch_number: usize) -> bool {
        matches!(
            self.lifecycle.read_state(patch_number),
            Some(PatchState::Bad { .. })
        )
    }

    fn patch_info(&self, n: usize) -> PatchInfo {
        PatchInfo {
            // Resolved, not assumed: this path becomes the engine's
            // `active_path`, and for an assets-only patch it must point at the
            // assets artifact so the engine derives the right patch directory
            // while declining to load it as a snapshot.
            path: self.lifecycle.resolved_artifact_path(n),
            number: n,
        }
    }
}

/// PatchEvent management.
impl UpdaterState {
    /// Adds `event` to the end of the queue, dropping the oldest events if
    /// the queue would hold more than [`MAX_QUEUED_EVENTS`].
    pub fn queue_event(&mut self, event: PatchEvent) -> Result<()> {
        let before = self.serialized_state.queued_events.len();
        // The event's OWN identity, not merely a length delta: a queue that grew
        // by one does not prove which event it grew by.
        let what = format!("{:?}/{:?}", event.identifier, event.outcome);
        let events = &mut self.serialized_state.queued_events;
        events.push(event);
        if events.len() > MAX_QUEUED_EVENTS {
            let excess = events.len() - MAX_QUEUED_EVENTS;
            events.drain(..excess);
        }
        state_diag(
            &self.cache_dir,
            &format!(
                "QUEUE_EVENT instance={} event={} queue_len={}->{} fingerprint={}",
                self.instance_id,
                what,
                before,
                self.serialized_state.queued_events.len(),
                state_fingerprint(&self.serialized_state),
            ),
        );
        self.save()
    }

    pub fn copy_events(&self, limit: usize) -> Vec<PatchEvent> {
        self.serialized_state
            .queued_events
            .iter()
            .take(limit)
            .cloned()
            .collect()
    }

    #[cfg(test)]
    pub fn clear_events(&mut self) -> Result<()> {
        self.serialized_state.queued_events.clear();
        self.save()
    }

    /// Moves ONE queued entry equal to `event` to the BACK of the queue, then
    /// persists. Used when a send fails.
    ///
    /// PORT NOTE: test-only on this branch. Upstream's flusher (`send_queued_events`)
    /// sends oldest first and stops at the first transient failure, and drops
    /// events the server refuses (400/413/422), so it does not rotate. The fork's
    /// production call site was NOT re-expressed; see SELFHOST_PORT_ca91f4b3.md.
    ///
    /// WHY THIS EXISTS — measurement integrity, not tidiness.
    ///
    /// `copy_events` takes the FIRST n. Combined with retain-on-failure, that means
    /// n permanently-failing events at the head form a permanent batch: every flush
    /// retries the same n and nothing behind them is ever sent. With n = 3, three
    /// stuck events censor the queue indefinitely — and the events most likely to
    /// be behind them are the lifecycle records that fleet policy is derived from.
    /// A silently censored numerator is the same failure class as the dedupe
    /// collision and the queue wipe, arrived at a third way.
    ///
    /// Rotating a failed event to the back keeps at-least-once retention — nothing
    /// is dropped — while guaranteeing every queued event eventually reaches the
    /// head. Send order is no longer strictly FIFO; nothing depends on it, since
    /// each event carries its own timestamp and dedupe identity.
    ///
    /// Does NOT bound queue growth while the server is unreachable. That is a
    /// separate concern and deliberately untouched here.
    #[cfg(test)]
    pub fn requeue_failed_event(&mut self, event: &PatchEvent) -> Result<bool> {
        let before = self.serialized_state.queued_events.len();
        let mut rotated = false;
        if let Some(idx) = self
            .serialized_state
            .queued_events
            .iter()
            .position(|queued| queued == event)
        {
            let e = self.serialized_state.queued_events.remove(idx);
            self.serialized_state.queued_events.push(e);
            rotated = true;
        }
        state_diag(
            &self.cache_dir,
            &format!(
                "REQUEUE_FAILED instance={} event={:?}/{:?} rotated={} queue_len={}",
                self.instance_id, event.identifier, event.outcome, rotated, before
            ),
        );
        self.save()?;
        Ok(rotated)
    }

    /// Removes the first queued event equal to `event`, once the server has
    /// it. Does nothing if it's no longer queued (dropped for space).
    ///
    /// THE INVARIANT: a queued event may disappear from durable state only when
    /// THAT EXACT event has been successfully handed off. Upstream's flusher
    /// removes exactly what it sent through this method, so it already holds;
    /// the fork's `acknowledge_sent_event` is now a test-only wrapper. Identity
    /// is full-field equality, so N genuinely duplicate entries need N removals.
    pub fn remove_event(&mut self, event: &PatchEvent) -> Result<()> {
        let before = self.serialized_state.queued_events.len();
        let events = &mut self.serialized_state.queued_events;
        let result = match events.iter().position(|queued| queued == event) {
            Some(index) => {
                events.remove(index);
                self.save()
            }
            None => Ok(()),
        };
        state_diag(
            &self.cache_dir,
            &format!(
                "ACK_EVENT instance={} event={:?}/{:?} removed={} queue_len={}->{}",
                self.instance_id,
                event.identifier,
                event.outcome,
                self.serialized_state.queued_events.len() != before,
                before,
                self.serialized_state.queued_events.len(),
            ),
        );
        result
    }

    /// The fork's name for [`Self::remove_event`], returning whether an entry
    /// was found and removed. Kept so the fork's regression tests port as-is.
    #[cfg(test)]
    pub fn acknowledge_sent_event(&mut self, event: &PatchEvent) -> Result<bool> {
        let before = self.serialized_state.queued_events.len();
        self.remove_event(event)?;
        Ok(self.serialized_state.queued_events.len() != before)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cache::lifecycle::BadReason;
    use crate::test_utils::install_fake_patch_into;
    use serial_test::serial;
    use tempfile::TempDir;

    fn load(tmp: &TempDir, release_version: &str) -> UpdaterState {
        UpdaterState::load_or_new_on_error(
            tmp.path(),
            &tmp.path().join("downloads"),
            release_version,
            None,
            PatchVerificationMode::default(),
        )
        .unwrap()
    }

    /// Installs `number` and makes it the next boot candidate.
    ///
    /// Ported: upstream removed the test-only `UpdaterState::install_patch`, so
    /// this goes through the lifecycle the way production does
    /// (`install_fake_patch_into`: download, install, promote).
    fn install(state: &mut UpdaterState, _tmp: &TempDir, number: usize) {
        install_fake_patch_into(state, number).unwrap();
        state.save().unwrap();
    }

    const TEST_PUBLIC_KEY: &str = "MIIBCgKCAQEA2wdpEGbuvlPsb9i0qYrfMefJnEw1BHTi8SYZTKrXOvJWmEpPE1hWfbkvYzXu5a96gV1yocF3DMwn04VmRlKhC4AhsD0NL0UNhYhotbKG91Kwi1vAXpHhCdz5gQEBw0K1uB4Jz+zK6WK+31PryYpwLwbyXNqXoY8IAAUQ4STsHYV5w+BMSi8pepWMRd7DR9RHcbNOZlJvdBQ5NxvB4JN4dRMq8cC73ez1P9d7Dfwv3TWY+he9EmuXLT2UivZSlHIrGBa7MFfqyUe2ro0F7Te/B0si12itBbWIqycvqcXjeOPNn6WEpqN7IWjb9LUh162JyYaz5Lb/VeeJX8LKtElccwIDAQAB";

    fn load_with_verification(
        tmp: &TempDir,
        public_key: Option<&str>,
        mode: PatchVerificationMode,
    ) -> UpdaterState {
        UpdaterState::load_or_new_on_error(
            tmp.path(),
            &tmp.path().join("downloads"),
            "1.0.0+1",
            public_key,
            mode,
        )
        .unwrap()
    }

    /// Re-opens the state in Strict mode under `TEST_PUBLIC_KEY`, which nothing
    /// installed by `install()` is signed by. A candidate therefore fails for a
    /// SIGNATURE reason -- the Arm C device defect -- rather than a size one.
    fn reopen_strict(tmp: &TempDir) -> UpdaterState {
        load_with_verification(tmp, Some(TEST_PUBLIC_KEY), PatchVerificationMode::Strict)
    }

    // ---- prepare_next_boot ---------------------------------------------------
    // Every row asserts BOTH halves -- the returned patch AND the attribution --
    // because the surface this replaces had them agree in the happy path and
    // disagree exactly when a candidate was rejected, which is how the defect
    // survived.

    // Writes the process-global running patch, so it must not overlap the
    // `#[serial]` tests that read it.
    #[serial]
    #[test]
    fn prepare_returns_the_candidate_when_it_validates() {
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install(&mut state, &tmp, 1);
        install(&mut state, &tmp, 2);

        let selected = state.prepare_next_boot().unwrap();
        assert_eq!(selected.map(|p| p.number), Some(2));
        assert_eq!(state.lifecycle.pointers().currently_booting_patch, Some(2));
        assert_eq!(state.running_patch().map(|p| p.number), Some(2));
    }

    // Writes the process-global running patch, so it must not overlap the
    // `#[serial]` tests that read it.
    #[serial]
    #[test]
    fn prepare_falls_back_and_attributes_the_fallback_not_the_candidate() {
        // THE LOAD-BEARING REGRESSION. Patch 1 known-good, patch 2 present but
        // unverifiable. The old surface credited patch 2 here.
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install(&mut state, &tmp, 1);
        state.lifecycle.record_boot_start(1).unwrap();
        state.lifecycle.record_boot_success().unwrap();
        install(&mut state, &tmp, 2);

        let mut strict = reopen_strict(&tmp);
        let selected = strict.prepare_next_boot().unwrap();

        assert_eq!(
            selected.map(|p| p.number),
            Some(1),
            "must return the fallback, not the rejected candidate"
        );
        assert_eq!(
            strict.lifecycle.pointers().currently_booting_patch,
            Some(1),
            "attribution must name the patch actually selected"
        );
        assert!(
            matches!(
                strict.lifecycle.read_state(2),
                Some(PatchState::Bad {
                    reason: BadReason::ValidationFailed,
                    ..
                })
            ),
            "the rejected candidate must be tombstoned"
        );
    }

    // Writes the process-global running patch, so it must not overlap the
    // `#[serial]` tests that read it.
    #[serial]
    #[test]
    fn prepare_success_after_fallback_keeps_the_fallback_installed() {
        // The consequence the device run exposed: with correct attribution a
        // successful boot promotes patch 1, so cleanup_older_than(1) cannot
        // delete patch 1 and no retention exception is needed.
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install(&mut state, &tmp, 1);
        state.lifecycle.record_boot_start(1).unwrap();
        state.lifecycle.record_boot_success().unwrap();
        install(&mut state, &tmp, 2);

        let mut strict = reopen_strict(&tmp);
        strict.prepare_next_boot().unwrap();
        let success = strict.lifecycle.record_boot_success().unwrap();

        assert_eq!(success.patch, 1);
        assert_eq!(strict.lifecycle.pointers().last_booted_patch, Some(1));
        assert!(
            matches!(
                strict.lifecycle.read_state(1),
                Some(PatchState::Installed { .. })
            ),
            "patch 1 must survive: it is what booted"
        );
        assert!(
            strict.lifecycle.installed_artifact_path(1).exists(),
            "the fallback ARTIFACT must survive, not just its state record"
        );
        assert!(matches!(
            strict.lifecycle.read_state(2),
            Some(PatchState::Bad { .. })
        ));
    }

    // Writes the process-global running patch, so it must not overlap the
    // `#[serial]` tests that read it.
    #[serial]
    #[test]
    fn prepare_returns_base_when_the_only_candidate_is_rejected() {
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install(&mut state, &tmp, 1);

        let mut strict = reopen_strict(&tmp);
        let selected = strict.prepare_next_boot().unwrap();
        assert!(selected.is_none(), "no usable patch means the base release");
        assert_eq!(
            strict.lifecycle.pointers().currently_booting_patch,
            None,
            "the base release must not be attributed to a patch"
        );
        assert_eq!(strict.running_patch().map(|p| p.number), None);
    }

    // Writes the process-global running patch, so it must not overlap the
    // `#[serial]` tests that read it.
    #[serial]
    #[test]
    fn prepare_attribution_survives_a_later_pointer_change() {
        // Why attribution is bound to the RETURNED patch and not re-read later:
        // next_boot_patch may legitimately change after preparation (update
        // thread, promotion). The patch being booted must not.
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install(&mut state, &tmp, 1);

        let selected = state.prepare_next_boot().unwrap();
        assert_eq!(selected.map(|p| p.number), Some(1));

        // A newer patch is installed and promoted before the launch succeeds.
        install(&mut state, &tmp, 3);
        assert_eq!(state.next_boot_patch().map(|p| p.number), Some(3));

        assert_eq!(
            state.lifecycle.pointers().currently_booting_patch,
            Some(1),
            "the patch being booted must not follow a later pointer change"
        );
        let success = state.lifecycle.record_boot_success().unwrap();
        assert_eq!(
            success.patch, 1,
            "launch success must credit the patch that ran, not the newest one"
        );
        assert_eq!(state.lifecycle.pointers().last_booted_patch, Some(1));
    }

    #[test]
    fn release_version_change_wipes_patch_state() {
        // Ports `patch_manager.rs::reset_tests::deletes_patches_dir_and_resets_patches_state`.
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install_fake_patch_into(&mut state, 1).unwrap();
        state.save().unwrap();
        assert_eq!(state.next_boot_patch().map(|p| p.number), Some(1));

        let mut next = load(&tmp, "1.0.0+2");
        assert!(next.next_boot_patch().is_none());
    }

    #[test]
    fn release_version_change_wipes_legacy_patches_state_json() {
        // Devices upgrading from the prior `PatchManager` will have a
        // `patches_state.json` left behind in cache_dir from the old
        // code. The new code never reads or writes it, but leaving it
        // on disk would orphan a few KB on every release upgrade.
        // Belongs to the SHOREBIRD_OWNED_PATHS wipe list.
        let tmp = TempDir::new().unwrap();
        let _state = load(&tmp, "1.0.0+1");
        std::fs::write(
            tmp.path().join("patches_state.json"),
            br#"{"legacy":"junk"}"#,
        )
        .unwrap();
        assert!(tmp.path().join("patches_state.json").exists());

        let _next = load(&tmp, "1.0.0+2");
        assert!(
            !tmp.path().join("patches_state.json").exists(),
            "legacy patches_state.json should be wiped on release-version change"
        );
    }

    #[test]
    fn release_version_change_wipes_download_dir() {
        // The cache-rooted download dir is per-release just like the
        // persistent patches/ tree. A release-version mismatch must
        // wipe both — otherwise an in-flight partial download from
        // the prior release could be confused for a current one.
        let tmp = TempDir::new().unwrap();
        let downloads_dir = tmp.path().join("downloads");
        std::fs::create_dir_all(&downloads_dir).unwrap();
        std::fs::write(downloads_dir.join("1"), b"stale prior-release bytes").unwrap();
        std::fs::write(downloads_dir.join("orphan"), b"junk").unwrap();

        // Release-version change triggers a full wipe.
        let _next = load(&tmp, "1.0.0+2");
        assert!(
            !downloads_dir.join("1").exists(),
            "stale prior-release download should be wiped"
        );
        assert!(
            !downloads_dir.join("orphan").exists(),
            "junk in downloads/ should be wiped"
        );
    }

    #[test]
    fn client_id_persists_across_release_changes() {
        let tmp = TempDir::new().unwrap();
        let original = load(&tmp, "1.0.0+1");
        let original_client_id = original.client_id();
        let next = load(&tmp, "1.0.0+2");
        assert_eq!(next.client_id(), original_client_id);
    }

    fn event(patch_number: usize) -> PatchEvent {
        PatchEvent {
            app_id: "app_id".to_string(),
            arch: "aarch64".to_string(),
            client_id: "client_id".to_string(),
            identifier: crate::events::EventType::PatchInstallSuccess,
            patch_number,
            platform: "android".to_string(),
            release_version: "1.0.0+1".to_string(),
            timestamp: 1,
            message: None,
            failure_category: None,
            event_id: Some(format!("id-{patch_number}")),
            outcome: None,
            ambiguous_attempt_count: None,
            boot_failure_threshold: None,
            boot_started_at: None,
            updater_revision: "test".to_string(),
        }
    }

    #[test]
    fn queued_events_persist_across_release_changes() {
        let tmp = TempDir::new().unwrap();
        let mut original = load(&tmp, "1.0.0+1");
        original.queue_event(event(1)).unwrap();
        let next = load(&tmp, "1.0.0+2");
        assert_eq!(next.copy_events(10), vec![event(1)]);
    }

    #[test]
    fn queue_drops_oldest_past_the_limit() {
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        for n in 0..MAX_QUEUED_EVENTS + 2 {
            state.queue_event(event(n)).unwrap();
        }
        let events = load(&tmp, "1.0.0+1").copy_events(MAX_QUEUED_EVENTS + 2);
        assert_eq!(events.len(), MAX_QUEUED_EVENTS);
        assert_eq!(events[0], event(2));
        assert_eq!(events[MAX_QUEUED_EVENTS - 1], event(MAX_QUEUED_EVENTS + 1));
    }

    #[test]
    fn remove_event_removes_only_that_event() {
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        state.queue_event(event(1)).unwrap();
        state.queue_event(event(2)).unwrap();
        state.remove_event(&event(1)).unwrap();
        // Removing an event that's gone already is a no-op.
        state.remove_event(&event(1)).unwrap();
        assert_eq!(load(&tmp, "1.0.0+1").copy_events(10), vec![event(2)]);
    }

    #[test]
    fn corrupt_state_file_creates_new_state() {
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install_fake_patch_into(&mut state, 1).unwrap();
        state.save().unwrap();

        std::fs::write(tmp.path().join(STATE_FILE_NAME), "garbage").unwrap();

        let mut reloaded = load(&tmp, "1.0.0+2");
        assert!(reloaded.next_boot_patch().is_none());
    }

    #[test]
    fn unreadable_state_file_keeps_installed_patches() {
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install_fake_patch_into(&mut state, 1).unwrap();
        state.save().unwrap();
        let artifact = state.lifecycle.installed_artifact_path(1);

        // A directory where the file should be: it exists but every read of
        // it fails, as a protected file does before first unlock.
        let state_path = tmp.path().join(STATE_FILE_NAME);
        let saved = std::fs::read(&state_path).unwrap();
        std::fs::remove_file(&state_path).unwrap();
        std::fs::create_dir(&state_path).unwrap();

        let result = UpdaterState::load_or_new_on_error(
            tmp.path(),
            &tmp.path().join("downloads"),
            "1.0.0+1",
            None,
            PatchVerificationMode::default(),
        );
        assert!(result.is_err());
        assert!(artifact.exists(), "installed patch should survive");

        // Once the file reads again, the patch is still the one to boot.
        std::fs::remove_dir(&state_path).unwrap();
        std::fs::write(&state_path, saved).unwrap();
        let mut reloaded = load(&tmp, "1.0.0+1");
        assert_eq!(reloaded.client_id(), state.client_id());
        assert_eq!(reloaded.next_boot_patch().map(|p| p.number), Some(1));
    }

    #[test]
    fn read_failure_is_not_a_missing_or_corrupt_file() {
        use crate::file_errors::{FileOperation, IoResultExt};
        use std::io::{Error, ErrorKind};
        let path = Path::new("state.json");
        let denied: std::io::Result<()> = Err(Error::new(ErrorKind::PermissionDenied, "denied"));
        let denied = denied.with_file_context(FileOperation::ReadFile, path);
        assert!(is_read_failure(&denied.unwrap_err()));

        let missing: std::io::Result<()> = Err(Error::new(ErrorKind::NotFound, "missing"));
        let missing = missing.with_file_context(FileOperation::ReadFile, path);
        assert!(!is_read_failure(&missing.unwrap_err()));

        let corrupt = serde_json::from_str::<SerializedState>("garbage").unwrap_err();
        assert!(!is_read_failure(&anyhow::Error::new(corrupt)));
    }

    #[test]
    fn installing_replaces_unbooted_predecessor() {
        // Ports
        // `patch_manager.rs::next_boot_patch_tests::adding_patch_deletes_unbooted_patch_not_last_booted`.
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install_fake_patch_into(&mut state, 1).unwrap();
        install_fake_patch_into(&mut state, 2).unwrap();
        assert_eq!(state.next_boot_patch().map(|p| p.number), Some(2));
        assert!(!state.lifecycle.installed_artifact_path(1).exists());
    }

    #[test]
    fn boot_lifecycle_tracks_state() {
        // Ports
        // `patch_manager.rs::last_successfully_booted_patch_tests::returns_value_from_patches_state`
        // and the happy path of
        // `patch_manager.rs::record_boot_success_for_patch_tests::succeeds_when_provided_next_boot_patch_number`.
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install_fake_patch_into(&mut state, 1).unwrap();
        state.record_boot_start_for_patch(1).unwrap();
        assert_eq!(state.currently_booting_patch().map(|p| p.number), Some(1));
        state.record_boot_success().unwrap();
        assert!(state.currently_booting_patch().is_none());
        assert_eq!(
            state.last_successfully_booted_patch().map(|p| p.number),
            Some(1)
        );
    }

    #[test]
    fn record_boot_failure_marks_bad_and_clears_next_boot() {
        // Ports
        // `patch_manager.rs::next_boot_patch_tests::returns_none_patch_if_first_patch_failed_to_boot`
        // and
        // `patch_manager.rs::record_boot_failure_for_patch_tests::deletes_failed_patch_artifacts`.
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install_fake_patch_into(&mut state, 1).unwrap();
        state.record_boot_start_for_patch(1).unwrap();
        state.record_boot_failure_for_patch(1).unwrap();
        assert!(state.is_known_bad_patch(1));
        assert!(state.next_boot_patch().is_none());
    }

    #[test]
    fn record_boot_failure_works_without_active_boot() {
        // Matches the prior PatchManager semantics: the call doesn't
        // require currently_booting_patch to be set; it just marks the
        // patch bad and recomputes pointers.
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install_fake_patch_into(&mut state, 1).unwrap();
        state.record_boot_failure_for_patch(1).unwrap();
        assert!(state.is_known_bad_patch(1));
        assert!(state.next_boot_patch().is_none());
    }

    #[test]
    fn uninstall_patch_clears_artifacts_and_recomputes_pointers() {
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install_fake_patch_into(&mut state, 1).unwrap();
        assert_eq!(state.next_boot_patch().map(|p| p.number), Some(1));
        state.uninstall_patch(1).unwrap();
        assert!(state.next_boot_patch().is_none());
        assert!(!state.lifecycle.installed_artifact_path(1).exists());
    }

    #[test]
    fn is_known_bad_patch_after_mark_bad() {
        let tmp = TempDir::new().unwrap();
        let mut state = load(&tmp, "1.0.0+1");
        install_fake_patch_into(&mut state, 1).unwrap();
        state
            .lifecycle
            .mark_bad(1, BadReason::InstallHashMismatch)
            .unwrap();
        assert!(state.is_known_bad_patch(1));
    }

    const WRITER_DIR_ENV: &str = "SHOREBIRD_TEST_STATE_WRITER_DIR";
    const WRITER_TAG_ENV: &str = "SHOREBIRD_TEST_STATE_WRITER_TAG";
    const WRITES_PER_PROCESS: usize = 20;

    /// The body of each process `concurrent_processes_lose_no_events`
    /// spawns. Run on its own, it returns at once.
    #[test]
    fn state_writer_process() {
        let Ok(dir) = std::env::var(WRITER_DIR_ENV) else {
            return;
        };
        let tag = std::env::var(WRITER_TAG_ENV).unwrap();
        let dir = PathBuf::from(dir);
        for i in 0..WRITES_PER_PROCESS {
            // What `with_mut_state` does: lock, load, mutate, save. With no
            // bound on the wait, so the result doesn't depend on timing: the
            // two loops lock back to back, and a loaded machine can starve
            // one past the production timeout, which then goes on unlocked
            // by design (2 of 6 full-suite runs on an M-series Mac,
            // 2026-11-04).
            let _lock =
                crate::cache::StateLock::acquire_within(&dir, std::time::Duration::from_secs(600));
            let mut state = UpdaterState::load_or_new_on_error(
                &dir,
                &dir.join("downloads"),
                "1.0.0+1",
                None,
                PatchVerificationMode::default(),
            )
            .unwrap();
            let mut queued = event(i);
            queued.event_id = Some(format!("{tag}-{i}"));
            state.queue_event(queued).unwrap();
        }
    }

    #[test]
    fn concurrent_processes_lose_no_events() {
        // Two processes (as with an Android `android:process` service)
        // queueing events into one cache dir: each read-modify-write must
        // see the other's, and the file must stay parseable throughout.
        const { assert!(2 * WRITES_PER_PROCESS <= MAX_QUEUED_EVENTS) };
        let tmp = TempDir::new().unwrap();
        let exe = std::env::current_exe().unwrap();
        let writers: Vec<_> = ["a", "b"]
            .iter()
            .map(|tag| {
                std::process::Command::new(&exe)
                    .args([
                        "--exact",
                        "cache::updater_state::tests::state_writer_process",
                        "--test-threads=1",
                    ])
                    .env(WRITER_DIR_ENV, tmp.path())
                    .env(WRITER_TAG_ENV, tag)
                    .stdout(std::process::Stdio::null())
                    .spawn()
                    .unwrap()
            })
            .collect();
        for mut writer in writers {
            assert!(writer.wait().unwrap().success());
        }

        let state = load(&tmp, "1.0.0+1");
        let mut ids: Vec<String> = state
            .copy_events(MAX_QUEUED_EVENTS)
            .into_iter()
            .map(|e| e.event_id.unwrap())
            .collect();
        ids.sort();
        let mut expected: Vec<String> = ["a", "b"]
            .iter()
            .flat_map(|tag| (0..WRITES_PER_PROCESS).map(move |i| format!("{tag}-{i}")))
            .collect();
        expected.sort();
        assert_eq!(ids, expected);
    }
}
