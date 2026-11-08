// Route B (selfhost): turn an SBRBPTCH container into a patch artifact the
// existing updater can download, inflate and hash-check without any change to
// the transport.
//
// WHY A BASE-INDEPENDENT DIFF. The updater inflates every code artifact against
// the running app's base snapshot: on iOS that is the four Dart blobs presented
// as one stream by SnapshotsDataHandle. A Route B container has nothing in
// common with those bytes, so diffing against them buys nothing -- and it would
// force the producer to reproduce the device's exact base byte-for-byte, which
// needs `analyze_snapshot --dump_blobs`, a Shorebird-fork tool we cannot build.
//
// Diffing against a tiny SYNTHETIC base makes the artifact pure literal
// inserts: the reconstruction never reads the base, so it is correct on any
// device whose base reader merely works. (An actually-empty base panics inside
// bidiff's suffix-array code, which is why the synthetic base is one zero byte
// rather than nothing at all.)
//
// That is a property, not a hope, which is why this tool VERIFIES it rather
// than asserting it -- see `verify` below, which reconstructs against both an
// empty base and a 4 MB noise base and requires both to reproduce the container
// exactly. Measured: a 4,338-byte container becomes a 229-byte artifact,
// identical for every synthetic base length tried.
//
// The transport is otherwise untouched: same bidiff+zstd container, same
// download/resume/install/hash path.
//
// Usage:
//   route_b_artifact <container.sbrbptch> <output.patch>
//
// Prints the sha256 of the CONTAINER (not the artifact) -- that is the value
// the control plane must record as the patch hash, because check_hash() runs
// against the inflated result.

use std::fs::{self, File};
use std::io::{Cursor, Read, Seek, SeekFrom, Write};

use sha2::{Digest, Sha256};

/// Reconstruct `artifact` against `base`, exactly the way the updater's
/// `inflate()` does, and return the bytes.
fn inflate_with_base(artifact: &[u8], base: Vec<u8>) -> Result<Vec<u8>, String> {
    let decoder = zstd::Decoder::new(Cursor::new(artifact.to_vec()))
        .map_err(|e| format!("zstd header: {e:?}"))?;
    let mut reader = bipatch::Reader::new(decoder, Cursor::new(base))
        .map_err(|e| format!("bipatch header: {e:?}"))?;
    let mut out = Vec::new();
    reader
        .read_to_end(&mut out)
        .map_err(|e| format!("bipatch read: {e:?}"))?;
    Ok(out)
}

/// The claim this tool rests on, checked every time it runs.
///
/// If a future bidiff ever emitted a base-referencing instruction for an empty
/// base, this is what would catch it -- before an artifact reached a device and
/// failed its install hash check with nothing to point at.
fn verify(container: &[u8], artifact: &[u8]) {
    let from_empty =
        inflate_with_base(artifact, Vec::new()).expect("inflate against an empty base");
    assert_eq!(
        from_empty, container,
        "artifact does not reconstruct the container from an empty base"
    );

    // A base of a different size and content entirely. If reconstruction still
    // matches, the artifact provably does not read the base.
    let mut noise = vec![0u8; 4 * 1024 * 1024];
    for (i, b) in noise.iter_mut().enumerate() {
        *b = (i.wrapping_mul(2654435761) >> 13) as u8;
    }
    let from_noise = inflate_with_base(artifact, noise).expect("inflate against a noise base");
    assert_eq!(
        from_noise, container,
        "artifact is base-DEPENDENT: reconstruction changed with the base"
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: {} <container.sbrbptch> <output.patch>", args[0]);
        std::process::exit(1);
    }
    let container = fs::read(&args[1]).expect("read container");

    if container.len() < 8 || &container[0..8] != b"SBRBPTCH" {
        // Refuse early. Producing an artifact from something that is not a
        // container would install cleanly and then be refused pre-main, which
        // is a much more expensive place to discover a typo.
        eprintln!("error: {} is not an SBRBPTCH container", args[1]);
        std::process::exit(2);
    }

    // An EMPTY base panics inside bidiff's suffix-array code ("partitioned
    // suffix arrays should always find at least one longest common substring"),
    // so the smallest base that keeps the differ alive is used instead. Whether
    // that is enough to keep the artifact base-INDEPENDENT is not assumed --
    // verify() below reconstructs against a completely different base and
    // requires the same bytes out.
    let synthetic_base = vec![
        0u8;
        std::env::var("ROUTE_B_BASE_LEN")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(1usize)
    ];
    let mut artifact = Cursor::new(Vec::new());
    patch::make_patch(synthetic_base, container.clone(), &mut artifact);
    artifact.seek(SeekFrom::Start(0)).unwrap();
    let artifact = artifact.into_inner();

    verify(&container, &artifact);

    let mut f = File::create(&args[2]).expect("create output");
    f.write_all(&artifact).expect("write output");

    let hash = Sha256::digest(&container)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    println!("container bytes : {}", container.len());
    println!("artifact bytes  : {}", artifact.len());
    println!("verified        : reconstructs from an empty base AND a noise base");
    println!("patch hash      : {}", hash);
}
