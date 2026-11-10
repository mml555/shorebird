//! Size-bounded append for the observation logs (`state_diag.log`,
//! `success_diag.log`).
//!
//! These files are appended on every launch and nothing else removes them, so
//! on a device they would grow for the life of the install. [`append`] rotates
//! a file that has reached [`MAX_BYTES`] to `<name>.1`, replacing the previous
//! `.1`, so a log and its rotation together stay under twice the bound and the
//! newest records are always kept.
//!
//! Best-effort by design: every failure is swallowed, so a diagnostic can never
//! fail a launch. The only filesystem operations are a `metadata` call, one
//! `rename` and an append. `rename` is atomic, so a crash between steps, or
//! two processes rotating at once, can lose log lines and nothing else. The
//! files are separate from `state.json` and `pointers.json`, and no lock is
//! taken, which matters for `state_diag.log`: it must not serialise the state
//! operations it observes.

use std::{io::Write as _, path::Path};

/// A log is rotated before an append that finds it at least this large.
pub(crate) const MAX_BYTES: u64 = 64 * 1024;

/// Appends `line` (a newline is added) to the log at `path`, rotating first
/// when the file is full. Never fails and never panics.
pub(crate) fn append(path: &Path, line: &str) {
    append_bounded(path, line, MAX_BYTES);
}

fn append_bounded(path: &Path, line: &str, max_bytes: u64) {
    if std::fs::metadata(path).is_ok_and(|m| m.len() >= max_bytes) {
        rotate(path);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut f| writeln!(f, "{line}"));
}

fn rotate(path: &Path) {
    let mut rotated = path.as_os_str().to_owned();
    rotated.push(".1");
    let rotated = std::path::PathBuf::from(rotated);
    // Rename replaces an existing target on Unix; Windows refuses, so clear it
    // first. If anything fails the log just keeps growing until the next try.
    #[cfg(windows)]
    let _ = std::fs::remove_file(&rotated);
    let _ = std::fs::rename(path, &rotated);
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn read(path: &Path) -> String {
        std::fs::read_to_string(path).unwrap_or_default()
    }

    #[test]
    fn appends_lines_below_the_bound() {
        let dir = TempDir::new().unwrap();
        let log = dir.path().join("x.log");
        append_bounded(&log, "one", 1024);
        append_bounded(&log, "two", 1024);
        assert_eq!(read(&log), "one\ntwo\n");
        assert!(!dir.path().join("x.log.1").exists());
    }

    #[test]
    fn rotates_a_full_log_and_keeps_the_newest_record() {
        let dir = TempDir::new().unwrap();
        let log = dir.path().join("x.log");
        let rotated = dir.path().join("x.log.1");
        // Each line is 10 bytes with its newline; the bound is 30.
        for i in 0..3 {
            append_bounded(&log, &format!("line-{i:04}"), 30);
        }
        assert_eq!(std::fs::metadata(&log).unwrap().len(), 30);
        append_bounded(&log, "line-0003", 30);
        assert_eq!(read(&log), "line-0003\n");
        assert_eq!(read(&rotated), "line-0000\nline-0001\nline-0002\n");
    }

    #[test]
    fn a_second_rotation_replaces_the_first() {
        let dir = TempDir::new().unwrap();
        let log = dir.path().join("x.log");
        for i in 0..7 {
            append_bounded(&log, &format!("line-{i:04}"), 30);
        }
        assert_eq!(read(&log), "line-0006\n");
        assert_eq!(
            read(&dir.path().join("x.log.1")),
            "line-0003\nline-0004\nline-0005\n"
        );
    }

    #[test]
    fn total_size_stays_bounded_over_many_appends() {
        let dir = TempDir::new().unwrap();
        let log = dir.path().join("x.log");
        for i in 0..1000 {
            append_bounded(&log, &format!("line-{i:04}"), 200);
        }
        let total = std::fs::metadata(&log).unwrap().len()
            + std::fs::metadata(dir.path().join("x.log.1")).unwrap().len();
        assert!(total <= 2 * 200, "{total}");
        assert!(read(&log).contains("line-0999"));
    }

    #[test]
    fn failures_are_swallowed() {
        let dir = TempDir::new().unwrap();
        // The parent directory does not exist: nothing to open, no panic.
        append(&dir.path().join("missing").join("x.log"), "line");
        // The log path is a directory: the metadata is "full" at any bound of
        // zero, the rotate and the open both fail, and nothing panics.
        let as_dir = dir.path().join("d.log");
        std::fs::create_dir(&as_dir).unwrap();
        append_bounded(&as_dir, "line", 0);
    }

    #[test]
    fn leaves_other_files_alone_when_rotating() {
        let dir = TempDir::new().unwrap();
        let state = dir.path().join("state.json");
        std::fs::write(&state, "{}").unwrap();
        let log = dir.path().join("x.log");
        for i in 0..10 {
            append_bounded(&log, &format!("line-{i:04}"), 20);
        }
        assert_eq!(read(&state), "{}");
    }

    #[test]
    fn public_append_uses_the_size_bound() {
        let dir = TempDir::new().unwrap();
        let log = dir.path().join("x.log");
        let line = "x".repeat(1023);
        for _ in 0..(MAX_BYTES / 1024 + 1) {
            append(&log, &line);
        }
        assert!(dir.path().join("x.log.1").exists());
        assert!(std::fs::metadata(&log).unwrap().len() < MAX_BYTES);
    }
}
