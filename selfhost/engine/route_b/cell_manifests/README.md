# v2 cell address manifests

One file per `route-b-cell-v2` address, named by the address it produces.

    shasum -a 256 <address>.v2 | cut -c1-40   ==   <address>

That equality is the whole point: a v2 address IS the digest of this manifest,
so the file authenticates the address it is filed under and cannot be moved to a
different one. `audit_route_b_compiler.sh` uses it to tell a legitimate
content-addressed cell from an identity substitution.

Each manifest carries the three identities that a v2 cell keeps separate:

    address_schema             the schema the address was computed under
    cell                       which cell shape (e.g. macos-ios)
    fallback_engine_revision   the engine a build falls back to
    <member> <sha256>          every addressed member, one per line

The PRODUCER engine revision — the engine tree the tooling binaries were
compiled in — is NOT here. It lives in the bundle's own `PROVENANCE.txt`, and it
is deliberately not the address: two cells built from the same producer tree with
different members must not collide, and one cell whose members are identical must
not get two addresses because it was rebuilt.

These are kept in the repository rather than beside the served cell so that
auditing an existing address never requires writing into a published cell
directory.
