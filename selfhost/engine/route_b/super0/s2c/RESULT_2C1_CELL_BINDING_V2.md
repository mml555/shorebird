# D-SUPER-2C.1 · CELL-BINDING-V2 — resolver split, host controls PASS

    18/18   route_b_cell_binding_test.dart (7) + route_b_compiler_test.dart (11)

Nothing published. H2's 16 members untouched, compiler still `9d4ace27…`,
map/protection unchanged, F2/CLI2 unchanged, release 139 retained.

## Why option 1 was not attempted

The recursion is real and worth writing down. The compiler archive is itself an
ADDRESSED member of the v2 manifest, and the publisher writes `--rev` straight
into `PROVENANCE.txt`. So:

    write H3 into PROVENANCE.txt -> archive digest changes -> address becomes H4
    write H4 into PROVENANCE.txt -> archive digest changes -> address becomes H5
    …

There is no one-time repair, only a fixed point that would need its own
canonicalization scheme. Option 3 avoids the problem instead of solving it.

## The split

    PRODUCER LINEAGE   what the bundle IS      a5a8be58…  (its PROVENANCE.txt)
    WHOLE-CELL ADDRESS which cell it BELONGS TO 64ff9f59…  (the v2 descriptor)

One field carried both while an address meant "the engine". Under v2 it means
"these 16 artifacts", so the identities separated and the field had to.

## The new binding is STRONGER than the equality it replaces

On the v2 path, `recordedEngine == engineHash` is replaced by:

    sha256(descriptor)[0:40] == requested address     self-authenticating
    descriptor.cell == macos-ios
    descriptor lists the compiler member EXACTLY ONCE
    sha256(downloaded bundle) == that member's digest
    recordedEngine PRESENT (lineage must exist, just not equal the address)

plus every existing check, unchanged: all eight files present, each file's
sha256 equal to its `PROVENANCE.txt` line, the dart2bytecode probe, the flutter
target, and the `patched-verification-dill` capability.

A bundle from another cell fails the member-digest check. A descriptor from
another cell fails to hash to the requested address. Editing either changes a
digest. Nothing can be substituted.

The descriptor is fetched BEFORE the bundle, so a descriptor that fails to
authenticate refuses without downloading tooling it would discard.

## v1 is untouched

No descriptor -> the old rule governs, verbatim. Every historical cell keeps
its original semantics; H still resolves only because its bundle says H and H
was requested. The new semantics are gated behind a cryptographically valid
`route-b-cell-v2` descriptor, not enabled globally.

## Qualification matrix — 7/7

    v2  descriptor + addressed bundle, bundle records H   ACCEPT
    v2  mutated compiler archive                          REFUSE  digest
    v2  descriptor addressing another cell                REFUSE  address
    v2  compiler member digest edited in the descriptor   REFUSE  address
    v2  descriptor for cell linux-android                 REFUSE  wrong cell
    v1  bundle records the requested hash                 ACCEPT
    THE CAUSAL NEGATIVE
        H2 requested + bundle says H + NO descriptor      REFUSE

That last pair is the one that matters. The same archive that is REFUSED
without a descriptor is ACCEPTED with a valid one — so the equality check was
replaced by a binding, not deleted.

The matrix drives `resolveRouteBCompiler` itself, not a re-implementation, and
the pre-existing 11-test resolver suite still passes unchanged.

## Not done — the rest of this lane

    publish the committed cell_manifest.v2 as a descriptor under a namespace
      OUTSIDE the addressed cell
    make descriptor misses hard-404 with no pinned fallback
    wire the CLI's descriptor fetcher to that URL
    prove it end to end from an empty compiler cache through the real CDN

Only after that is H2's Route B tooling actually cell-bound and resolvable, and
only then is a NEW release identity worth cutting. Release 139 stays as negative
evidence and will not be retrofitted.
